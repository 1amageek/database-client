#if !os(WASI)
public enum WebSocketDatabaseConfigurationError: Error, Sendable, Equatable {
    case unsupportedScheme(String?)
    case emptyAccessToken
    case emptyDatabaseID
    case invalidRequestTimeout
    case invalidMaximumRequestBytes
    case invalidMaximumResponseBytes
    case invalidMaximumRetiredRequestIDsPerConnection
}
#endif
