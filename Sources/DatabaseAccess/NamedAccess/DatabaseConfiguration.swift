/// Immutable acquisition settings; ownership is supplied by its adapter opener.
public struct DatabaseConfiguration: Sendable {
    public let maximumConcurrentExecutions: Int
    private let opening: any DatabaseOpening

    public init(opening: any DatabaseOpening, maximumConcurrentExecutions: Int) throws(AccessConfigurationError) {
        guard maximumConcurrentExecutions > 0 else { throw .invalidConcurrencyLimit(maximumConcurrentExecutions) }
        self.opening = opening
        self.maximumConcurrentExecutions = maximumConcurrentExecutions
    }

    public func open() async throws -> any DatabaseExecuting {
        try await opening.open(maximumConcurrentExecutions: maximumConcurrentExecutions)
    }
}
