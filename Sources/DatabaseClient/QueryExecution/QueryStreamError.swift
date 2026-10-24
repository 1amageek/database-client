/// A remote page violated the original result's delivery contract.
public enum QueryStreamError: Error, Sendable, Equatable {
    case unexpectedContinuation
    case unexpectedResultKind
    case changedColumns
    case changedMetadata
    case changedReadIdentity
    case continuationDidNotAdvance
    case pageLimitExceeded(actual: UInt64, maximum: UInt32)
    case emptyPageWithContinuation
}
