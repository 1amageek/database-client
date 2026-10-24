import DatabaseAccess
import DatabaseKit
import DatabaseWire

/// Resource cleanup ownership over an existing Client invocation scope.
actor RemoteExecution<Transport: DatabaseTransport>: DatabaseExecuting {
    private let connection: QueryConnection<Transport>
    private let shutdown: (@Sendable () async -> Void)?
    private var closingTask: Task<Void, Never>?

    init(connection: QueryConnection<Transport>, shutdown: (@Sendable () async -> Void)?) {
        self.connection = connection
        self.shutdown = shutdown
    }

    nonisolated func execute(_ input: QueryInput, parameters: [QueryParameter],
        options: QueryExecutionOptions, metadata: OperationRequestMetadata) async throws -> AccessResult {
        adapt(try await connection.execute(input, parameters: parameters, options: options, metadata: metadata))
    }

    func close() async {
        if let closingTask { await closingTask.value; return }
        let connection = connection, shutdown = shutdown
        let cleanup = Task {
            await connection.close()
            if let shutdown { await shutdown() }
        }
        closingTask = cleanup
        await cleanup.value
    }

    private nonisolated func adapt(_ result: QueryConnection<Transport>.Response) -> AccessResult {
        switch result {
        case .rows(let rows): return .rows(RowStream(rows))
        case .rdfGraph(let graph): return .rdfGraph(GraphStream(graph))
        case .boolean(let value): return .boolean(value)
        case .command(let kind, let count): return .command(kind, affectedRows: count)
        case .copy(let bytes, let count): return .copy(bytes: bytes, affectedRows: count)
        case .block(let results): return .block(results.map(adapt))
        }
    }
}
