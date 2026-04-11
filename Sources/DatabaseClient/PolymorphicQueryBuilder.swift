import Foundation
import Core
import QueryIR
import DatabaseClientProtocol
import Vector
import FullText
import Permuted

enum ClientRankReadParameter {
    static let fieldName = "fieldName"
    static let mode = "mode"
    static let count = "count"
    static let from = "from"
    static let to = "to"
    static let percentile = "percentile"
}

enum ClientBitmapReadParameter {
    static let fieldName = "fieldName"
    static let operation = "operation"
    static let values = "values"
    static let valueSets = "valueSets"
    static let limit = "limit"

    static let equalsOperation = "equals"
    static let inOperation = "in"
    static let andOperation = "and"
}

enum ClientPermutedReadParameter {
    static let queryType = "queryType"
    static let values = "values"
    static let permutation = "permutation"
    static let limit = "limit"

    static let prefixQuery = "prefix"
    static let exactQuery = "exact"
    static let allQuery = "all"
}

enum ClientVersionReadParameter {
    static let primaryKey = "primaryKey"
    static let limit = "limit"
    static let indexName = "indexName"
}

public enum TupleQueryValue: Sendable, Equatable, Hashable, Codable,
    ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral
{
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case binary(Data)
    case uuid(UUID)
    case date(Date)
    case float(Float)
    case uint64(UInt64)

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(integerLiteral value: Int64) {
        self = .int(value)
    }

    public init(floatLiteral value: Double) {
        self = .double(value)
    }

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    public init?(any value: Any) {
        switch value {
        case let value as String:
            self = .string(value)
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(Int64(value))
        case let value as Int32:
            self = .int(Int64(value))
        case let value as Int64:
            self = .int(value)
        case let value as UInt64:
            self = .uint64(value)
        case let value as Float:
            self = .float(value)
        case let value as Double:
            self = .double(value)
        case let value as UUID:
            self = .uuid(value)
        case let value as Date:
            self = .date(value)
        case let value as Data:
            self = .binary(value)
        default:
            return nil
        }
    }

    fileprivate func toQueryParameterValue() -> QueryParameterValue {
        switch self {
        case .string(let value):
            return .string(value)
        case .int(let value):
            return .int(value)
        case .double(let value):
            return .double(value)
        case .bool(let value):
            return .bool(value)
        case .binary(let value):
            return .binary(value)
        case .uuid(let value):
            return .object([
                "type": .string("uuid"),
                "value": .string(value.uuidString)
            ])
        case .date(let value):
            return .object([
                "type": .string("date"),
                "value": .double(value.timeIntervalSince1970)
            ])
        case .float(let value):
            return .object([
                "type": .string("float"),
                "value": .double(Double(value))
            ])
        case .uint64(let value):
            if let exact = Int64(exactly: value) {
                return .int(exact)
            }
            return .object([
                "type": .string("uint64"),
                "value": .string(String(value))
            ])
        }
    }
}

private enum ClientPolymorphicQueryError: Error, Sendable {
    case invalidRequest(String)
}

/// Protocol-first fluent query builder backed by the canonical logical-source route.
public struct PolymorphicQueryBuilder: Sendable {
    private let context: DatabaseContext
    private let groupIdentifier: String
    private var selectQuery: SelectQuery
    private var options: ReadExecutionOptions
    private var partitionValues: [String: String]?

    init(context: DatabaseContext, groupIdentifier: String) {
        self.context = context
        self.groupIdentifier = groupIdentifier
        self.selectQuery = SelectQuery(
            projection: .all,
            source: .logical(
                LogicalSourceRef(
                    kindIdentifier: BuiltinLogicalSourceKind.polymorphic,
                    identifier: groupIdentifier
                )
            )
        )
        self.options = .default
        self.partitionValues = nil
    }

    public func `where`(_ predicate: QueryIR.Expression) -> Self {
        var copy = self
        let combinedFilter: QueryIR.Expression
        if let existing = copy.selectQuery.filter {
            combinedFilter = .and(existing, predicate)
        } else {
            combinedFilter = predicate
        }
        copy.selectQuery = copy.selectQuery.replacing(filter: combinedFilter)
        return copy
    }

    public func sort(by fieldName: String, ascending: Bool = true) -> Self {
        var copy = self
        var sorts = copy.selectQuery.orderBy ?? []
        sorts.append(
            SortKey(
                .column(ColumnRef(column: fieldName)),
                direction: ascending ? .ascending : .descending
            )
        )
        copy.selectQuery = copy.selectQuery.replacing(orderBy: sorts)
        return copy
    }

    public func limit(_ count: Int) -> Self {
        var copy = self
        copy.selectQuery = copy.selectQuery.replacing(limit: count)
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

    public func vector(fieldName: String, dimensions: Int) -> PolymorphicVectorQueryBuilder {
        PolymorphicVectorQueryBuilder(
            context: context,
            groupIdentifier: groupIdentifier,
            fieldName: fieldName,
            dimensions: dimensions
        )
    }

    public func fullText(fieldName: String) -> PolymorphicFullTextQueryBuilder {
        PolymorphicFullTextQueryBuilder(
            context: context,
            groupIdentifier: groupIdentifier,
            fieldName: fieldName
        )
    }

    public func rank(fieldName: String) -> PolymorphicRankQueryBuilder {
        PolymorphicRankQueryBuilder(
            context: context,
            groupIdentifier: groupIdentifier,
            fieldName: fieldName
        )
    }

    public func bitmap(fieldName: String) -> PolymorphicBitmapQueryBuilder {
        PolymorphicBitmapQueryBuilder(
            context: context,
            groupIdentifier: groupIdentifier,
            fieldName: fieldName
        )
    }

    public func permuted(
        indexName: String,
        permutation: Permutation? = nil
    ) -> PolymorphicPermutedQueryBuilder {
        PolymorphicPermutedQueryBuilder(
            context: context,
            groupIdentifier: groupIdentifier,
            indexName: indexName,
            permutation: permutation
        )
    }

    public func reference(
        typeName: String,
        idComponents: [TupleQueryValue]
    ) -> PolymorphicRecordReference {
        PolymorphicRecordReference(
            groupIdentifier: groupIdentifier,
            typeName: typeName,
            idComponents: idComponents
        )
    }

    public func reference<T: Persistable & Polymorphable>(
        for item: T
    ) throws -> PolymorphicRecordReference where T.ID: Sendable {
        guard let id = TupleQueryValue(any: item.id) else {
            throw ClientPolymorphicQueryError.invalidRequest(
                "Persistable id for '\(T.persistableType)' cannot be encoded as a tuple query value."
            )
        }
        return PolymorphicRecordReference(
            groupIdentifier: groupIdentifier,
            typeName: T.persistableType,
            idComponents: [id]
        )
    }

    public func versionHistory(
        for reference: PolymorphicRecordReference
    ) -> PolymorphicVersionQueryBuilder {
        PolymorphicVersionQueryBuilder(
            context: context,
            groupIdentifier: groupIdentifier,
            reference: reference
        )
    }

    public func versionHistory<T: Persistable & Polymorphable>(
        for item: T
    ) throws -> PolymorphicVersionQueryBuilder where T.ID: Sendable {
        PolymorphicVersionQueryBuilder(
            context: context,
            groupIdentifier: groupIdentifier,
            reference: try reference(for: item)
        )
    }

    public func execute() async throws -> [any Persistable] {
        try await executePage().items
    }

    public func executeAnnotated() async throws -> [(item: any Persistable, annotations: [String: FieldValue])] {
        try await executeAnnotatedPage().records
    }

    public func executePage() async throws -> (items: [any Persistable], continuation: String?) {
        let page = try await executeAnnotatedPage()
        return (items: page.records.map { $0.item }, continuation: page.continuation)
    }

    public func executeAnnotatedPage() async throws -> (
        records: [(item: any Persistable, annotations: [String: FieldValue])],
        continuation: String?
    ) {
        let response = try await context.query(
            selectQuery,
            options: options,
            partitionValues: partitionValues
        )
        let records = try response.rows.map { row in
            (
                item: try context.decodePolymorphicRow(row, groupIdentifier: groupIdentifier),
                annotations: row.annotations
            )
        }
        return (records: records, continuation: response.continuation?.token)
    }

    public func count() async throws -> Int {
        var countQuery = selectQuery.replacing(
            projection: .items([
                ProjectionItem(.aggregate(.count(nil, distinct: false)), alias: "count")
            ])
        )
        countQuery = countQuery.replacing(groupBy: nil)
        countQuery = countQuery.replacing(having: nil)
        countQuery = countQuery.replacing(orderBy: nil)
        countQuery = countQuery.replacing(limit: 1)
        countQuery = countQuery.replacing(offset: nil)
        countQuery = countQuery.replacing(distinct: false)
        countQuery = countQuery.replacing(reduced: false)

        let response = try await context.query(
            countQuery,
            options: .default,
            partitionValues: partitionValues
        )
        guard let row = response.rows.first,
              let count = row.fields["count"]?.int64Value else {
            return 0
        }
        return Int(count)
    }

    public func first() async throws -> (any Persistable)? {
        try await limit(1).execute().first
    }

    public func stream(pageSize: Int = 100) -> AsyncThrowingStream<any Persistable, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var builder = self.pageSize(pageSize)
                    while true {
                        let page = try await builder.executePage()
                        for item in page.items {
                            continuation.yield(item)
                        }
                        guard let token = page.continuation else {
                            continuation.finish()
                            return
                        }
                        builder = builder.continuation(token)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

public struct PolymorphicVectorQueryBuilder: Sendable {
    private let context: DatabaseContext
    private let groupIdentifier: String
    private let fieldName: String
    private let dimensions: Int
    private var indexNameOverride: String?
    private var queryVector: [Float]?
    private var k: Int = 10
    private var metric: VectorMetric = .cosine
    private var partitionValues: [String: String]?
    private var options: ReadExecutionOptions = .default

    init(
        context: DatabaseContext,
        groupIdentifier: String,
        fieldName: String,
        dimensions: Int
    ) {
        self.context = context
        self.groupIdentifier = groupIdentifier
        self.fieldName = fieldName
        self.dimensions = dimensions
    }

    public func query(_ vector: [Float], k: Int) -> Self {
        var copy = self
        copy.queryVector = vector
        copy.k = k
        return copy
    }

    public func metric(_ metric: VectorMetric) -> Self {
        var copy = self
        copy.metric = metric
        return copy
    }

    public func indexName(_ name: String) -> Self {
        var copy = self
        copy.indexNameOverride = name
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

    public func execute() async throws -> PolymorphicVectorQueryResult {
        let response = try await context.query(
            try makeSelectQuery(),
            options: options,
            partitionValues: partitionValues
        )

        let items: [(item: any Persistable, distance: Double)] = try response.rows.map { row in
            let item = try context.decodePolymorphicRow(row, groupIdentifier: groupIdentifier)
            let distance = row.annotations["distance"]?.doubleValue ?? 0
            return (item: item, distance: distance)
        }

        return PolymorphicVectorQueryResult(
            items: items,
            continuation: response.continuation?.token
        )
    }

    private func makeSelectQuery() throws -> SelectQuery {
        guard let queryVector else {
            throw ServiceError(code: "INVALID_QUERY", message: "Missing vector query")
        }

        let parameters: [String: QueryParameterValue] = [
            ClientVectorReadParameter.fieldName: .string(fieldName),
            ClientVectorReadParameter.dimensions: .int(Int64(dimensions)),
            ClientVectorReadParameter.queryVector: .array(queryVector.map { .double(Double($0)) }),
            ClientVectorReadParameter.k: .int(Int64(k)),
            ClientVectorReadParameter.metric: .string(metric.rawValue)
        ]

        return SelectQuery(
            projection: .all,
            source: .logical(
                LogicalSourceRef(
                    kindIdentifier: BuiltinLogicalSourceKind.polymorphic,
                    identifier: groupIdentifier
                )
            ),
            accessPath: .index(
                IndexScanSource(
                    indexName: buildIndexName(),
                    kindIdentifier: "vector",
                    parameters: parameters
                )
            ),
            limit: k
        )
    }

    private func buildIndexName() -> String {
        if let indexNameOverride {
            return indexNameOverride
        }
        if let group = context.schema?.polymorphicGroup(identifier: groupIdentifier),
           let descriptor = group.indexes.first(where: {
               $0.kindIdentifier == "vector" && $0.fieldNames.contains(fieldName)
           }) {
            return descriptor.name
        }
        return "\(groupIdentifier)_vector_\(fieldName)"
    }
}

public struct PolymorphicFullTextQueryBuilder: Sendable {
    private let context: DatabaseContext
    private let groupIdentifier: String
    private let fieldName: String
    private var indexNameOverride: String?
    private var searchTerms: [String] = []
    private var matchMode: FullTextMatchMode = .all
    private var fetchLimit: Int?
    private var bm25K1: Double = 1.2
    private var bm25B: Double = 0.75
    private var facetFields: [String] = []
    private var facetLimit: Int = 10
    private var partitionValues: [String: String]?
    private var options: ReadExecutionOptions = .default

    init(context: DatabaseContext, groupIdentifier: String, fieldName: String) {
        self.context = context
        self.groupIdentifier = groupIdentifier
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

    public func indexName(_ name: String) -> Self {
        var copy = self
        copy.indexNameOverride = name
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

    public func execute() async throws -> PolymorphicFullTextQueryResult {
        let response = try await context.query(
            makeSelectQuery(),
            options: options,
            partitionValues: partitionValues
        )

        let items = try response.rows.map {
            try context.decodePolymorphicRow($0, groupIdentifier: groupIdentifier)
        }
        return PolymorphicFullTextQueryResult(items: items, continuation: response.continuation?.token)
    }

    public func executeWithScores() async throws -> PolymorphicFullTextScoredQueryResult {
        let response = try await context.query(
            makeSelectQuery(returnScores: true),
            options: options,
            partitionValues: partitionValues
        )

        let items: [(item: any Persistable, score: Double)] = try response.rows.map { row in
            let item = try context.decodePolymorphicRow(row, groupIdentifier: groupIdentifier)
            let score = row.annotations["score"]?.doubleValue ?? 0
            return (item: item, score: score)
        }

        return PolymorphicFullTextScoredQueryResult(
            items: items,
            continuation: response.continuation?.token
        )
    }

    public func executeWithFacets() async throws -> PolymorphicFullTextFacetedQueryResult {
        let response = try await context.query(
            makeSelectQuery(includeFacets: true),
            options: options,
            partitionValues: partitionValues
        )

        let items = try response.rows.map {
            try context.decodePolymorphicRow($0, groupIdentifier: groupIdentifier)
        }
        return PolymorphicFullTextFacetedQueryResult(
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
            source: .logical(
                LogicalSourceRef(
                    kindIdentifier: BuiltinLogicalSourceKind.polymorphic,
                    identifier: groupIdentifier
                )
            ),
            accessPath: .index(
                IndexScanSource(
                    indexName: buildIndexName(),
                    kindIdentifier: "fulltext",
                    parameters: parameters
                )
            ),
            limit: fetchLimit
        )
    }

    private func buildIndexName() -> String {
        if let indexNameOverride {
            return indexNameOverride
        }
        if let group = context.schema?.polymorphicGroup(identifier: groupIdentifier),
           let descriptor = group.indexes.first(where: {
               $0.kindIdentifier == "fulltext" && $0.fieldNames.contains(fieldName)
           }) {
            return descriptor.name
        }
        return "\(groupIdentifier)_fulltext_\(fieldName)"
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

public struct PolymorphicRankQueryBuilder: Sendable {
    private let context: DatabaseContext
    private let groupIdentifier: String
    private let fieldName: String
    private var indexNameOverride: String?
    private var mode: String = "top"
    private var count: Int = 10
    private var rangeStart: Int = 0
    private var rangeEnd: Int = 10
    private var percentileValue: Double = 0.5
    private var partitionValues: [String: String]?
    private var options: ReadExecutionOptions = .default

    init(
        context: DatabaseContext,
        groupIdentifier: String,
        fieldName: String
    ) {
        self.context = context
        self.groupIdentifier = groupIdentifier
        self.fieldName = fieldName
    }

    public func top(_ count: Int) -> Self {
        var copy = self
        copy.mode = "top"
        copy.count = count
        return copy
    }

    public func bottom(_ count: Int) -> Self {
        var copy = self
        copy.mode = "bottom"
        copy.count = count
        return copy
    }

    public func range(from: Int, to: Int) -> Self {
        var copy = self
        copy.mode = "range"
        copy.rangeStart = from
        copy.rangeEnd = to
        return copy
    }

    public func percentile(_ value: Double) -> Self {
        var copy = self
        copy.mode = "percentile"
        copy.percentileValue = value
        return copy
    }

    public func indexName(_ name: String) -> Self {
        var copy = self
        copy.indexNameOverride = name
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

    public func execute() async throws -> PolymorphicRankQueryResult {
        let response = try await context.query(
            toSelectQuery(),
            options: options,
            partitionValues: partitionValues
        )

        let items = try response.rows.map { row in
            (
                item: try context.decodePolymorphicRow(row, groupIdentifier: groupIdentifier),
                rank: Int(row.annotations["rank"]?.int64Value ?? 0)
            )
        }
        return PolymorphicRankQueryResult(
            items: items,
            continuation: response.continuation?.token
        )
    }

    private func toSelectQuery() -> SelectQuery {
        var parameters: [String: QueryParameterValue] = [
            ClientRankReadParameter.fieldName: .string(fieldName)
        ]

        let limit: Int?
        switch mode {
        case "top", "bottom":
            parameters[ClientRankReadParameter.mode] = .string(mode)
            parameters[ClientRankReadParameter.count] = .int(Int64(count))
            limit = count
        case "range":
            parameters[ClientRankReadParameter.mode] = .string("range")
            parameters[ClientRankReadParameter.from] = .int(Int64(rangeStart))
            parameters[ClientRankReadParameter.to] = .int(Int64(rangeEnd))
            limit = max(rangeEnd - rangeStart, 0)
        case "percentile":
            parameters[ClientRankReadParameter.mode] = .string("percentile")
            parameters[ClientRankReadParameter.percentile] = .double(percentileValue)
            limit = 1
        default:
            parameters[ClientRankReadParameter.mode] = .string("top")
            parameters[ClientRankReadParameter.count] = .int(Int64(count))
            limit = count
        }

        return SelectQuery(
            projection: .all,
            source: .logical(
                LogicalSourceRef(
                    kindIdentifier: BuiltinLogicalSourceKind.polymorphic,
                    identifier: groupIdentifier
                )
            ),
            accessPath: .index(
                IndexScanSource(
                    indexName: indexNameOverride ?? "\(groupIdentifier)_rank_\(fieldName)",
                    kindIdentifier: "rank",
                    parameters: parameters
                )
            ),
            limit: limit
        )
    }
}

public struct PolymorphicBitmapQueryBuilder: Sendable {
    private enum Operation: Sendable {
        case equals(TupleQueryValue)
        case `in`([TupleQueryValue])
        case and([[TupleQueryValue]])
    }

    private let context: DatabaseContext
    private let groupIdentifier: String
    private let fieldName: String
    private var indexNameOverride: String?
    private var operation: Operation?
    private var limitCount: Int?
    private var partitionValues: [String: String]?
    private var options: ReadExecutionOptions = .default

    init(
        context: DatabaseContext,
        groupIdentifier: String,
        fieldName: String
    ) {
        self.context = context
        self.groupIdentifier = groupIdentifier
        self.fieldName = fieldName
    }

    public func equals(_ value: TupleQueryValue) -> Self {
        var copy = self
        copy.operation = .equals(value)
        return copy
    }

    public func `in`(_ values: [TupleQueryValue]) -> Self {
        var copy = self
        copy.operation = .in(values)
        return copy
    }

    public func all(_ valueSets: [[TupleQueryValue]]) -> Self {
        var copy = self
        copy.operation = .and(valueSets)
        return copy
    }

    public func limit(_ count: Int) -> Self {
        var copy = self
        copy.limitCount = count
        return copy
    }

    public func indexName(_ name: String) -> Self {
        var copy = self
        copy.indexNameOverride = name
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

    public func execute() async throws -> [any Persistable] {
        let response = try await context.query(
            try toSelectQuery(),
            options: options,
            partitionValues: partitionValues
        )
        return try response.rows.map { row in
            try context.decodePolymorphicRow(row, groupIdentifier: groupIdentifier)
        }
    }

    public func count() async throws -> Int {
        var countQuery = try toSelectQuery().replacing(
            projection: .items([
                ProjectionItem(.aggregate(.count(nil, distinct: false)), alias: "count")
            ])
        )
        countQuery = countQuery.replacing(limit: 1)
        countQuery = countQuery.replacing(offset: nil)
        let response = try await context.query(
            countQuery,
            options: .default,
            partitionValues: partitionValues
        )
        return Int(response.rows.first?.fields["count"]?.int64Value ?? 0)
    }

    private func toSelectQuery() throws -> SelectQuery {
        guard let operation else {
            throw ClientPolymorphicQueryError.invalidRequest("Bitmap operation is required")
        }

        var parameters: [String: QueryParameterValue] = [
            ClientBitmapReadParameter.fieldName: .string(fieldName)
        ]
        if let limitCount {
            parameters[ClientBitmapReadParameter.limit] = .int(Int64(limitCount))
        }

        switch operation {
        case .equals(let value):
            parameters[ClientBitmapReadParameter.operation] = .string(ClientBitmapReadParameter.equalsOperation)
            parameters[ClientBitmapReadParameter.values] = .array([value.toQueryParameterValue()])
        case .in(let values):
            parameters[ClientBitmapReadParameter.operation] = .string(ClientBitmapReadParameter.inOperation)
            parameters[ClientBitmapReadParameter.values] = .array(
                values.map { $0.toQueryParameterValue() }
            )
        case .and(let valueSets):
            parameters[ClientBitmapReadParameter.operation] = .string(ClientBitmapReadParameter.andOperation)
            parameters[ClientBitmapReadParameter.valueSets] = .array(
                valueSets.map { valueSet in
                    .array(valueSet.map { $0.toQueryParameterValue() })
                }
            )
        }

        return SelectQuery(
            projection: .all,
            source: .logical(
                LogicalSourceRef(
                    kindIdentifier: BuiltinLogicalSourceKind.polymorphic,
                    identifier: groupIdentifier
                )
            ),
            accessPath: .index(
                IndexScanSource(
                    indexName: indexNameOverride ?? "\(groupIdentifier)_bitmap_\(fieldName)",
                    kindIdentifier: "bitmap",
                    parameters: parameters
                )
            ),
            limit: limitCount
        )
    }
}

public struct PolymorphicPermutedQueryBuilder: Sendable {
    private enum QueryType: Sendable {
        case prefix([TupleQueryValue])
        case exact([TupleQueryValue])
        case all
    }

    private let context: DatabaseContext
    private let groupIdentifier: String
    private let indexName: String
    private let permutation: Permutation?
    private var queryType: QueryType = .all
    private var limitCount: Int?
    private var partitionValues: [String: String]?
    private var options: ReadExecutionOptions = .default

    init(
        context: DatabaseContext,
        groupIdentifier: String,
        indexName: String,
        permutation: Permutation?
    ) {
        self.context = context
        self.groupIdentifier = groupIdentifier
        self.indexName = indexName
        self.permutation = permutation
    }

    public func prefix(_ values: [TupleQueryValue]) -> Self {
        var copy = self
        copy.queryType = .prefix(values)
        return copy
    }

    public func exact(_ values: [TupleQueryValue]) -> Self {
        var copy = self
        copy.queryType = .exact(values)
        return copy
    }

    public func all() -> Self {
        var copy = self
        copy.queryType = .all
        return copy
    }

    public func limit(_ count: Int) -> Self {
        var copy = self
        copy.limitCount = count
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

    public func execute() async throws -> PolymorphicPermutedQueryResult {
        let response = try await context.query(
            toSelectQuery(),
            options: options,
            partitionValues: partitionValues
        )
        let items = try response.rows.map { row in
            try context.decodePolymorphicRow(row, groupIdentifier: groupIdentifier)
        }
        return PolymorphicPermutedQueryResult(
            items: items,
            continuation: response.continuation?.token
        )
    }

    private func toSelectQuery() -> SelectQuery {
        var parameters: [String: QueryParameterValue] = [:]
        if let permutation {
            parameters[ClientPermutedReadParameter.permutation] = .array(
                permutation.indices.map { .int(Int64($0)) }
            )
        }
        if let limitCount {
            parameters[ClientPermutedReadParameter.limit] = .int(Int64(limitCount))
        }

        switch queryType {
        case .prefix(let values):
            parameters[ClientPermutedReadParameter.queryType] = .string(ClientPermutedReadParameter.prefixQuery)
            parameters[ClientPermutedReadParameter.values] = .array(values.map { $0.toQueryParameterValue() })
        case .exact(let values):
            parameters[ClientPermutedReadParameter.queryType] = .string(ClientPermutedReadParameter.exactQuery)
            parameters[ClientPermutedReadParameter.values] = .array(values.map { $0.toQueryParameterValue() })
        case .all:
            parameters[ClientPermutedReadParameter.queryType] = .string(ClientPermutedReadParameter.allQuery)
        }

        return SelectQuery(
            projection: .all,
            source: .logical(
                LogicalSourceRef(
                    kindIdentifier: BuiltinLogicalSourceKind.polymorphic,
                    identifier: groupIdentifier
                )
            ),
            accessPath: .index(
                IndexScanSource(
                    indexName: indexName,
                    kindIdentifier: "permuted",
                    parameters: parameters
                )
            ),
            limit: limitCount
        )
    }
}

public struct PolymorphicVersionQueryBuilder: Sendable {
    private let context: DatabaseContext
    private let groupIdentifier: String
    private let reference: PolymorphicRecordReference
    private var limitCount: Int?
    private var indexNameOverride: String?
    private var partitionValues: [String: String]?
    private var options: ReadExecutionOptions = .default

    init(
        context: DatabaseContext,
        groupIdentifier: String,
        reference: PolymorphicRecordReference
    ) {
        self.context = context
        self.groupIdentifier = groupIdentifier
        self.reference = reference
    }

    public func limit(_ count: Int) -> Self {
        var copy = self
        copy.limitCount = count
        return copy
    }

    public func indexName(_ name: String) -> Self {
        var copy = self
        copy.indexNameOverride = name
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

    public func execute() async throws -> PolymorphicVersionQueryResult {
        let response = try await context.query(
            try toSelectQuery(),
            options: options,
            partitionValues: partitionValues
        )

        let items: [(version: RecordVersion, item: any Persistable)] = try response.rows.map { row in
            guard let versionData = row.annotations["version"]?.dataValue else {
                throw ServiceError(
                    code: "INVALID_RESPONSE",
                    message: "Polymorphic version query response is missing version annotation."
                )
            }
            return (
                version: RecordVersion(bytes: versionData),
                item: try context.decodePolymorphicRow(row, groupIdentifier: groupIdentifier)
            )
        }

        return PolymorphicVersionQueryResult(
            items: items,
            continuation: response.continuation?.token
        )
    }

    public func latest() async throws -> (version: RecordVersion, item: any Persistable)? {
        try await limit(1).execute().items.first
    }

    private func toSelectQuery() throws -> SelectQuery {
        guard reference.groupIdentifier == groupIdentifier else {
            throw ClientPolymorphicQueryError.invalidRequest(
                "Polymorphic record reference for '\(reference.groupIdentifier)' cannot be queried from '\(groupIdentifier)'."
            )
        }

        let typeCode = try context.polymorphicTypeCode(
            groupIdentifier: groupIdentifier,
            typeName: reference.typeName
        )
        let primaryKey = [
            QueryParameterValue.int(typeCode)
        ] + reference.idComponents.map { $0.toQueryParameterValue() }

        var parameters: [String: QueryParameterValue] = [
            ClientVersionReadParameter.primaryKey: .array(primaryKey)
        ]
        if let limitCount {
            parameters[ClientVersionReadParameter.limit] = .int(Int64(limitCount))
        }
        if let indexNameOverride {
            parameters[ClientVersionReadParameter.indexName] = .string(indexNameOverride)
        }

        return SelectQuery(
            projection: .all,
            source: .logical(
                LogicalSourceRef(
                    kindIdentifier: BuiltinLogicalSourceKind.polymorphic,
                    identifier: groupIdentifier
                )
            ),
            accessPath: .index(
                IndexScanSource(
                    indexName: buildIndexName(),
                    kindIdentifier: "version",
                    parameters: parameters
                )
            ),
            limit: limitCount
        )
    }

    private func buildIndexName() -> String {
        if let indexNameOverride {
            return indexNameOverride
        }
        if let group = context.schema?.polymorphicGroup(identifier: groupIdentifier),
           let descriptor = group.indexes.first(where: { $0.kindIdentifier == "version" }) {
            return descriptor.name
        }
        return "\(groupIdentifier)_version_id"
    }
}
