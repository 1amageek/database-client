public import DatabaseWire

public enum DatabaseJobLifecycleError: Error, Sendable, Equatable {
    case mismatchedOperation(
        expected: DatabaseJobOperationIdentifier,
        actual: DatabaseJobOperationIdentifier
    )
    case mismatchedJob(
        expected: DatabaseJobIdentity,
        actual: DatabaseJobIdentity
    )
}
