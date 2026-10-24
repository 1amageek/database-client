import DatabaseKit
import DatabaseTypes
import DatabaseWire

/// A fixed-result cursor whose witness retains the original iterator state.
public protocol RowPageCursor: Sendable {
    mutating func nextRowPage() async throws -> QueryRowPage?
}
