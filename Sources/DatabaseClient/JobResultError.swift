public import DatabaseWire

public enum JobResultError: Error, Sendable, Equatable {
    case mismatchedJob(
        expected: JobIdentity,
        actual: JobIdentity
    )
    case failed(RemoteOperationError)
    case cancelled(JobIdentity)
    case responseTooLarge(actual: UInt64, maximum: Int)
    case totalByteCountChanged(expected: UInt64, actual: UInt64)
    case digestChanged(
        expected: JobResultDigest,
        actual: JobResultDigest
    )
    case invalidContinuationJob(
        expected: JobIdentity,
        actual: JobIdentity
    )
    case invalidContinuationDigest
    case invalidContinuationIndex(expected: UInt32, actual: UInt32)
    case emptyPageWithContinuation
    case byteCountExceeded(expected: UInt64, actual: UInt64)
    case incompleteByteCount(expected: UInt64, actual: UInt64)
    case digestMismatch(
        expected: JobResultDigest,
        actual: JobResultDigest
    )
    case responseDecode(DatabaseWireError)
}
