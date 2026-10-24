import DatabaseKit

/// A named source retaining the exact database selected by its owner.
public struct EntitySource: QuerySource {
    let database: Database
    public let querySource: DataSource

    public func selectAll() -> QueryReference {
        QueryReference(database: database, definition: querySource.selectAll())
    }
    public func select(_ column: String, _ columns: String...) -> QueryReference {
        QueryReference(database: database, definition: querySource.select(columns: [column] + columns))
    }
    public func select(_ item: ProjectionItem, _ items: ProjectionItem...) -> QueryReference {
        QueryReference(database: database, definition: querySource.select(projection: [item] + items))
    }
}
