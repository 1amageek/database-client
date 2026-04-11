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

public struct PolymorphicVectorQueryResult: Sendable {
    public let items: [(item: any Persistable, distance: Double)]
    public let continuation: String?

    public var hasMore: Bool {
        continuation != nil
    }

    public init(items: [(item: any Persistable, distance: Double)], continuation: String?) {
        self.items = items
        self.continuation = continuation
    }
}

public struct PolymorphicRankQueryResult: Sendable {
    public let items: [(item: any Persistable, rank: Int)]
    public let continuation: String?

    public var hasMore: Bool {
        continuation != nil
    }

    public init(items: [(item: any Persistable, rank: Int)], continuation: String?) {
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

public struct PolymorphicFullTextQueryResult: Sendable {
    public let items: [any Persistable]
    public let continuation: String?

    public var hasMore: Bool {
        continuation != nil
    }

    public init(items: [any Persistable], continuation: String?) {
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

public struct PolymorphicFullTextScoredQueryResult: Sendable {
    public let items: [(item: any Persistable, score: Double)]
    public let continuation: String?

    public var hasMore: Bool {
        continuation != nil
    }

    public init(items: [(item: any Persistable, score: Double)], continuation: String?) {
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

public struct PolymorphicFullTextFacetedQueryResult: Sendable {
    public let items: [any Persistable]
    public let facets: [String: [(value: String, count: Int64)]]
    public let totalCount: Int
    public let continuation: String?

    public var hasMore: Bool {
        continuation != nil
    }

    public init(
        items: [any Persistable],
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
