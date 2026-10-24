import DatabaseKit
import DatabaseWire

/// Immutable canonical IR bound to one access identity and generation.
public struct QueryReference: Sendable {
    let database: Database
    public let definition: SelectQuery

    public func `where`(_ condition: Expression) -> Self {
        Self(database: database, definition: definition.where(condition))
    }
    public func orderBy(_ column: String, _ direction: SortDirection = .ascending) -> Self {
        Self(database: database, definition: definition.orderBy(column, direction))
    }
    public func limit(_ count: UInt64) -> Self { Self(database: database, definition: definition.limit(count)) }
    public func offset(_ count: UInt64) -> Self { Self(database: database, definition: definition.offset(count)) }

    public func join(_ source: EntitySource, on condition: Expression) throws(AccessError) -> Self {
        try joined(database: source.database, source: source.querySource, condition: condition)
    }
    public func join<Model>(_ source: ModelEntitySource<Model>, on condition: Expression) throws(AccessError) -> Self {
        try joined(database: source.database, source: source.querySource, condition: condition)
    }
    private func joined(database other: Database, source: DataSource, condition: Expression) throws(AccessError) -> Self {
        guard database === other else { throw .crossDatabaseReference }
        return Self(database: database, definition: definition.replacing(source: .join(JoinClause(
            type: .inner, left: definition.source, right: source, condition: .on(condition)))))
    }
    public func execute(parameters: [QueryParameter] = [], options: QueryExecutionOptions = .init(),
        metadata: OperationRequestMetadata = .init()) async throws -> AccessResult {
        try await database.execute(definition, parameters: parameters, options: options, metadata: metadata)
    }
}
