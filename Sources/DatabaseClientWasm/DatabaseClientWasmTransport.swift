/// Raw binary transport used by WASM database clients.
public protocol DatabaseClientWasmTransport: Sendable {
    func send(_ request: [UInt8]) throws(DatabaseClientWasmError) -> [UInt8]
}
