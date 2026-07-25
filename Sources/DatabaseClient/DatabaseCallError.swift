public import DatabaseWire

public enum DatabaseCallError: Error, Sendable, Equatable {
    case wire(DatabaseWireError)
    case remote(RemoteOperationError)
}
