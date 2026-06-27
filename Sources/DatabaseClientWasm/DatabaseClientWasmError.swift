import DatabaseKitWasmCore

/// Errors raised by the WASM database client facade.
public enum DatabaseClientWasmError: Error, Sendable, Equatable {
    case wire(DatabaseKitWasmWireError)
    case remoteFailure(status: DatabaseKitWasmResponseStatus, message: String)
    case unexpectedResponse(DatabaseKitWasmResponse)
}
