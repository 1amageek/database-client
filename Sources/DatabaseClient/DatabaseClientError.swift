public enum DatabaseClientError: Error, Sendable, Equatable {
    case transport(DatabaseTransportError)
    case call(DatabaseCallError)
    case jobLifecycle(DatabaseJobLifecycleError)
    case jobResult(DatabaseJobResultError)
}
