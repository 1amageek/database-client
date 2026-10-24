import DatabaseKit
import DatabaseWire

/// Executes canonical input under one fixed authorization and resource scope.
public protocol DatabaseQuerying: Sendable {
    func execute(_ input: QueryInput, parameters: [QueryParameter],
        options: QueryExecutionOptions, metadata: OperationRequestMetadata) async throws -> AccessResult
}
