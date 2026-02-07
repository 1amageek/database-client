import DatabaseClientProtocol

/// Internal transport abstraction for client-server communication
///
/// Hidden from the user. Implementations handle the actual network communication.
protocol DatabaseTransport: Sendable {
    func send(_ envelope: ServiceEnvelope) async throws -> ServiceEnvelope
    func disconnect() async
}
