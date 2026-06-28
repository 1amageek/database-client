#if !os(WASI)
import DatabaseClientProtocol

/// Transport boundary used by `DatabaseContext`.
///
/// Implementations may use WebSocket, in-process calls, JavaScript bridges,
/// or any other runtime-specific mechanism.
public protocol Transport: Sendable {
    func send(_ envelope: ServiceEnvelope) async throws -> ServiceEnvelope
    func disconnect() async
}

#endif
