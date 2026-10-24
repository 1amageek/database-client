/// Acquires one logical scope and cleans up its own partial acquisition on failure.
public protocol DatabaseOpening: Sendable {
    func open(maximumConcurrentExecutions: Int) async throws -> any DatabaseExecuting
}
