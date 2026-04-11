import Foundation
import Core
import QueryIR
import DatabaseClientProtocol
import FullText

private enum ClientFullTextReadParameter {
    static let fieldName = "fieldName"
    static let terms = "terms"
    static let matchMode = "matchMode"
    static let limit = "limit"
    static let returnScores = "returnScores"
    static let includeFacets = "includeFacets"
    static let bm25K1 = "bm25.k1"
    static let bm25B = "bm25.b"
    static let facetFields = "facetFields"
    static let facetLimit = "facetLimit"
    static let totalCount = "fulltext.totalCount"
    static let facetMetadataPrefix = "fulltext.facets."
}

public enum FullTextMatchMode: String, Sendable, Codable {
    case any
    case all
    case phrase
}

public struct FullTextEntryPoint<T: Persistable>: Sendable {
    private let context: DatabaseContext

    init(context: DatabaseContext) {
        self.context = context
    }

    public func fullText(_ keyPath: KeyPath<T, String>) -> FullTextQueryBuilder<T> {
        FullTextQueryBuilder(
            context: context,
            fieldName: T.fieldName(for: keyPath)
        )
    }

    public func fullText(_ keyPath: KeyPath<T, String?>) -> FullTextQueryBuilder<T> {
        FullTextQueryBuilder(
            context: context,
            fieldName: T.fieldName(for: keyPath)
        )
    }
}

public struct FullTextQueryBuilder<T: Persistable>: Sendable {
    private let context: DatabaseContext
    private let fieldName: String
    private var searchTerms: [String] = []
    private var matchMode: FullTextMatchMode = .all
    private var fetchLimit: Int?
    private var bm25K1: Double = 1.2
    private var bm25B: Double = 0.75
    private var facetFields: [String] = []
    private var facetLimit: Int = 10
    private var partitionValues: [String: String]?
    private var options: ReadExecutionOptions = .default

    init(context: DatabaseContext, fieldName: String) {
        self.context = context
        self.fieldName = fieldName
    }

    public func terms(_ terms: [String], mode: FullTextMatchMode = .all) -> Self {
        var copy = self
        copy.searchTerms = terms
        copy.matchMode = mode
        return copy
    }

    public func limit(_ count: Int) -> Self {
        var copy = self
        copy.fetchLimit = count
        return copy
    }

    public func bm25(k1: Double = 1.2, b: Double = 0.75) -> Self {
        var copy = self
        copy.bm25K1 = k1
        copy.bm25B = b
        return copy
    }

    public func facets(_ fields: [String], limit: Int = 10) -> Self {
        var copy = self
        copy.facetFields = fields
        copy.facetLimit = limit
        return copy
    }

    public func partition(_ values: [String: String]) -> Self {
        var copy = self
        copy.partitionValues = values
        return copy
    }

    public func continuation(_ token: String) -> Self {
        var copy = self
        copy.options = ReadExecutionOptions(
            consistency: copy.options.consistency,
            pageSize: copy.options.pageSize,
            continuation: QueryContinuation(token)
        )
        return copy
    }

    public func pageSize(_ count: Int) -> Self {
        var copy = self
        copy.options = ReadExecutionOptions(
            consistency: copy.options.consistency,
            pageSize: count,
            continuation: copy.options.continuation
        )
        return copy
    }

    public func consistency(_ consistency: ReadConsistency) -> Self {
        var copy = self
        copy.options = ReadExecutionOptions(
            consistency: consistency,
            pageSize: copy.options.pageSize,
            continuation: copy.options.continuation
        )
        return copy
    }

    public func execute() async throws -> FullTextQueryResult<T> {
        let response = try await context.query(
            makeSelectQuery(),
            options: options,
            partitionValues: partitionValues
        )

        let items: [T] = try response.rows.map { try FieldValueDecoder.decode($0.fields) }
        return FullTextQueryResult(items: items, continuation: response.continuation?.token)
    }

    public func executeWithScores() async throws -> FullTextScoredQueryResult<T> {
        let response = try await context.query(
            makeSelectQuery(returnScores: true),
            options: options,
            partitionValues: partitionValues
        )

        let items: [(item: T, score: Double)] = try response.rows.map { row in
            let item: T = try FieldValueDecoder.decode(row.fields)
            let score = row.annotations["score"]?.doubleValue ?? 0
            return (item: item, score: score)
        }

        return FullTextScoredQueryResult(
            items: items,
            continuation: response.continuation?.token
        )
    }

    public func executeWithFacets() async throws -> FullTextFacetedQueryResult<T> {
        let response = try await context.query(
            makeSelectQuery(includeFacets: true),
            options: options,
            partitionValues: partitionValues
        )

        let items: [T] = try response.rows.map { try FieldValueDecoder.decode($0.fields) }
        return FullTextFacetedQueryResult(
            items: items,
            facets: decodeFacetMetadata(response.metadata),
            totalCount: Int(response.metadata[ClientFullTextReadParameter.totalCount]?.int64Value ?? Int64(items.count)),
            continuation: response.continuation?.token
        )
    }

    private func makeSelectQuery(
        returnScores: Bool = false,
        includeFacets: Bool = false
    ) -> SelectQuery {
        var parameters: [String: QueryParameterValue] = [
            ClientFullTextReadParameter.fieldName: .string(fieldName),
            ClientFullTextReadParameter.terms: .array(searchTerms.map(QueryParameterValue.string)),
            ClientFullTextReadParameter.matchMode: .string(matchMode.rawValue),
            ClientFullTextReadParameter.returnScores: .bool(returnScores),
            ClientFullTextReadParameter.includeFacets: .bool(includeFacets)
        ]

        if let fetchLimit {
            parameters[ClientFullTextReadParameter.limit] = .int(Int64(fetchLimit))
        }
        if returnScores {
            parameters[ClientFullTextReadParameter.bm25K1] = .double(bm25K1)
            parameters[ClientFullTextReadParameter.bm25B] = .double(bm25B)
        }
        if includeFacets, !facetFields.isEmpty {
            parameters[ClientFullTextReadParameter.facetFields] = .array(facetFields.map(QueryParameterValue.string))
            parameters[ClientFullTextReadParameter.facetLimit] = .int(Int64(facetLimit))
        }

        return SelectQuery(
            projection: .all,
            source: .table(TableRef(table: T.persistableType)),
            accessPath: .index(
                IndexScanSource(
                    indexName: buildIndexName(),
                    kindIdentifier: FullTextIndexKind<T>.identifier,
                    parameters: parameters
                )
            ),
            limit: fetchLimit
        )
    }

    private func buildIndexName() -> String {
        if let descriptor = T.indexDescriptors.first(where: { descriptor in
            guard descriptor.kindIdentifier == FullTextIndexKind<T>.identifier,
                  let kind = descriptor.kind as? FullTextIndexKind<T> else {
                return false
            }
            return kind.fieldNames.contains(fieldName)
        }) {
            return descriptor.name
        }
        return "\(T.persistableType)_fulltext_\(fieldName)"
    }

    private func decodeFacetMetadata(_ metadata: [String: FieldValue]) -> [String: [(value: String, count: Int64)]] {
        var facets: [String: [(value: String, count: Int64)]] = [:]

        for (key, value) in metadata {
            guard key.hasPrefix(ClientFullTextReadParameter.facetMetadataPrefix),
                  let buckets = value.arrayValue else {
                continue
            }

            let fieldName = String(key.dropFirst(ClientFullTextReadParameter.facetMetadataPrefix.count))
            facets[fieldName] = buckets.compactMap { bucket in
                guard let elements = bucket.arrayValue,
                      elements.count == 2,
                      let facetValue = elements[0].stringValue,
                      let count = elements[1].int64Value else {
                    return nil
                }
                return (value: facetValue, count: count)
            }
        }

        return facets
    }
}
