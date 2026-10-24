import DatabaseKit
import DatabaseWire

/// One coherent value stream, its original pages and fixed-result cursor witnesses.
public protocol PagedRows: QueryRows {
    associatedtype Pages: AsyncSequence & Sendable where Pages.Element == QueryRowPage
    var pages: Pages { get }
    func makeRowCursor() -> any RowCursor
    func makeRowPageCursor() -> any RowPageCursor
}
