import DatabaseKitWasmCore

/// Errors raised by the wire database client facade.
public enum DatabaseClientError: Error, Sendable, Equatable {
    case wire(DatabaseKitWasmWireError)
    case remoteFailure(status: DatabaseKitWasmResponseStatus, message: String)
    case unexpectedResponse(DatabaseKitWasmResponse)
}
