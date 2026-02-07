import Foundation
import Core
import QueryIR
import DatabaseClientProtocol

/// Fluent query builder for remote database queries
///
/// Constructed via `DatabaseContext.find(_:)`. Supports KeyPath-based
/// predicates, sorting, pagination, and limit.
public struct QueryBuilder<T: Persistable>: Sendable {

    private let transport: any DatabaseTransport
    private var request: FetchRequest

    init(transport: any DatabaseTransport, entityName: String) {
        self.transport = transport
        self.request = FetchRequest(entityName: entityName)
    }

    /// Add a predicate filter (QueryIR.Expression)
    public func `where`(_ predicate: QueryIR.Expression) -> QueryBuilder<T> {
        var copy = self
        if let existing = copy.request.predicate {
            // Combine with AND
            copy.request = FetchRequest(
                entityName: request.entityName,
                predicate: .and(existing, predicate),
                sortDescriptors: request.sortDescriptors,
                limit: request.limit,
                continuation: request.continuation,
                partitionValues: request.partitionValues
            )
        } else {
            copy.request = FetchRequest(
                entityName: request.entityName,
                predicate: predicate,
                sortDescriptors: request.sortDescriptors,
                limit: request.limit,
                continuation: request.continuation,
                partitionValues: request.partitionValues
            )
        }
        return copy
    }

    /// Add a sort descriptor using KeyPath
    public func sort<V: FieldValueConvertible>(
        by keyPath: KeyPath<T, V>,
        ascending: Bool = true
    ) -> QueryBuilder<T> {
        var copy = self
        var sorts = copy.request.sortDescriptors
        sorts.append(SortKey(
            .column(ColumnRef(column: T.fieldName(for: keyPath))),
            direction: ascending ? .ascending : .descending
        ))
        copy.request = FetchRequest(
            entityName: request.entityName,
            predicate: request.predicate,
            sortDescriptors: sorts,
            limit: request.limit,
            continuation: request.continuation,
            partitionValues: request.partitionValues
        )
        return copy
    }

    /// Set maximum number of results
    public func limit(_ count: Int) -> QueryBuilder<T> {
        var copy = self
        copy.request = FetchRequest(
            entityName: request.entityName,
            predicate: request.predicate,
            sortDescriptors: request.sortDescriptors,
            limit: count,
            continuation: request.continuation,
            partitionValues: request.partitionValues
        )
        return copy
    }

    /// Set partition values for dynamic directory types
    public func partition(_ values: [String: String]) -> QueryBuilder<T> {
        var copy = self
        copy.request = FetchRequest(
            entityName: request.entityName,
            predicate: request.predicate,
            sortDescriptors: request.sortDescriptors,
            limit: request.limit,
            continuation: request.continuation,
            partitionValues: values
        )
        return copy
    }

    /// Continue from a previous query result
    public func continuation(_ token: String) -> QueryBuilder<T> {
        var copy = self
        copy.request = FetchRequest(
            entityName: request.entityName,
            predicate: request.predicate,
            sortDescriptors: request.sortDescriptors,
            limit: request.limit,
            continuation: token,
            partitionValues: request.partitionValues
        )
        return copy
    }

    /// Execute the query and return paginated results
    public func execute() async throws -> QueryResult<T> {
        let payload = try JSONEncoder().encode(request)
        let envelope = ServiceEnvelope(operationID: "fetch", payload: payload)
        let response = try await transport.send(envelope)

        if response.isError == true {
            throw ServiceError(
                code: response.errorCode ?? "UNKNOWN",
                message: response.errorMessage ?? "Unknown error"
            )
        }

        let fetchResponse = try JSONDecoder().decode(FetchResponse.self, from: response.payload)
        let items: [T] = try fetchResponse.records.map { try FieldValueDecoder.decode($0) }
        return QueryResult(items: items, continuation: fetchResponse.continuation)
    }

    /// Execute the query and return the count
    public func count() async throws -> Int {
        let countReq = CountRequest(
            entityName: request.entityName,
            predicate: request.predicate,
            partitionValues: request.partitionValues
        )
        let payload = try JSONEncoder().encode(countReq)
        let envelope = ServiceEnvelope(operationID: "count", payload: payload)
        let response = try await transport.send(envelope)

        if response.isError == true {
            throw ServiceError(
                code: response.errorCode ?? "UNKNOWN",
                message: response.errorMessage ?? "Unknown error"
            )
        }

        let countResponse = try JSONDecoder().decode(CountResponse.self, from: response.payload)
        return countResponse.count
    }

    /// Execute the query and return only the first result
    public func first() async throws -> T? {
        let result = try await limit(1).execute()
        return result.items.first
    }
}
