public import DatabaseWire

public enum DatabaseJobResultError: Error, Sendable, Equatable {
    case mismatchedJob(
        expected: DatabaseJobIdentity,
        actual: DatabaseJobIdentity
    )
    case failed(DatabaseRemoteError)
    case cancelled(DatabaseJobIdentity)
    case responseTooLarge(actual: UInt64, maximum: Int)
    case totalByteCountChanged(expected: UInt64, actual: UInt64)
    case digestChanged(
        expected: DatabaseJobResultDigest,
        actual: DatabaseJobResultDigest
    )
    case invalidContinuationJob(
        expected: DatabaseJobIdentity,
        actual: DatabaseJobIdentity
    )
    case invalidContinuationDigest
    case invalidContinuationIndex(expected: UInt32, actual: UInt32)
    case emptyPageWithContinuation
    case byteCountExceeded(expected: UInt64, actual: UInt64)
    case incompleteByteCount(expected: UInt64, actual: UInt64)
    case digestMismatch(
        expected: DatabaseJobResultDigest,
        actual: DatabaseJobResultDigest
    )
    case responseDecode(DatabaseWireError)
}
