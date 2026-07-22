#if os(WASI)
public enum WorkerDatabaseConfigurationError:
    Error,
    Sendable,
    Equatable {
    case emptyRequestEntrypointName
    case invalidRequestTimeoutMilliseconds
    case invalidMaximumRequestBytes
    case invalidMaximumResponseBytes
}
#endif
