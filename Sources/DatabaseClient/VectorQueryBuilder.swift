import Foundation
import Core
import QueryIR
import DatabaseClientProtocol
import Vector

private enum ClientVectorReadParameter {
    static let fieldName = "fieldName"
    static let dimensions = "dimensions"
    static let queryVector = "queryVector"
    static let k = "k"
    static let metric = "metric"
}

public struct VectorEntryPoint<T: Persistable>: Sendable {
    private let context: DatabaseContext

    init(context: DatabaseContext) {
        self.context = context
    }

    public func vector(_ keyPath: KeyPath<T, [Float]>, dimensions: Int) -> VectorQueryBuilder<T> {
        VectorQueryBuilder(
            context: context,
            fieldName: T.fieldName(for: keyPath),
            dimensions: dimensions
        )
    }

    public func vector(_ keyPath: KeyPath<T, [Float]?>, dimensions: Int) -> VectorQueryBuilder<T> {
        VectorQueryBuilder(
            context: context,
            fieldName: T.fieldName(for: keyPath),
            dimensions: dimensions
        )
    }
}

public struct VectorQueryBuilder<T: Persistable>: Sendable {
    private let context: DatabaseContext
    private let fieldName: String
    private let dimensions: Int
    private var queryVector: [Float]?
    private var k: Int = 10
    private var metric: VectorMetric = .cosine
    private var partitionValues: [String: String]?
    private var options: ReadExecutionOptions = .default

    init(context: DatabaseContext, fieldName: String, dimensions: Int) {
        self.context = context
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

    public func execute() async throws -> VectorQueryResult<T> {
        let response = try await context.query(
            try makeSelectQuery(),
            options: options,
            partitionValues: partitionValues
        )

        let items: [(item: T, distance: Double)] = try response.rows.map { row in
            let item: T = try FieldValueDecoder.decode(row.fields)
            let distance = row.annotations["distance"]?.doubleValue ?? 0
            return (item: item, distance: distance)
        }

        return VectorQueryResult(
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
            source: .table(TableRef(table: T.persistableType)),
            accessPath: .index(
                IndexScanSource(
                    indexName: buildIndexName(),
                    kindIdentifier: VectorIndexKind<T>.identifier,
                    parameters: parameters
                )
            ),
            limit: k
        )
    }

    private func buildIndexName() -> String {
        if let descriptor = T.indexDescriptors.first(where: { descriptor in
            guard descriptor.kindIdentifier == VectorIndexKind<T>.identifier,
                  let kind = descriptor.kind as? VectorIndexKind<T> else {
                return false
            }
            return kind.fieldNames.contains(fieldName)
        }) {
            return descriptor.name
        }
        return "\(T.persistableType)_vector_\(fieldName)"
    }
}
