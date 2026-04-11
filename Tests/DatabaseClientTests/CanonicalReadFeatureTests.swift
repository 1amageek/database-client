import Testing
import Foundation
import Core
import QueryIR
import DatabaseClientProtocol
import Vector
@testable import DatabaseClient

struct VectorDocument: Persistable, Codable, Sendable {
    typealias ID = String

    var id: String = UUID().uuidString
    var title: String = ""
    var embedding: [Float] = []

    static var persistableType: String { "VectorDocument" }
    static var allFields: [String] { ["id", "title", "embedding"] }

    static func fieldNumber(for fieldName: String) -> Int? {
        switch fieldName {
        case "id": return 1
        case "title": return 2
        case "embedding": return 3
        default: return nil
        }
    }

    static func enumMetadata(for fieldName: String) -> EnumMetadata? { nil }

    subscript(dynamicMember member: String) -> (any Sendable)? {
        switch member {
        case "id": return id
        case "title": return title
        case "embedding": return embedding
        default: return nil
        }
    }

    static func fieldName<Value>(for keyPath: KeyPath<VectorDocument, Value>) -> String {
        if keyPath == \VectorDocument.id { return "id" }
        if keyPath == \VectorDocument.title { return "title" }
        if keyPath == \VectorDocument.embedding { return "embedding" }
        return "\(keyPath)"
    }

    static func fieldName(for keyPath: PartialKeyPath<VectorDocument>) -> String {
        if keyPath == \VectorDocument.id { return "id" }
        if keyPath == \VectorDocument.title { return "title" }
        if keyPath == \VectorDocument.embedding { return "embedding" }
        return "\(keyPath)"
    }

    static func fieldName(for keyPath: AnyKeyPath) -> String {
        if let partial = keyPath as? PartialKeyPath<VectorDocument> {
            return fieldName(for: partial)
        }
        return "\(keyPath)"
    }
}

struct SearchArticle: Persistable, Codable, Sendable {
    typealias ID = String

    var id: String = UUID().uuidString
    var content: String = ""

    static var persistableType: String { "SearchArticle" }
    static var allFields: [String] { ["id", "content"] }

    static func fieldNumber(for fieldName: String) -> Int? {
        switch fieldName {
        case "id": return 1
        case "content": return 2
        default: return nil
        }
    }

    static func enumMetadata(for fieldName: String) -> EnumMetadata? { nil }

    subscript(dynamicMember member: String) -> (any Sendable)? {
        switch member {
        case "id": return id
        case "content": return content
        default: return nil
        }
    }

    static func fieldName<Value>(for keyPath: KeyPath<SearchArticle, Value>) -> String {
        if keyPath == \SearchArticle.id { return "id" }
        if keyPath == \SearchArticle.content { return "content" }
        return "\(keyPath)"
    }

    static func fieldName(for keyPath: PartialKeyPath<SearchArticle>) -> String {
        if keyPath == \SearchArticle.id { return "id" }
        if keyPath == \SearchArticle.content { return "content" }
        return "\(keyPath)"
    }

    static func fieldName(for keyPath: AnyKeyPath) -> String {
        if let partial = keyPath as? PartialKeyPath<SearchArticle> {
            return fieldName(for: partial)
        }
        return "\(keyPath)"
    }
}

@Suite("Canonical Read Features")
struct CanonicalReadFeatureTests {
    @Test("Vector query builder sends accessPath and decodes distance annotation")
    func vectorQueryBuilderUsesCanonicalRoute() async throws {
        let captured = Capture<QueryRequest>()

        let transport = InProcessTransport { envelope in
            captured.set(try JSONDecoder().decode(QueryRequest.self, from: envelope.payload))
            let response = QueryResponse(
                rows: [
                    QueryRow(
                        fields: [
                            "id": .string("doc-1"),
                            "title": .string("Nearest"),
                            "embedding": .array([.double(0.1), .double(0.2), .double(0.3)])
                        ],
                        annotations: ["distance": .double(0.12)]
                    )
                ],
                continuation: QueryContinuation("next-vector-page")
            )
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        let result = try await context.findSimilar(VectorDocument.self)
            .vector(\.embedding, dimensions: 3)
            .query([0.1, 0.2, 0.3], k: 5)
            .metric(.cosine)
            .consistency(.snapshot)
            .execute()

        guard case .select(let selectQuery) = captured.get()!.statement,
              case .index(let accessPath) = selectQuery.accessPath else {
            Issue.record("Expected index access path")
            return
        }

        #expect(accessPath.kindIdentifier == "vector")
        #expect(accessPath.parameters["fieldName"] == .string("embedding"))
        #expect(accessPath.parameters["dimensions"] == .int(3))
        #expect(captured.get()?.options.consistency == .snapshot)
        #expect(result.items.count == 1)
        #expect(result.items[0].item.title == "Nearest")
        #expect(result.items[0].distance == 0.12)
        #expect(result.continuation == "next-vector-page")
    }

    @Test("Full-text scored query sends accessPath and decodes score annotation")
    func fullTextScoredQueryUsesCanonicalRoute() async throws {
        let captured = Capture<QueryRequest>()

        let transport = InProcessTransport { envelope in
            captured.set(try JSONDecoder().decode(QueryRequest.self, from: envelope.payload))
            let response = QueryResponse(
                rows: [
                    QueryRow(
                        fields: [
                            "id": .string("article-1"),
                            "content": .string("swift concurrency and vector search")
                        ],
                        annotations: ["score": .double(9.5)]
                    )
                ]
            )
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        let result = try await context.search(SearchArticle.self)
            .fullText(\.content)
            .terms(["swift", "vector"], mode: .all)
            .bm25(k1: 1.5, b: 0.8)
            .consistency(.snapshot)
            .executeWithScores()

        guard case .select(let selectQuery) = captured.get()!.statement,
              case .index(let accessPath) = selectQuery.accessPath else {
            Issue.record("Expected index access path")
            return
        }

        #expect(accessPath.kindIdentifier == "fulltext")
        #expect(accessPath.parameters["matchMode"] == .string("all"))
        #expect(accessPath.parameters["returnScores"] == .bool(true))
        #expect(captured.get()?.options.consistency == .snapshot)
        #expect(result.items.count == 1)
        #expect(result.items[0].item.content.contains("vector"))
        #expect(result.items[0].score == 9.5)
    }

    @Test("Full-text facet query decodes metadata")
    func fullTextFacetQueryDecodesMetadata() async throws {
        let transport = InProcessTransport { envelope in
            let response = QueryResponse(
                rows: [
                    QueryRow(
                        fields: [
                            "id": .string("article-1"),
                            "content": .string("swift concurrency")
                        ]
                    )
                ],
                metadata: [
                    "fulltext.totalCount": .int64(42),
                    "fulltext.facets.category": .array([
                        .array([.string("search"), .int64(10)]),
                        .array([.string("database"), .int64(8)])
                    ])
                ]
            )
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        let result = try await context.search(SearchArticle.self)
            .fullText(\.content)
            .terms(["swift"])
            .facets(["category"], limit: 10)
            .executeWithFacets()

        #expect(result.items.count == 1)
        #expect(result.totalCount == 42)
        #expect(result.facets["category"]?.count == 2)
        #expect(result.facets["category"]?.first?.value == "search")
        #expect(result.facets["category"]?.first?.count == 10)
    }
}
