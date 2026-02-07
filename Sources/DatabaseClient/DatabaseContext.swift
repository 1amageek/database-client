import Foundation
import Core
import DatabaseClientProtocol
import Synchronization

/// Client-side database context mirroring FDBContext API
///
/// Provides typed, KeyPath-based CRUD and query operations.
/// Internally communicates with the server via ServiceEnvelope messages.
///
/// Usage:
/// ```swift
/// let config = ClientConfiguration(url: serverURL, authToken: "sk-xxx")
/// let context = try await DatabaseContext(configuration: config)
///
/// context.insert(User(name: "Alice", age: 30))
/// try await context.save()
///
/// let users = try await context.find(User.self)
///     .where(\.age > 20)
///     .execute()
/// ```
public final class DatabaseContext: Sendable {

    private let transport: any DatabaseTransport
    private let configuration: ClientConfiguration
    private let pendingChanges: Mutex<ChangeSet>

    /// Connect to a database server
    public init(configuration: ClientConfiguration) async throws {
        self.configuration = configuration
        self.pendingChanges = Mutex(ChangeSet())

        let ws = WebSocketTransport(url: configuration.url, authToken: configuration.authToken)
        try await ws.connect()
        self.transport = ws
    }

    /// Create with a custom transport (for testing)
    init(transport: any DatabaseTransport, configuration: ClientConfiguration = ClientConfiguration(url: URL(string: "ws://localhost")!)) {
        self.transport = transport
        self.configuration = configuration
        self.pendingChanges = Mutex(ChangeSet())
    }

    // MARK: - Change Tracking (FDBContext compatible)

    /// Stage an item for insertion
    public func insert<T: Persistable>(_ item: T) throws {
        let change = ChangeSet.Change(
            entityName: T.persistableType,
            id: FieldValueDecoder.idString(item),
            operation: .insert,
            fields: try FieldValueDecoder.encode(item)
        )
        pendingChanges.withLock { $0.changes.append(change) }
    }

    /// Stage an item for update
    public func update<T: Persistable>(_ item: T) throws {
        let change = ChangeSet.Change(
            entityName: T.persistableType,
            id: FieldValueDecoder.idString(item),
            operation: .update,
            fields: try FieldValueDecoder.encode(item)
        )
        pendingChanges.withLock { $0.changes.append(change) }
    }

    /// Stage an item for deletion
    public func delete<T: Persistable>(_ item: T) {
        let change = ChangeSet.Change(
            entityName: T.persistableType,
            id: FieldValueDecoder.idString(item),
            operation: .delete
        )
        pendingChanges.withLock { $0.changes.append(change) }
    }

    /// Send all pending changes to the server atomically
    public func save() async throws {
        let changes = pendingChanges.withLock { cs -> [ChangeSet.Change] in
            let current = cs.changes
            cs.changes.removeAll()
            return current
        }

        guard !changes.isEmpty else { return }

        let saveReq = SaveRequest(changes: changes)
        let payload = try JSONEncoder().encode(saveReq)
        let envelope = ServiceEnvelope(operationID: "save", payload: payload)
        let response = try await transport.send(envelope)

        if response.isError == true {
            // Restore changes on failure
            pendingChanges.withLock { $0.changes.append(contentsOf: changes) }
            throw ServiceError(
                code: response.errorCode ?? "SAVE_FAILED",
                message: response.errorMessage ?? "Failed to save changes"
            )
        }
    }

    /// Discard all pending changes
    public func clearChanges() {
        pendingChanges.withLock { $0.changes.removeAll() }
    }

    // MARK: - Query

    /// Start building a query for the given type
    public func find<T: Persistable>(_ type: T.Type) -> QueryBuilder<T> {
        QueryBuilder<T>(transport: transport, entityName: T.persistableType)
    }

    /// Get a single record by ID
    public func get<T: Persistable>(_ type: T.Type, id: String, partitionValues: [String: String]? = nil) async throws -> T? {
        let getReq = GetRequest(entityName: T.persistableType, id: id, partitionValues: partitionValues)
        let payload = try JSONEncoder().encode(getReq)
        let envelope = ServiceEnvelope(operationID: "get", payload: payload)
        let response = try await transport.send(envelope)

        if response.isError == true {
            throw ServiceError(
                code: response.errorCode ?? "UNKNOWN",
                message: response.errorMessage ?? "Unknown error"
            )
        }

        let getResponse = try JSONDecoder().decode(GetResponse.self, from: response.payload)
        guard let dict = getResponse.record else { return nil }
        return try FieldValueDecoder.decode(dict)
    }

    /// Fetch schema information from the server
    public func fetchSchema() async throws -> [Schema.Entity] {
        let envelope = ServiceEnvelope(operationID: "schema")
        let response = try await transport.send(envelope)

        if response.isError == true {
            throw ServiceError(
                code: response.errorCode ?? "UNKNOWN",
                message: response.errorMessage ?? "Unknown error"
            )
        }

        let schemaResponse = try JSONDecoder().decode(SchemaResponse.self, from: response.payload)
        return schemaResponse.entities
    }

    /// Disconnect from the server
    public func disconnect() async {
        await transport.disconnect()
    }
}
