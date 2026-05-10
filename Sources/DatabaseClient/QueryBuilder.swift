import Foundation
import Core
import QueryIR
import DatabaseClientProtocol

/// Fluent query builder for remote database queries.
public struct QueryBuilder<T: Persistable>: Sendable {
    private static var keysetContinuationSeed: String { "keyset:v1" }

    private let transport: any DatabaseTransport
    private let entityName: String
    private var selectQuery: SelectQuery
    private var options: ReadExecutionOptions
    private var partitionValues: [String: String]?

    init(transport: any DatabaseTransport, entityName: String) {
        self.transport = transport
        self.entityName = entityName
        self.selectQuery = SelectQuery(
            projection: .all,
            source: .table(TableRef(table: entityName))
        )
        self.options = .default
        self.partitionValues = nil
    }

    public func `where`(_ predicate: QueryIR.Expression) -> QueryBuilder<T> {
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

    public func sort<V: FieldValueConvertible>(
        by keyPath: KeyPath<T, V>,
        ascending: Bool = true
    ) -> QueryBuilder<T> {
        var copy = self
        var sorts = copy.selectQuery.orderBy ?? []
        sorts.append(SortKey(
            .column(ColumnRef(column: T.fieldName(for: keyPath))),
            direction: ascending ? .ascending : .descending
        ))
        copy.selectQuery = copy.selectQuery.replacing(orderBy: sorts)
        return copy
    }

    public func limit(_ count: Int) -> QueryBuilder<T> {
        var copy = self
        copy.selectQuery = copy.selectQuery.replacing(limit: count)
        return copy
    }

    public func partition(_ values: [String: String]) -> QueryBuilder<T> {
        var copy = self
        copy.partitionValues = values
        return copy
    }

    public func continuation(_ token: String) -> QueryBuilder<T> {
        var copy = self
        copy.options = ReadExecutionOptions(
            consistency: copy.options.consistency,
            pageSize: copy.options.pageSize,
            continuation: QueryContinuation(token)
        )
        return copy
    }

    /// Requests keyset-based pagination from servers that support it.
    ///
    /// The continuation token remains opaque to the client. Servers that
    /// understand this seed token can return stable sort-key continuations
    /// instead of offset tokens.
    public func keysetPagination() -> QueryBuilder<T> {
        continuation(Self.keysetContinuationSeed)
    }

    public func pageSize(_ count: Int) -> QueryBuilder<T> {
        var copy = self
        copy.options = ReadExecutionOptions(
            consistency: copy.options.consistency,
            pageSize: count,
            continuation: copy.options.continuation
        )
        return copy
    }

    public func consistency(_ consistency: ReadConsistency) -> QueryBuilder<T> {
        var copy = self
        copy.options = ReadExecutionOptions(
            consistency: consistency,
            pageSize: copy.options.pageSize,
            continuation: copy.options.continuation
        )
        return copy
    }

    public func execute() async throws -> QueryResult<T> {
        let request = QueryRequest(
            statement: .select(selectQuery),
            options: options,
            partitionValues: partitionValues
        )
        let payload = try JSONEncoder().encode(request)
        let envelope = ServiceEnvelope(operationID: "query", payload: payload)
        let responseEnvelope = try await transport.send(envelope)

        if responseEnvelope.isError == true {
            throw ServiceError(
                code: responseEnvelope.errorCode ?? "UNKNOWN",
                message: responseEnvelope.errorMessage ?? "Unknown error"
            )
        }

        let response = try JSONDecoder().decode(QueryResponse.self, from: responseEnvelope.payload)
        let items: [T] = try response.rows.map { try FieldValueDecoder.decode($0.fields) }
        return QueryResult(items: items, continuation: response.continuation?.token)
    }

    public func executeAnnotated() async throws -> AnnotatedQueryResult<T> {
        let request = QueryRequest(
            statement: .select(selectQuery),
            options: options,
            partitionValues: partitionValues
        )
        let payload = try JSONEncoder().encode(request)
        let envelope = ServiceEnvelope(operationID: "query", payload: payload)
        let responseEnvelope = try await transport.send(envelope)

        if responseEnvelope.isError == true {
            throw ServiceError(
                code: responseEnvelope.errorCode ?? "UNKNOWN",
                message: responseEnvelope.errorMessage ?? "Unknown error"
            )
        }

        let response = try JSONDecoder().decode(QueryResponse.self, from: responseEnvelope.payload)
        let records: [AnnotatedRecord<T>] = try response.rows.map { row in
            AnnotatedRecord(
                item: try FieldValueDecoder.decode(row.fields),
                annotations: row.annotations,
                version: row.version
            )
        }
        return AnnotatedQueryResult(
            records: records,
            continuation: response.continuation?.token,
            metadata: response.metadata
        )
    }

    public func count() async throws -> Int {
        if selectQuery.accessPath != nil {
            throw ServiceError(
                code: "UNSUPPORTED_QUERY",
                message: "count() is not supported for access-path queries. Use a feature-specific count API."
            )
        }

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

        let request = QueryRequest(
            statement: .select(countQuery),
            options: .default,
            partitionValues: partitionValues
        )
        let payload = try JSONEncoder().encode(request)
        let envelope = ServiceEnvelope(operationID: "query", payload: payload)
        let responseEnvelope = try await transport.send(envelope)

        if responseEnvelope.isError == true {
            throw ServiceError(
                code: responseEnvelope.errorCode ?? "UNKNOWN",
                message: responseEnvelope.errorMessage ?? "Unknown error"
            )
        }

        let response = try JSONDecoder().decode(QueryResponse.self, from: responseEnvelope.payload)
        guard let row = response.rows.first,
              let count = row.fields["count"]?.int64Value else {
            return 0
        }
        return Int(count)
    }

    public func first() async throws -> T? {
        let result = try await limit(1).execute()
        return result.items.first
    }

    public func cursor(pageSize: Int = 100) -> ClientQueryCursor<T> {
        var copy = self
        copy = copy.pageSize(pageSize)
        return ClientQueryCursor(builder: copy)
    }

    public func stream(pageSize: Int = 100) -> AsyncThrowingStream<T, Error> {
        cursor(pageSize: pageSize).stream()
    }
}
