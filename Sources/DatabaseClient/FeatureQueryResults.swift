import Core

public struct VectorQueryResult<T: Persistable>: Sendable {
    public let items: [(item: T, distance: Double)]
    public let continuation: String?

    public var hasMore: Bool {
        continuation != nil
    }

    public init(items: [(item: T, distance: Double)], continuation: String?) {
        self.items = items
        self.continuation = continuation
    }
}

public struct FullTextQueryResult<T: Persistable>: Sendable {
    public let items: [T]
    public let continuation: String?

    public var hasMore: Bool {
        continuation != nil
    }

    public init(items: [T], continuation: String?) {
        self.items = items
        self.continuation = continuation
    }
}

public struct FullTextScoredQueryResult<T: Persistable>: Sendable {
    public let items: [(item: T, score: Double)]
    public let continuation: String?

    public var hasMore: Bool {
        continuation != nil
    }

    public init(items: [(item: T, score: Double)], continuation: String?) {
        self.items = items
        self.continuation = continuation
    }
}

public struct FullTextFacetedQueryResult<T: Persistable>: Sendable {
    public let items: [T]
    public let facets: [String: [(value: String, count: Int64)]]
    public let totalCount: Int
    public let continuation: String?

    public var hasMore: Bool {
        continuation != nil
    }

    public init(
        items: [T],
        facets: [String: [(value: String, count: Int64)]],
        totalCount: Int,
        continuation: String?
    ) {
        self.items = items
        self.facets = facets
        self.totalCount = totalCount
        self.continuation = continuation
    }
}
