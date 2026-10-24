import DatabaseKit
import DatabaseWire

/// One coherent value stream, its original pages and fixed-result cursor witnesses.
public protocol PagedGraph: QueryGraph {
    associatedtype Pages: AsyncSequence & Sendable where Pages.Element == RDFGraphPage
    var pages: Pages { get }
    func makeGraphCursor() -> any GraphCursor
    func makeGraphPageCursor() -> any GraphPageCursor
}
