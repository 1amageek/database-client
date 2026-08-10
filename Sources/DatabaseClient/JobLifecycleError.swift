public import DatabaseWire

public enum JobLifecycleError: Error, Sendable, Equatable {
    case mismatchedJob(
        expected: JobIdentity,
        actual: JobIdentity
    )
}
