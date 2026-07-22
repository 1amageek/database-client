#if !os(WASI)
struct RetiredDatabaseRequestIDs: Sendable {
    private let capacity: Int
    private var identifiers: [UInt64] = []
    private var identifierSet: Set<UInt64> = []

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        identifiers.reserveCapacity(capacity)
    }

    func contains(_ identifier: UInt64) -> Bool {
        identifierSet.contains(identifier)
    }

    @discardableResult
    mutating func insert(_ identifier: UInt64) -> Bool {
        guard !identifierSet.contains(identifier) else {
            return true
        }
        guard identifiers.count < capacity else {
            return false
        }
        identifiers.append(identifier)
        identifierSet.insert(identifier)
        return true
    }

    mutating func removeAll() {
        identifiers.removeAll(keepingCapacity: true)
        identifierSet.removeAll(keepingCapacity: true)
    }
}
#endif
