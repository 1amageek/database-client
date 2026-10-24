import DatabaseKit
import DatabaseTypes
import DatabaseWire

/// Lazy canonical values retaining their existing page or checked stream owner.
public struct RowStream: PagedRows {
    private enum Storage: Sendable {
        case page(QueryRowPage)
        case source(any PagedRows)
    }
    private let storage: Storage
    private init(storage: Storage) { self.storage = storage }

    public init(page: QueryRowPage) throws(StreamAdaptationError) {
        guard page.continuation == nil else { throw .missingPageSource }
        storage = .page(page)
    }

    public init(_ source: any PagedRows) { storage = .source(source) }

    public static var empty: Self { Self(storage: .page(.empty)) }
    public var columns: [QueryColumn] {
        switch storage { case .page(let page): return page.columns; case .source(let source): return source.columns }
    }
    public var affectedRows: UInt64? {
        switch storage { case .page(let page): return page.affectedRows; case .source(let source): return source.affectedRows }
    }
    public var metadata: FieldObject {
        switch storage { case .page(let page): return page.metadata; case .source(let source): return source.metadata }
    }

    public func makeAsyncIterator() -> Iterator {
        switch storage {
        case .page(let page): return Iterator(cursor: RowRetainedCursor(iterator: page.makeRowIterator()))
        case .source(let source): return Iterator(cursor: source.makeRowCursor())
        }
    }
    public func makeRowCursor() -> any RowCursor { makeAsyncIterator() }
    public func makeRowPageCursor() -> any RowPageCursor { pages.makeAsyncIterator() }

    public var pages: Pages {
        switch storage {
        case .page(let page): return Pages(storage: .page(page))
        case .source(let source): return Pages(storage: .source(source))
        }
    }

    public struct Iterator: AsyncIteratorProtocol, RowCursor {
        public typealias Failure = any Error
        private var cursor: any RowCursor
        private var finished = false
        fileprivate init(cursor: any RowCursor) { self.cursor = cursor }
        public mutating func nextRow() async throws -> QueryRow? { try await next() }
        public mutating func next(isolation actor: isolated (any Actor)?) async throws -> QueryRow? { try await next() }
        public mutating func next() async throws -> QueryRow? {
            guard !finished else { return nil }
            do {
                let value = try await cursor.nextRow()
                if value == nil { finished = true }
                return value
            } catch { finished = true; throw error }
        }
    }

    public struct Pages: AsyncSequence, Sendable {
        public typealias Element = QueryRowPage
        fileprivate enum Storage: Sendable {
            case page(QueryRowPage)
            case source(any PagedRows)
        }
        fileprivate let storage: Storage
        public func makeAsyncIterator() -> Iterator {
            switch storage {
            case .page(let page): return Iterator(cursor: RowRetainedPageCursor(page: page))
            case .source(let source): return Iterator(cursor: source.makeRowPageCursor())
            }
        }
        public struct Iterator: AsyncIteratorProtocol, RowPageCursor {
            public typealias Failure = any Error
            private var cursor: any RowPageCursor
            private var finished = false
            fileprivate init(cursor: any RowPageCursor) { self.cursor = cursor }
            public mutating func nextRowPage() async throws -> QueryRowPage? { try await next() }
            public mutating func next(isolation actor: isolated (any Actor)?) async throws -> QueryRowPage? { try await next() }
            public mutating func next() async throws -> QueryRowPage? {
                guard !finished else { return nil }
                do {
                    let value = try await cursor.nextRowPage()
                    if value == nil { finished = true }
                    return value
                } catch { finished = true; throw error }
            }
        }
    }
}

private struct RowRetainedCursor: RowCursor {
    var iterator: QueryRowIterator
    mutating func nextRow() async throws -> QueryRow? { try iterator.next() }
}

private struct RowRetainedPageCursor: RowPageCursor {
    var page: QueryRowPage?
    mutating func nextRowPage() async throws -> QueryRowPage? {
        defer { page = nil }
        return page
    }
}
