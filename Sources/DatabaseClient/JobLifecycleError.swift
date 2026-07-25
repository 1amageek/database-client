public import DatabaseWire

public enum JobLifecycleError: Error, Sendable, Equatable {
    case mismatchedOperation(
        expected: JobOperationIdentifier,
        actual: JobOperationIdentifier
    )
    case mismatchedJob(
        expected: JobIdentity,
        actual: JobIdentity
    )
}
