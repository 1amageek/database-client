/// Resolves an existing configured database without I/O or resource acquisition.
public protocol DatabaseProviding: Sendable {
    func database(_ name: String) throws(AccessError) -> Database
}
