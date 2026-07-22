#if !os(WASI)
public enum HTTPDatabaseConfigurationError: Error, Sendable, Equatable {
    case unsupportedScheme(String?)
    case emptyAccessToken
    case emptyDatabaseID
    case invalidRequestTimeout
    case invalidMaximumRequestBytes
    case invalidMaximumResponseBytes
}
#endif
