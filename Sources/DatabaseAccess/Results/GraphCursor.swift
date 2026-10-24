import DatabaseKit
import DatabaseTypes
import DatabaseWire

/// A fixed-result cursor whose witness retains the original iterator state.
public protocol GraphCursor: Sendable {
    mutating func nextQuad() async throws -> RDFQuad?
}
