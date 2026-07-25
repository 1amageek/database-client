public enum DatabaseClientError: Error, Sendable, Equatable {
    case requestIdentifierExhausted
    case transport(DatabaseTransportError)
    case call(DatabaseCallError)
    case jobLifecycle(JobLifecycleError)
    case jobResult(JobResultError)
}
