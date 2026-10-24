import DatabaseKit
import DatabaseTypes
import DatabaseWire

/// Retained values; pages additionally preserve original provenance and read metadata.
public struct QueryRowStream<Transport: DatabaseTransport>: QueryRows {
    private let page: QueryRowPage
    private let source: QueryPageSource<Transport>?
    init(page: QueryRowPage, source: QueryPageSource<Transport>?) { self.page = page; self.source = source }
    public static var empty: Self { Self(page: .empty, source: nil) }
    public var columns: [QueryColumn] { page.columns }
    public var affectedRows: UInt64? { page.affectedRows }
    public var metadata: FieldObject { page.metadata }
    public var pages: Pages { Pages(page: page, source: source) }
    public func makeAsyncIterator() -> Iterator { Iterator(pages: pages.makeAsyncIterator()) }

    public struct Iterator: AsyncIteratorProtocol, Sendable {
        private var pages: Pages.Iterator
        private var values: QueryRowIterator?
        private var finished = false
        fileprivate init(pages: Pages.Iterator) { self.pages = pages }
        public mutating func next() async throws -> QueryRow? {
            guard !finished else { return nil }
            do {
                while true {
                    if let value = try values?.next() { return value }
                    values = nil
                    guard let page = try await pages.next() else { finished = true; return nil }
                    values = page.makeRowIterator()
                }
            } catch { finished = true; values = nil; throw error }
        }
    }

    public struct Pages: AsyncSequence, Sendable {
        public typealias Element = QueryRowPage
        private let page: QueryRowPage
        private let source: QueryPageSource<Transport>?
        fileprivate init(page: QueryRowPage, source: QueryPageSource<Transport>?) { self.page = page; self.source = source }
        public func makeAsyncIterator() -> Iterator { Iterator(page: page, source: source) }

        public struct Iterator: AsyncIteratorProtocol, Sendable {
            private var first: QueryRowPage?
            private var continuation: ByteString?
            private var source: QueryPageSource<Transport>?
            private let columns: [QueryColumn]
            private let metadata: FieldObject
            private let affectedRows: UInt64?
            #if DATABASE_CLIENT_MULTI_BASE
            private let composition: CompositionResolution?
            private let consistency: DatabaseReadConsistency?
            #else
            private let snapshotVersion: UInt64?
            #endif
            fileprivate init(page: QueryRowPage, source: QueryPageSource<Transport>?) {
                first = page
                // Detach the small token instead of retaining a consumed bulk frame across I/O.
                continuation = page.continuation?.detached(); self.source = source
                columns = page.columns; metadata = page.metadata; affectedRows = page.affectedRows
                #if DATABASE_CLIENT_MULTI_BASE
                composition = page.provenance?.composition; consistency = page.consistency
                #else
                snapshotVersion = page.snapshotVersion
                #endif
            }
            public mutating func next() async throws -> QueryRowPage? {
                do {
                    if let first { self.first = nil; return first }
                    guard let token = continuation else { source = nil; return nil }
                    continuation = nil
                    guard let source else { throw QueryStreamError.unexpectedContinuation }
                    guard case .rows(let page) = try await source.fetch(after: token) else { throw QueryStreamError.unexpectedResultKind }
                    guard page.columns == columns else { throw QueryStreamError.changedColumns }
                    guard page.metadata == metadata, page.affectedRows == affectedRows else { throw QueryStreamError.changedMetadata }
                    #if DATABASE_CLIENT_MULTI_BASE
                    guard page.provenance?.composition == composition, page.consistency == consistency else { throw QueryStreamError.changedReadIdentity }
                    #else
                    guard page.snapshotVersion == snapshotVersion else { throw QueryStreamError.changedReadIdentity }
                    #endif
                    guard page.continuation != token else { throw QueryStreamError.continuationDidNotAdvance }
                    guard page.rowCount > 0 || page.continuation == nil else { throw QueryStreamError.emptyPageWithContinuation }
                    continuation = page.continuation?.detached()
                    return page
                } catch { first = nil; continuation = nil; source = nil; throw error }
            }
        }
    }
}
