#if !os(WASI)
import DatabaseClientProtocol

/// In-process transport for testing without network
///
/// Allows unit testing of DatabaseContext by providing a handler closure
/// that processes ServiceEnvelope directly.
public final class InProcessTransport: Transport, Sendable {

    private let handler: @Sendable (ServiceEnvelope) async throws -> ServiceEnvelope

    public init(handler: @escaping @Sendable (ServiceEnvelope) async throws -> ServiceEnvelope) {
        self.handler = handler
    }

    public func send(_ envelope: ServiceEnvelope) async throws -> ServiceEnvelope {
        try await handler(envelope)
    }

    public func disconnect() async {
        // No-op for in-process
    }
}

#endif
