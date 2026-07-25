public import DatabaseTypes

public protocol DatabaseTransport: Sendable {
    func send(
        _ request: ByteString
    ) async throws(DatabaseTransportError) -> ByteString
}
