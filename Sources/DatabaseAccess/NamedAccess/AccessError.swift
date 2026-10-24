/// Named-access failures remain distinct from execution and adapter errors.
public enum AccessError: Error, Sendable {
    case notConfigured
    case configurationInProgress
    case alreadyConfigured
    case shuttingDown
    case nameNotFound(String)
    case invalidName(String)
    case closed(String)
    case initializationFailed(name: String, cause: any Error)
    case crossDatabaseReference
}
