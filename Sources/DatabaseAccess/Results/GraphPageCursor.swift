import DatabaseKit
import DatabaseTypes
import DatabaseWire

/// A fixed-result cursor whose witness retains the original iterator state.
public protocol GraphPageCursor: Sendable {
    mutating func nextGraphPage() async throws -> RDFGraphPage?
}
