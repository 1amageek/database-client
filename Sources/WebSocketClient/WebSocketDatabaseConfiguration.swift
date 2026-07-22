#if !os(WASI)
import DatabaseWire
import Foundation

public struct WebSocketDatabaseConfiguration: Sendable {
    public let endpoint: URL
    public let accessToken: String
    public let databaseID: String
    public let requestTimeout: TimeInterval
    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int
    public let maximumRetiredRequestIDsPerConnection: Int

    public init(
        endpoint: URL,
        accessToken: String,
        databaseID: String = "main",
        requestTimeout: TimeInterval = 30,
        maximumRequestBytes: Int =
            DatabaseWireLimits.default.maximumFrameBytes,
        maximumResponseBytes: Int =
            DatabaseWireLimits.default.maximumFrameBytes,
        maximumRetiredRequestIDsPerConnection: Int = 1_024
    ) throws(WebSocketDatabaseConfigurationError) {
        guard endpoint.scheme == "ws" || endpoint.scheme == "wss" else {
            throw .unsupportedScheme(endpoint.scheme)
        }
        guard !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .emptyAccessToken
        }
        guard !databaseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .emptyDatabaseID
        }
        guard requestTimeout.isFinite,
              requestTimeout > 0 else {
            throw .invalidRequestTimeout
        }
        guard maximumRequestBytes > 0 else {
            throw .invalidMaximumRequestBytes
        }
        guard maximumResponseBytes > 0 else {
            throw .invalidMaximumResponseBytes
        }
        guard maximumRetiredRequestIDsPerConnection > 0 else {
            throw .invalidMaximumRetiredRequestIDsPerConnection
        }

        self.endpoint = endpoint
        self.accessToken = accessToken
        self.databaseID = databaseID
        self.requestTimeout = requestTimeout
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumRetiredRequestIDsPerConnection =
            maximumRetiredRequestIDsPerConnection
    }
}
#endif
