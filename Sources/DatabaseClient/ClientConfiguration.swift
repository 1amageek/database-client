import Foundation

/// Configuration for connecting to a database server
public struct ClientConfiguration: Sendable {

    /// Server URL (WebSocket endpoint)
    public let url: URL

    /// Authentication token
    public let authToken: String?

    /// Retry policy for failed requests
    public let retryPolicy: RetryPolicy

    /// Default request timeout
    public let timeout: TimeInterval

    public init(
        url: URL,
        authToken: String? = nil,
        retryPolicy: RetryPolicy = .default,
        timeout: TimeInterval = 30
    ) {
        self.url = url
        self.authToken = authToken
        self.retryPolicy = retryPolicy
        self.timeout = timeout
    }

    /// Retry policy configuration
    public struct RetryPolicy: Sendable {
        /// Maximum number of retry attempts
        public let maxRetries: Int

        /// Base delay between retries (exponential backoff)
        public let backoffBase: TimeInterval

        public init(maxRetries: Int = 3, backoffBase: TimeInterval = 0.5) {
            self.maxRetries = maxRetries
            self.backoffBase = backoffBase
        }

        public static let `default` = RetryPolicy()
        public static let none = RetryPolicy(maxRetries: 0)
    }
}
