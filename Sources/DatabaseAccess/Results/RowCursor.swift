import DatabaseKit
import DatabaseTypes
import DatabaseWire

/// A fixed-result cursor whose witness retains the original iterator state.
public protocol RowCursor: Sendable {
    mutating func nextRow() async throws -> QueryRow?
}
