@_exported import DatabaseKit
@_exported import DatabaseWire

public extension DatabaseSessionClient {
    /// Opens a bounded invocation scope over this session's existing transport and target.
    func openConnection(maximumConcurrentExecutions: Int = 1) async throws -> QueryConnection<Transport> {
        guard maximumConcurrentExecutions > 0 else { throw QueryConnectionError.invalidConcurrencyLimit }
        return QueryConnection(session: self, concurrencyLimit: maximumConcurrentExecutions)
    }
}

public extension DatabaseClient {
    func openConnection(maximumConcurrentExecutions: Int = 1) async throws -> QueryConnection<Transport> {
        try await database.openConnection(maximumConcurrentExecutions: maximumConcurrentExecutions)
    }
}
