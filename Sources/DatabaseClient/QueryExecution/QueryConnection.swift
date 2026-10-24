import DatabaseKit
import DatabaseWire

/// Owns query admission and cancellation over a separately owned client transport.
public actor QueryConnection<Transport: DatabaseTransport> {
    #if DATABASE_CLIENT_MULTI_BASE
    public typealias Response = QueryResult<QueryRowStream<Transport>, QueryGraphStream<Transport>, QueryBooleanResult>
    #else
    public typealias Response = QueryResult<QueryRowStream<Transport>, QueryGraphStream<Transport>, Bool>
    #endif

    private enum Phase { case open, closing, closed }
    private let session: DatabaseSessionClient<Transport>
    private let concurrencyLimit: Int
    private var phase = Phase.open
    private var nextIdentifier: UInt64 = 1
    private var executions: [UInt64: Task<QueryExecuteOperation.Response, Error>] = [:]
    private var closingTask: Task<Void, Never>?

    init(session: DatabaseSessionClient<Transport>, concurrencyLimit: Int) {
        self.session = session
        self.concurrencyLimit = concurrencyLimit
    }

    public func execute(_ sql: SQL, options: QueryExecutionOptions = .init(),
        metadata: OperationRequestMetadata = .init()) async throws -> Response {
        try await execute(.sql(sql.text), parameters: sql.parameters, options: options, metadata: metadata)
    }

    public func execute(_ statement: QueryStatement, parameters: [QueryParameter] = [],
        options: QueryExecutionOptions = .init(), metadata: OperationRequestMetadata = .init()) async throws -> Response {
        try await execute(.statement(statement), parameters: parameters, options: options, metadata: metadata)
    }

    public func execute(_ block: SQLBlock, parameters: [QueryParameter] = [],
        options: QueryExecutionOptions = .init(), metadata: OperationRequestMetadata = .init()) async throws -> Response {
        try await execute(.block(block), parameters: parameters, options: options, metadata: metadata)
    }

    public func execute(_ input: QueryInput, parameters: [QueryParameter] = [],
        options: QueryExecutionOptions = .init(), metadata: OperationRequestMetadata = .init()) async throws -> Response {
        try options.validate()
        let request = QueryExecuteOperation.Request(input: input, parameters: parameters,
            graphPartitions: options.graphPartitions,
            page: options.pageSize.map { .init(limit: $0) }, budget: options.budget)
        let response = try await invoke(request, metadata: metadata)
        let source = request.page == nil ? nil
            : QueryPageSource(connection: self, request: request, metadata: metadata)
        return try adapt(response, source: source)
    }

    func invoke(_ request: QueryExecuteOperation.Request,
        metadata: OperationRequestMetadata) async throws -> QueryExecuteOperation.Response {
        guard phase == .open else { throw QueryConnectionError.closed }
        if Task.isCancelled { throw CancellationError() }
        guard executions.count < concurrencyLimit else {
            throw QueryConnectionError.concurrentExecutionLimitReached(concurrencyLimit)
        }
        guard nextIdentifier != 0 else { throw QueryConnectionError.requestIdentifierExhausted }
        let identifier = nextIdentifier
        nextIdentifier = identifier == .max ? 0 : identifier + 1
        let session = session
        let task = Task {
            let value = try await session.execute(DatabaseOperationCatalog.queryExecute,
                request: request, metadata: metadata)
            if Task.isCancelled { throw CancellationError() }
            if let limit = request.page?.limit {
                let count: UInt64
                switch value {
                case .rows(let page): count = UInt64(page.rowCount)
                case .rdfGraph(let page): count = UInt64(page.quadCount)
                default: return value
                }
                guard count <= UInt64(limit) else {
                    throw QueryStreamError.pageLimitExceeded(actual: count, maximum: limit)
                }
            }
            return value
        }
        executions[identifier] = task
        defer { executions[identifier] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    /// Cancels and drains this scope without shutting down a shared transport.
    public func close() async {
        if let closingTask { await closingTask.value; return }
        guard phase != .closed else { return }
        phase = .closing
        let admitted = Array(executions.values)
        for task in admitted { task.cancel() }
        let drain = Task {
            for task in admitted {
                do { _ = try await task.value }
                catch {
                    // Execute retains the error; close only proves termination.
                }
            }
        }
        closingTask = drain
        await drain.value
        executions.removeAll()
        phase = .closed
    }

    private func adapt(_ response: QueryExecuteOperation.Response,
        source: QueryPageSource<Transport>?) throws -> Response {
        switch response {
        case .rows(let page):
            if page.continuation != nil && source == nil { throw QueryStreamError.unexpectedContinuation }
            if page.rowCount == 0 && page.continuation != nil { throw QueryStreamError.emptyPageWithContinuation }
            return .rows(QueryRowStream(page: page, source: page.continuation == nil ? nil : source))
        case .rdfGraph(let page):
            if page.continuation != nil && source == nil { throw QueryStreamError.unexpectedContinuation }
            if page.quadCount == 0 && page.continuation != nil { throw QueryStreamError.emptyPageWithContinuation }
            return .rdfGraph(QueryGraphStream(page: page, source: page.continuation == nil ? nil : source))
        case .boolean(let value): return .boolean(value)
        case .command(let kind, let count): return .command(kind, affectedRows: count)
        case .copy(let bytes, let count): return .copy(bytes: bytes, affectedRows: count)
        case .block(let results):
            // This is the final ordered outcome boundary; row/quad payloads stay retained views.
            return try Response(results: results.map { try adapt($0, source: source) })
        }
    }
}
