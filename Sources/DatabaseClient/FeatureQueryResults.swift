#if !os(WASI)
import Foundation
import Core

public struct RecordVersion: Sendable, Comparable, Hashable, Codable, CustomStringConvertible {
    public let bytes: Data

    public init(bytes: Data) {
        precondition(bytes.count == 10, "RecordVersion must be 10 bytes.")
        self.bytes = bytes
    }

    public static func < (lhs: RecordVersion, rhs: RecordVersion) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct PolymorphicRecordReference: Sendable, Equatable, Hashable, Codable {
    public let groupIdentifier: String
    public let typeName: String
    public let idComponents: [TupleQueryValue]

    public init(
        groupIdentifier: String,
        typeName: String,
        idComponents: [TupleQueryValue]
    ) {
        self.groupIdentifier = groupIdentifier
        self.typeName = typeName
        self.idComponents = idComponents
    }
}

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

public struct PolymorphicPermutedQueryResult: Sendable {
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

public struct PolymorphicVersionQueryResult: Sendable {
    public let items: [(version: RecordVersion, item: any Persistable)]
    public let continuation: String?

    public var hasMore: Bool {
        continuation != nil
    }

    public init(items: [(version: RecordVersion, item: any Persistable)], continuation: String?) {
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

#endif
