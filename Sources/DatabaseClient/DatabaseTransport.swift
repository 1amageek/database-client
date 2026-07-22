public import DatabaseValue

public protocol DatabaseTransport: Sendable {
    func send(
        _ request: DatabaseBytes
    ) async throws(DatabaseTransportError) -> DatabaseBytes
}
