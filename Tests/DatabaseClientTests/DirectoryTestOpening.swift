import DatabaseAccess

struct DirectoryTestOpening: DatabaseOpening {
    let body: @Sendable () async throws -> any DatabaseExecuting
    func open(maximumConcurrentExecutions: Int) async throws -> any DatabaseExecuting { try await body() }
}
