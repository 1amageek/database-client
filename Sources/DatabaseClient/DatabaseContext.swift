import Foundation
import Core
import QueryIR
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
    private let localSchema: Schema?

    /// Connect to a database server
    public init(
        configuration: ClientConfiguration,
        localSchema: Schema? = nil
    ) async throws {
        self.configuration = configuration
        self.pendingChanges = Mutex(ChangeSet())
        self.localSchema = localSchema

        let ws = WebSocketTransport(
            url: configuration.url,
            authToken: configuration.authToken,
            requestTimeout: configuration.timeout
        )
        try await ws.connect()
        self.transport = ws
    }

    /// Create with a custom transport (for testing)
    init(
        transport: any DatabaseTransport,
        configuration: ClientConfiguration = ClientConfiguration(url: URL(string: "ws://localhost")!),
        localSchema: Schema? = nil
    ) {
        self.transport = transport
        self.configuration = configuration
        self.pendingChanges = Mutex(ChangeSet())
        self.localSchema = localSchema
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
        try await save(options: .default)
    }

    /// Send all pending changes with retry and precondition metadata.
    public func save(options: SaveOptions) async throws {
        let changes = pendingChanges.withLock { cs -> [ChangeSet.Change] in
            let current = cs.changes
            cs.changes.removeAll()
            return current
        }

        guard !changes.isEmpty else { return }

        let saveReq = SaveRequest(
            changes: changes,
            preconditions: options.preconditions
        )
        let payload = try JSONEncoder().encode(saveReq)
        let envelope = ServiceEnvelope(
            operationID: "save",
            payload: payload,
            metadata: options.metadata
        )

        let response: ServiceEnvelope
        do {
            response = try await transport.send(envelope)
        } catch {
            // Restore changes on failure
            pendingChanges.withLock { $0.changes.append(contentsOf: changes) }
            throw error
        }

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

    /// Start building a polymorphic query from wire-safe group metadata.
    public func findPolymorphic(_ group: PolymorphicGroup) -> PolymorphicQueryBuilder {
        PolymorphicQueryBuilder(context: self, groupIdentifier: group.identifier)
    }

    /// Start building a polymorphic query from a logical group identifier.
    public func findPolymorphic(_ groupIdentifier: String) -> PolymorphicQueryBuilder {
        PolymorphicQueryBuilder(context: self, groupIdentifier: groupIdentifier)
    }

    /// Start a vector similarity query using the canonical read route.
    public func findSimilar<T: Persistable>(_ type: T.Type) -> VectorEntryPoint<T> {
        VectorEntryPoint(context: self)
    }

    /// Start a full-text query using the canonical read route.
    public func search<T: Persistable>(_ type: T.Type) -> FullTextEntryPoint<T> {
        FullTextEntryPoint(context: self)
    }

    /// Execute a canonical query and return wire-level rows.
    public func query(
        _ selectQuery: SelectQuery,
        options: ReadExecutionOptions = .default,
        partitionValues: [String: String]? = nil
    ) async throws -> QueryResponse {
        let request = QueryRequest(
            statement: .select(selectQuery),
            options: options,
            partitionValues: partitionValues
        )
        let payload = try JSONEncoder().encode(request)
        let envelope = ServiceEnvelope(operationID: "query", payload: payload)
        let response = try await transport.send(envelope)

        if response.isError == true {
            throw ServiceError(
                code: response.errorCode ?? "UNKNOWN",
                message: response.errorMessage ?? "Unknown error"
            )
        }

        return try JSONDecoder().decode(QueryResponse.self, from: response.payload)
    }

    /// Execute a canonical query and decode typed records with annotations.
    public func query<T: Persistable>(
        _ selectQuery: SelectQuery,
        as type: T.Type,
        options: ReadExecutionOptions = .default,
        partitionValues: [String: String]? = nil
    ) async throws -> AnnotatedQueryResult<T> {
        let response = try await query(
            selectQuery,
            options: options,
            partitionValues: partitionValues
        )
        let records: [AnnotatedRecord<T>] = try response.rows.map { row in
            AnnotatedRecord<T>(
                item: try FieldValueDecoder.decode(row.fields),
                annotations: row.annotations,
                version: row.version
            )
        }
        return AnnotatedQueryResult(
            records: records,
            continuation: response.continuation?.token,
            metadata: response.metadata
        )
    }

    /// Execute an extension operation by string identifier.
    ///
    /// This keeps feature-specific commands out of the core client API while
    /// still allowing domain SDKs to route typed commands through the same
    /// transport, timeout, cancellation, and error handling path.
    public func executeOperation<Request: Encodable, Response: Decodable>(
        _ operationID: String,
        request: Request,
        responseType: Response.Type = Response.self,
        metadata: [String: String] = [:]
    ) async throws -> Response {
        let payload = try JSONEncoder().encode(request)
        let envelope = ServiceEnvelope(
            operationID: operationID,
            payload: payload,
            metadata: metadata
        )
        let response = try await transport.send(envelope)

        if response.isError == true {
            throw ServiceError(
                code: response.errorCode ?? "UNKNOWN",
                message: response.errorMessage ?? "Unknown error"
            )
        }

        return try JSONDecoder().decode(Response.self, from: response.payload)
    }

    /// Execute a registered server-side command and return its decoded payload.
    public func executeCommand<Request: Encodable, Response: Decodable & Sendable>(
        _ commandID: String,
        request: Request,
        responseType: Response.Type = Response.self,
        idempotencyKey: IdempotencyKey? = nil,
        preconditions: [WritePreconditionEntry] = [],
        metadata: [String: String] = [:],
        envelopeMetadata: [String: String] = [:]
    ) async throws -> Response {
        try await executeCommandResult(
            commandID,
            request: request,
            responseType: responseType,
            idempotencyKey: idempotencyKey,
            preconditions: preconditions,
            metadata: metadata,
            envelopeMetadata: envelopeMetadata
        ).response
    }

    /// Execute a registered server-side command and return status, effects, and replay metadata.
    public func executeCommandResult<Request: Encodable, Response: Decodable & Sendable>(
        _ commandID: String,
        request: Request,
        responseType: Response.Type = Response.self,
        idempotencyKey: IdempotencyKey? = nil,
        preconditions: [WritePreconditionEntry] = [],
        metadata: [String: String] = [:],
        envelopeMetadata: [String: String] = [:]
    ) async throws -> ClientCommandResult<Response> {
        let command = CommandRequest(
            commandID: commandID,
            idempotencyKey: idempotencyKey,
            payload: try JSONEncoder().encode(request),
            preconditions: preconditions,
            metadata: metadata
        )
        let envelope = ServiceEnvelope(
            operationID: "command",
            payload: try JSONEncoder().encode(command),
            metadata: envelopeMetadata
        )
        let response = try await transport.send(envelope)

        if response.isError == true {
            throw ServiceError(
                code: response.errorCode ?? "UNKNOWN",
                message: response.errorMessage ?? "Unknown error"
            )
        }

        let commandResponse = try JSONDecoder().decode(CommandResponse.self, from: response.payload)
        let decodedPayload = try JSONDecoder().decode(Response.self, from: commandResponse.payload)
        return ClientCommandResult(
            status: commandResponse.status,
            response: decodedPayload,
            effects: commandResponse.effects,
            replayed: commandResponse.replayed
        )
    }

    /// Execute a typed command descriptor.
    public func execute<Response: Decodable & Sendable, Payload: Encodable & Sendable>(
        _ command: TypedCommand<Payload, Response>
    ) async throws -> Response {
        try await executeCommandResult(command).response
    }

    /// Execute a typed command descriptor and return command metadata.
    public func executeCommandResult<Response: Decodable & Sendable, Payload: Encodable & Sendable>(
        _ command: TypedCommand<Payload, Response>
    ) async throws -> ClientCommandResult<Response> {
        try await executeCommandResult(
            command.commandID,
            request: command.payload,
            responseType: command.responseType,
            idempotencyKey: command.idempotencyKey,
            preconditions: command.preconditions,
            metadata: command.metadata,
            envelopeMetadata: command.envelopeMetadata
        )
    }

    /// Get a single record by ID via canonical query execution.
    public func get<T: Persistable>(_ type: T.Type, id: String, partitionValues: [String: String]? = nil) async throws -> T? {
        let selectQuery = SelectQuery(
            projection: .all,
            source: .table(TableRef(table: T.persistableType)),
            filter: .equal(.column(ColumnRef(column: "id")), .literal(.string(id))),
            limit: 1
        )
        let result = try await query(selectQuery, as: type, partitionValues: partitionValues)
        return result.items.first
    }

    /// Fetch schema information from the server
    public func fetchSchema() async throws -> [Schema.Entity] {
        let response = try await fetchSchemaResponse()
        return response.entities
    }

    /// Fetch schema information including polymorphic groups.
    public func fetchSchemaResponse() async throws -> SchemaResponse {
        let envelope = ServiceEnvelope(operationID: "schema")
        let response = try await transport.send(envelope)

        if response.isError == true {
            throw ServiceError(
                code: response.errorCode ?? "UNKNOWN",
                message: response.errorMessage ?? "Unknown error"
            )
        }

        return try JSONDecoder().decode(SchemaResponse.self, from: response.payload)
    }

    /// Disconnect from the server
    public func disconnect() async {
        await transport.disconnect()
    }

    var schema: Schema? {
        localSchema
    }

    func decodePolymorphicRow(_ row: QueryRow, groupIdentifier: String) throws -> any Persistable {
        guard let typeName = row.annotations["_typeName"]?.stringValue else {
            throw ServiceError(
                code: "INVALID_RESPONSE",
                message: "Polymorphic query response is missing _typeName annotation."
            )
        }
        guard let schema = localSchema else {
            throw ServiceError(
                code: "SCHEMA_REQUIRED",
                message: "A local Schema is required to decode polymorphic results for '\(groupIdentifier)'."
            )
        }
        guard schema.polymorphicGroup(identifier: groupIdentifier) != nil else {
            throw ServiceError(
                code: "UNKNOWN_POLYMORPHIC_GROUP",
                message: "Polymorphic group '\(groupIdentifier)' is not registered in the local Schema."
            )
        }
        guard let type = schema.entity(named: typeName)?.persistableType else {
            throw ServiceError(
                code: "UNKNOWN_PERSISTABLE_TYPE",
                message: "Concrete type '\(typeName)' is not registered in the local Schema."
            )
        }
        return try FieldValueDecoder.decodeAny(row.fields, as: type)
    }

    func polymorphicTypeCode(
        groupIdentifier: String,
        typeName: String
    ) throws -> Int64 {
        guard let schema = localSchema else {
            throw ServiceError(
                code: "SCHEMA_REQUIRED",
                message: "A local Schema is required to resolve polymorphic type codes for '\(groupIdentifier)'."
            )
        }
        guard schema.polymorphicGroup(identifier: groupIdentifier) != nil else {
            throw ServiceError(
                code: "UNKNOWN_POLYMORPHIC_GROUP",
                message: "Polymorphic group '\(groupIdentifier)' is not registered in the local Schema."
            )
        }
        guard let type = schema.entity(named: typeName)?.persistableType,
              let polymorphicType = type as? any Polymorphable.Type else {
            throw ServiceError(
                code: "UNKNOWN_PERSISTABLE_TYPE",
                message: "Concrete type '\(typeName)' is not registered as a polymorphic member."
            )
        }
        return polymorphicType.typeCode(for: type.persistableType)
    }
}

/// Decoded command response returned by `executeCommandResult`.
public struct ClientCommandResult<Response: Sendable>: Sendable {
    public let status: String
    public let response: Response
    public let effects: [CommandEffect]
    public let replayed: Bool

    public init(
        status: String,
        response: Response,
        effects: [CommandEffect],
        replayed: Bool
    ) {
        self.status = status
        self.response = response
        self.effects = effects
        self.replayed = replayed
    }
}
