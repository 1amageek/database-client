import DatabaseWire

/// Errors raised by the wire database client facade.
public enum ClientError: Error, Sendable, Equatable {
    case wire(DatabaseWireError)
    case remoteFailure(status: DatabaseWireResponseStatus, message: String)
    case unexpectedResponse(DatabaseWireResponse)
}
