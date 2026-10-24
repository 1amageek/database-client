import DatabaseKit

/// A bound source whose fluent fields are restricted to one compiled model.
public struct ModelEntitySource<Model: Persistable>: QuerySource {
    let database: Database
    public let querySource: DataSource

    public func selectAll() -> ModelQueryReference<Model> {
        ModelQueryReference(database: database, selection: Selection(definition: querySource.selectAll()))
    }
    public func select<each Value>(_ fields: repeat Field<Model, each Value>) throws -> ModelQueryReference<Model> {
        var identities: [FieldIdentity] = []
        repeat identities.append((each fields).identity)
        let selection = try Selection<Model>(definition: querySource.selectAll()).select(fields: identities)
        return ModelQueryReference(database: database, selection: selection)
    }
}
