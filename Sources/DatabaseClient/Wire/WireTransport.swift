/// Raw binary transport used by wire database clients.
public protocol WireTransport: Sendable {
    func send(_ request: [UInt8]) throws(ClientError) -> [UInt8]
}
