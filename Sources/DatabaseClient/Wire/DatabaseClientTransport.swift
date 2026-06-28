/// Raw binary transport used by wire database clients.
public protocol DatabaseClientTransport: Sendable {
    func send(_ request: [UInt8]) throws(DatabaseClientError) -> [UInt8]
}
