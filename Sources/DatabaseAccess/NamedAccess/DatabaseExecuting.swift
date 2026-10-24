import DatabaseKit
import DatabaseWire

/// An owned logical execution scope; its adapter retains resource ownership.
public protocol DatabaseExecuting: Sendable {
    func execute(_ input: QueryInput, parameters: [QueryParameter],
        options: QueryExecutionOptions, metadata: OperationRequestMetadata) async throws -> AccessResult
    func close() async
}
