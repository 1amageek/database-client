import DatabaseTypes
import DatabaseWire

/// Preserves the exact invocation while retrieving its read-only continuation.
struct QueryPageSource<Transport: DatabaseTransport>: Sendable {
    let connection: QueryConnection<Transport>
    let request: QueryExecuteOperation.Request
    let metadata: OperationRequestMetadata

    func fetch(after continuation: ByteString) async throws -> QueryExecuteOperation.Response {
        guard let page = request.page else { throw QueryStreamError.unexpectedContinuation }
        return try await connection.invoke(.init(input: request.input, parameters: request.parameters,
            graphPartitions: request.graphPartitions,
            page: .init(limit: page.limit, continuation: continuation), budget: request.budget), metadata: metadata)
    }
}
