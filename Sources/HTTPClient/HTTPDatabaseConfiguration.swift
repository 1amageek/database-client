#if !os(WASI)
import Foundation
import DatabaseWire

public struct HTTPDatabaseConfiguration: Sendable {
    public let endpoint: URL
    public let accessToken: String
    public let databaseID: String
    public let tenantID: String?
    public let workspaceID: String?
    public let requestTimeout: TimeInterval
    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int

    public init(
        endpoint: URL,
        accessToken: String,
        databaseID: String = "main",
        tenantID: String? = nil,
        workspaceID: String? = nil,
        requestTimeout: TimeInterval = 30,
        maximumRequestBytes: Int =
            DatabaseWireLimits.default.maximumFrameBytes,
        maximumResponseBytes: Int =
            DatabaseWireLimits.default.maximumFrameBytes
    ) throws(HTTPDatabaseConfigurationError) {
        guard endpoint.scheme == "http" || endpoint.scheme == "https" else {
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

        self.endpoint = endpoint
        self.accessToken = accessToken
        self.databaseID = databaseID
        self.tenantID = tenantID
        self.workspaceID = workspaceID
        self.requestTimeout = requestTimeout
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
    }
}
#endif
