import DatabaseKit
import DatabaseWire

/// Typed construction remains in Kit; this value retains only its access binding.
public struct ModelQueryReference<Model: Persistable>: Sendable {
    let database: Database
    let selection: Selection<Model>
    public var definition: SelectQuery { selection.definition }

    public func `where`(_ predicate: Predicate<Model>) throws -> Self {
        Self(database: database, selection: try selection.where(predicate))
    }
    public func orderBy<Value>(_ field: Field<Model, Value>, _ direction: SortDirection = .ascending) throws -> Self {
        Self(database: database, selection: try selection.orderBy(field, direction))
    }
    public func limit(_ count: UInt64) -> Self { Self(database: database, selection: selection.limit(count)) }
    public func offset(_ count: UInt64) -> Self { Self(database: database, selection: selection.offset(count)) }
    public func execute(parameters: [QueryParameter] = [], options: QueryExecutionOptions = .init(),
        metadata: OperationRequestMetadata = .init()) async throws -> AccessResult {
        try await database.execute(definition, parameters: parameters, options: options, metadata: metadata)
    }
}
