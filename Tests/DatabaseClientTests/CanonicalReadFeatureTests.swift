import Testing
import Foundation
import Core
import QueryIR
import DatabaseClientProtocol
import Vector
import Permuted
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

    @Test("Polymorphic vector query builder uses logical source and decodes mixed results")
    func polymorphicVectorQueryUsesLogicalSource() async throws {
        let schema = Schema([TestArticle.self, TestReport.self])
        let group = try #require(schema.polymorphicGroup(identifier: "TestDocument"))
        let captured = Capture<QueryRequest>()

        let transport = InProcessTransport { envelope in
            captured.set(try JSONDecoder().decode(QueryRequest.self, from: envelope.payload))
            let response = QueryResponse(
                rows: [
                    QueryRow(
                        fields: [
                            "id": .string("article-1"),
                            "title": .string("Article"),
                            "body": .string("Body")
                        ],
                        annotations: [
                            "_typeName": .string("TestArticle"),
                            "_typeCode": .int64(1),
                            "distance": .double(0.25)
                        ]
                    ),
                    QueryRow(
                        fields: [
                            "id": .string("report-1"),
                            "title": .string("Report"),
                            "summary": .string("Summary")
                        ],
                        annotations: [
                            "_typeName": .string("TestReport"),
                            "_typeCode": .int64(2),
                            "distance": .double(0.5)
                        ]
                    )
                ],
                continuation: QueryContinuation("poly-vector-next")
            )
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport, localSchema: schema)
        let result = try await context.findPolymorphic(group)
            .vector(fieldName: "titleEmbedding", dimensions: 3)
            .indexName("document_title_embedding")
            .query([0.1, 0.2, 0.3], k: 4)
            .consistency(.snapshot)
            .execute()

        guard case .select(let selectQuery) = captured.get()!.statement,
              case .logical(let logicalSource) = selectQuery.source,
              case .index(let accessPath) = selectQuery.accessPath else {
            Issue.record("Expected logical polymorphic index query")
            return
        }

        #expect(logicalSource.kindIdentifier == BuiltinLogicalSourceKind.polymorphic)
        #expect(logicalSource.identifier == group.identifier)
        #expect(accessPath.kindIdentifier == "vector")
        #expect(accessPath.indexName == "document_title_embedding")
        #expect(accessPath.parameters["fieldName"] == .string("titleEmbedding"))
        #expect(captured.get()?.options.consistency == .snapshot)
        #expect(result.items.count == 2)
        #expect(result.items[0].item is TestArticle)
        #expect(result.items[1].item is TestReport)
        #expect(result.items[0].distance == 0.25)
        #expect(result.continuation == "poly-vector-next")
    }

    @Test("Polymorphic full-text query builder uses logical source and decodes scores")
    func polymorphicFullTextQueryUsesLogicalSource() async throws {
        let schema = Schema([TestArticle.self, TestReport.self])
        let group = try #require(schema.polymorphicGroup(identifier: "TestDocument"))
        let captured = Capture<QueryRequest>()

        let transport = InProcessTransport { envelope in
            captured.set(try JSONDecoder().decode(QueryRequest.self, from: envelope.payload))
            let response = QueryResponse(
                rows: [
                    QueryRow(
                        fields: [
                            "id": .string("article-1"),
                            "title": .string("Searchable"),
                            "body": .string("swift vector")
                        ],
                        annotations: [
                            "_typeName": .string("TestArticle"),
                            "_typeCode": .int64(1),
                            "score": .double(8.75)
                        ]
                    )
                ]
            )
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport, localSchema: schema)
        let result = try await context.findPolymorphic(group)
            .fullText(fieldName: "title")
            .indexName("document_title")
            .terms(["swift", "vector"], mode: .all)
            .bm25(k1: 1.4, b: 0.7)
            .executeWithScores()

        guard case .select(let selectQuery) = captured.get()!.statement,
              case .logical(let logicalSource) = selectQuery.source,
              case .index(let accessPath) = selectQuery.accessPath else {
            Issue.record("Expected logical polymorphic full-text query")
            return
        }

        #expect(logicalSource.identifier == group.identifier)
        #expect(accessPath.kindIdentifier == "fulltext")
        #expect(accessPath.indexName == "document_title")
        #expect(accessPath.parameters["matchMode"] == .string("all"))
        #expect(accessPath.parameters["returnScores"] == .bool(true))
        #expect(result.items.count == 1)
        #expect(result.items[0].item is TestArticle)
        #expect(result.items[0].score == 8.75)
    }

    @Test("Polymorphic rank query builder uses logical source and decodes rank annotations")
    func polymorphicRankQueryUsesLogicalSource() async throws {
        let schema = Schema([TestArticle.self, TestReport.self])
        let group = try #require(schema.polymorphicGroup(identifier: "TestDocument"))
        let captured = Capture<QueryRequest>()

        let transport = InProcessTransport { envelope in
            captured.set(try JSONDecoder().decode(QueryRequest.self, from: envelope.payload))
            let response = QueryResponse(
                rows: [
                    QueryRow(
                        fields: [
                            "id": .string("rank-1"),
                            "title": .string("top ranked"),
                            "body": .string("body")
                        ],
                        annotations: [
                            "_typeName": .string(TestArticle.persistableType),
                            "_typeCode": .int64(11),
                            "rank": .int64(0)
                        ]
                    )
                ],
                continuation: QueryContinuation("next-rank-page")
            )
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport, localSchema: schema)
        let result = try await context.findPolymorphic(group)
            .rank(fieldName: "score")
            .top(5)
            .consistency(.snapshot)
            .execute()

        guard case .select(let selectQuery) = captured.get()!.statement,
              case .logical(let source) = selectQuery.source,
              case .index(let accessPath) = selectQuery.accessPath else {
            Issue.record("Expected logical source with index access path")
            return
        }

        #expect(source.identifier == group.identifier)
        #expect(accessPath.kindIdentifier == "rank")
        #expect(accessPath.parameters["mode"] == .string("top"))
        #expect(accessPath.parameters["count"] == .int(5))
        #expect(result.items.count == 1)
        #expect(result.items[0].rank == 0)
        #expect((result.items[0].item as? TestArticle)?.title == "top ranked")
        #expect(result.continuation == "next-rank-page")
    }

    @Test("Polymorphic bitmap query builder uses logical source and count projection")
    func polymorphicBitmapQueryUsesLogicalSource() async throws {
        let schema = Schema([TestArticle.self, TestReport.self])
        let group = try #require(schema.polymorphicGroup(identifier: "TestDocument"))
        let captured = Capture<QueryRequest>()

        let transport = InProcessTransport { envelope in
            let request = try JSONDecoder().decode(QueryRequest.self, from: envelope.payload)
            captured.set(request)

            let response: QueryResponse
            if case .select(let query) = request.statement,
               case .items(let items) = query.projection,
               case .aggregate = items.first?.expression {
                response = QueryResponse(rows: [QueryRow(fields: ["count": .int64(3)])])
            } else {
                response = QueryResponse(
                    rows: [
                        QueryRow(
                            fields: [
                                "id": .string("bitmap-1"),
                                "title": .string("matched"),
                                "body": .string("body")
                            ],
                            annotations: [
                                "_typeName": .string(TestArticle.persistableType),
                                "_typeCode": .int64(7)
                            ]
                        )
                    ]
                )
            }

            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport, localSchema: schema)
        let count = try await context.findPolymorphic(group)
            .bitmap(fieldName: "category")
            .equals("tech")
            .count()

        guard case .select(let selectQuery) = captured.get()!.statement,
              case .index(let accessPath) = selectQuery.accessPath else {
            Issue.record("Expected index access path")
            return
        }

        #expect(accessPath.kindIdentifier == "bitmap")
        #expect(accessPath.parameters["operation"] == .string("equals"))
        #expect(accessPath.parameters["values"] == .array([.string("tech")]))
        #expect(count == 3)
    }

    @Test("Polymorphic permuted query builder uses logical source and permutation metadata")
    func polymorphicPermutedQueryUsesLogicalSource() async throws {
        let schema = Schema([TestArticle.self, TestReport.self])
        let group = try #require(schema.polymorphicGroup(identifier: "TestDocument"))
        let captured = Capture<QueryRequest>()

        let transport = InProcessTransport { envelope in
            captured.set(try JSONDecoder().decode(QueryRequest.self, from: envelope.payload))
            let response = QueryResponse(
                rows: [
                    QueryRow(
                        fields: [
                            "id": .string("permuted-1"),
                            "title": .string("Tokyo"),
                            "body": .string("Body")
                        ],
                        annotations: [
                            "_typeName": .string(TestArticle.persistableType),
                            "_typeCode": .int64(7)
                        ]
                    )
                ],
                continuation: QueryContinuation("next-permuted-page")
            )
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport, localSchema: schema)
        let result = try await context.findPolymorphic(group)
            .permuted(
                indexName: "document_location",
                permutation: try Permutation(indices: [1, 0])
            )
            .prefix(["tokyo"])
            .limit(5)
            .execute()

        guard case .select(let selectQuery) = captured.get()!.statement,
              case .index(let accessPath) = selectQuery.accessPath else {
            Issue.record("Expected index access path")
            return
        }

        #expect(accessPath.kindIdentifier == "permuted")
        #expect(accessPath.indexName == "document_location")
        #expect(accessPath.parameters["queryType"] == .string("prefix"))
        #expect(accessPath.parameters["values"] == .array([.string("tokyo")]))
        #expect(accessPath.parameters["permutation"] == .array([.int(1), .int(0)]))
        #expect(result.items.count == 1)
        #expect(result.items[0] is TestArticle)
        #expect(result.continuation == "next-permuted-page")
    }

    @Test("Polymorphic version query builder encodes composite primary key and decodes version annotation")
    func polymorphicVersionQueryUsesReference() async throws {
        let schema = Schema([TestArticle.self, TestReport.self])
        let group = try #require(schema.polymorphicGroup(identifier: "TestDocument"))
        let captured = Capture<QueryRequest>()
        let versionBytes = Data([0, 0, 0, 0, 0, 0, 0, 2, 0, 1])

        let transport = InProcessTransport { envelope in
            captured.set(try JSONDecoder().decode(QueryRequest.self, from: envelope.payload))
            let response = QueryResponse(
                rows: [
                    QueryRow(
                        fields: [
                            "id": .string("versioned-1"),
                            "title": .string("Versioned"),
                            "body": .string("Body")
                        ],
                        annotations: [
                            "_typeName": .string(TestArticle.persistableType),
                            "_typeCode": .int64(TestArticle.typeCode(for: TestArticle.persistableType)),
                            "version": .data(versionBytes)
                        ]
                    )
                ],
                continuation: QueryContinuation("next-version-page")
            )
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport, localSchema: schema)
        let article = TestArticle(id: "versioned-1", title: "Versioned", body: "Body")
        let result = try await context.findPolymorphic(group)
            .versionHistory(for: article)
            .limit(10)
            .execute()

        guard case .select(let selectQuery) = captured.get()!.statement,
              case .index(let accessPath) = selectQuery.accessPath,
              let primaryKey = accessPath.parameters["primaryKey"]?.arrayValue else {
            Issue.record("Expected version access path with primary key")
            return
        }

        #expect(accessPath.kindIdentifier == "version")
        #expect(accessPath.indexName == "TestDocument_version_id")
        #expect(primaryKey.count == 2)
        #expect(primaryKey[0] == .int(TestArticle.typeCode(for: TestArticle.persistableType)))
        #expect(primaryKey[1] == .string(article.id))
        #expect(result.items.count == 1)
        #expect(result.items[0].version == RecordVersion(bytes: versionBytes))
        #expect((result.items[0].item as? TestArticle)?.id == article.id)
        #expect(result.continuation == "next-version-page")
    }
}
