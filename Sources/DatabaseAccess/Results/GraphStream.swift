import DatabaseKit
import DatabaseTypes
import DatabaseWire

/// Lazy canonical values retaining their existing page or checked stream owner.
public struct GraphStream: PagedGraph {
    private enum Storage: Sendable {
        case page(RDFGraphPage)
        case source(any PagedGraph)
    }
    private let storage: Storage
    private init(storage: Storage) { self.storage = storage }

    public init(page: RDFGraphPage) throws(StreamAdaptationError) {
        guard page.continuation == nil else { throw .missingPageSource }
        storage = .page(page)
    }

    public init(_ source: any PagedGraph) { storage = .source(source) }


    public func makeAsyncIterator() -> Iterator {
        switch storage {
        case .page(let page): return Iterator(cursor: GraphRetainedCursor(iterator: page.makeQuadIterator()))
        case .source(let source): return Iterator(cursor: source.makeGraphCursor())
        }
    }
    public func makeGraphCursor() -> any GraphCursor { makeAsyncIterator() }
    public func makeGraphPageCursor() -> any GraphPageCursor { pages.makeAsyncIterator() }

    public var pages: Pages {
        switch storage {
        case .page(let page): return Pages(storage: .page(page))
        case .source(let source): return Pages(storage: .source(source))
        }
    }

    public struct Iterator: AsyncIteratorProtocol, GraphCursor {
        public typealias Failure = any Error
        private var cursor: any GraphCursor
        private var finished = false
        fileprivate init(cursor: any GraphCursor) { self.cursor = cursor }
        public mutating func nextQuad() async throws -> RDFQuad? { try await next() }
        public mutating func next(isolation actor: isolated (any Actor)?) async throws -> RDFQuad? { try await next() }
        public mutating func next() async throws -> RDFQuad? {
            guard !finished else { return nil }
            do {
                let value = try await cursor.nextQuad()
                if value == nil { finished = true }
                return value
            } catch { finished = true; throw error }
        }
    }

    public struct Pages: AsyncSequence, Sendable {
        public typealias Element = RDFGraphPage
        fileprivate enum Storage: Sendable {
            case page(RDFGraphPage)
            case source(any PagedGraph)
        }
        fileprivate let storage: Storage
        public func makeAsyncIterator() -> Iterator {
            switch storage {
            case .page(let page): return Iterator(cursor: GraphRetainedPageCursor(page: page))
            case .source(let source): return Iterator(cursor: source.makeGraphPageCursor())
            }
        }
        public struct Iterator: AsyncIteratorProtocol, GraphPageCursor {
            public typealias Failure = any Error
            private var cursor: any GraphPageCursor
            private var finished = false
            fileprivate init(cursor: any GraphPageCursor) { self.cursor = cursor }
            public mutating func nextGraphPage() async throws -> RDFGraphPage? { try await next() }
            public mutating func next(isolation actor: isolated (any Actor)?) async throws -> RDFGraphPage? { try await next() }
            public mutating func next() async throws -> RDFGraphPage? {
                guard !finished else { return nil }
                do {
                    let value = try await cursor.nextGraphPage()
                    if value == nil { finished = true }
                    return value
                } catch { finished = true; throw error }
            }
        }
    }
}

private struct GraphRetainedCursor: GraphCursor {
    var iterator: RDFQuadIterator
    mutating func nextQuad() async throws -> RDFQuad? { try iterator.next() }
}

private struct GraphRetainedPageCursor: GraphPageCursor {
    var page: RDFGraphPage?
    mutating func nextGraphPage() async throws -> RDFGraphPage? {
        defer { page = nil }
        return page
    }
}
