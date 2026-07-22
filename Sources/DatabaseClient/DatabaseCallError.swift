public import DatabaseWire

public enum DatabaseCallError: Error, Sendable, Equatable {
    case wire(DatabaseWireError)
    case remote(DatabaseRemoteError)
    case mismatchedRequestID(expected: UInt64, actual: UInt64)
    case mismatchedOperation(
        expected: DatabaseOperationIdentifier,
        actual: DatabaseOperationIdentifier
    )
}
