#if os(WASI)
public enum JavaScriptDatabaseConfigurationError:
    Error,
    Sendable,
    Equatable {
    case emptyRequestEntrypointName
    case invalidRequestTimeoutMilliseconds
    case invalidMaximumRequestBytes
    case invalidMaximumResponseBytes
}
#endif
