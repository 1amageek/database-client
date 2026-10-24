import DatabaseKit
import DatabaseWire

/// A long-lived, generation-bound application database handle.
public final class Database: DatabaseQuerying {
    private static let shared = DatabaseDirectory()
    public let name: String
    private let generation: AccessGeneration
    let endpoint: any DatabaseExecuting

    init(name: String, generation: AccessGeneration, endpoint: any DatabaseExecuting) {
        self.name = name; self.generation = generation; self.endpoint = endpoint
    }

    public static func configure(databases: [String: DatabaseConfiguration]) async throws {
        try await shared.configure(databases: databases)
    }
    public static func database(_ name: String) throws(AccessError) -> Database { try shared.database(name) }
    public static func shutdown() async { await shared.shutdown() }

    public func execute(_ input: QueryInput, parameters: [QueryParameter] = [],
        options: QueryExecutionOptions = .init(), metadata: OperationRequestMetadata = .init()) async throws -> AccessResult {
        guard generation.isValid else { throw AccessError.closed(name) }
        return try await endpoint.execute(input, parameters: parameters, options: options, metadata: metadata)
    }
    public func execute(_ sql: SQL, options: QueryExecutionOptions = .init(),
        metadata: OperationRequestMetadata = .init()) async throws -> AccessResult {
        try await execute(.sql(sql.text), parameters: sql.parameters, options: options, metadata: metadata)
    }
    public func execute(_ statement: QueryStatement, parameters: [QueryParameter] = [],
        options: QueryExecutionOptions = .init(), metadata: OperationRequestMetadata = .init()) async throws -> AccessResult {
        try await execute(.statement(statement), parameters: parameters, options: options, metadata: metadata)
    }
    public func execute(_ block: SQLBlock, parameters: [QueryParameter] = [],
        options: QueryExecutionOptions = .init(), metadata: OperationRequestMetadata = .init()) async throws -> AccessResult {
        try await execute(.block(block), parameters: parameters, options: options, metadata: metadata)
    }
    public func execute(_ query: SelectQuery, parameters: [QueryParameter] = [],
        options: QueryExecutionOptions = .init(), metadata: OperationRequestMetadata = .init()) async throws -> AccessResult {
        try await execute(QueryStatement.select(query), parameters: parameters, options: options, metadata: metadata)
    }
    public func execute<Model>(_ query: Selection<Model>, parameters: [QueryParameter] = [],
        options: QueryExecutionOptions = .init(), metadata: OperationRequestMetadata = .init()) async throws -> AccessResult {
        try await execute(query.definition, parameters: parameters, options: options, metadata: metadata)
    }

    public func entity(_ name: String, schema: String? = nil) -> EntitySource {
        entity(TableRef(schema: schema, table: name))
    }
    public func entity(_ table: TableRef) -> EntitySource {
        EntitySource(database: self, querySource: table.querySource)
    }
    public func entity<Model: Persistable>(_ model: Model.Type) -> ModelEntitySource<Model> {
        ModelEntitySource(database: self, querySource: TableRef(Model.persistableType).querySource)
    }
}
