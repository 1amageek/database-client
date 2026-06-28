#if !os(WASI)
import Core
import DatabaseClient
import Foundation

/// Configuration for WebSocket database clients.
public struct WebSocketConfiguration: Sendable {

    /// Server URL for the WebSocket endpoint.
    public let url: URL

    /// Authentication token.
    public let authToken: String?

    /// Request timeout.
    public let requestTimeout: TimeInterval

    public init(
        url: URL,
        authToken: String? = nil,
        requestTimeout: TimeInterval = 30
    ) {
        self.url = url
        self.authToken = authToken
        self.requestTimeout = requestTimeout
    }
}

public extension DatabaseContext {
    convenience init(
        webSocket configuration: WebSocketConfiguration,
        localSchema: Schema? = nil
    ) async throws {
        let transport = URLSessionWebSocketTransport(
            url: configuration.url,
            authToken: configuration.authToken,
            requestTimeout: configuration.requestTimeout
        )
        try await transport.connect()
        self.init(transport: transport, localSchema: localSchema)
    }
}

#endif
