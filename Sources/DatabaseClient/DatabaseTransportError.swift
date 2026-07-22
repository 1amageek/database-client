public enum DatabaseTransportError: Error, Sendable, Equatable {
    case unavailable(String)
    case timeout
    case cancelled
    case rejected(code: String, message: String)
    case invalidRequest(String)
    case invalidResponse(String)
}
