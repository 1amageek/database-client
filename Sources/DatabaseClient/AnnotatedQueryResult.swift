import Core
import DatabaseClientProtocol

public struct AnnotatedRecord<T: Persistable>: Sendable {
    public let item: T
    public let annotations: [String: FieldValue]
    public let version: RecordVersionToken?

    public init(
        item: T,
        annotations: [String: FieldValue],
        version: RecordVersionToken? = nil
    ) {
        self.item = item
        self.annotations = annotations
        self.version = version
    }

    public func precondition(
        partitionValues: [String: String]? = nil,
        _ kind: (RecordVersionToken) -> WritePreconditionSpec = WritePreconditionSpec.matchesStored
    ) -> WritePreconditionEntry? {
        guard let version else { return nil }
        return WritePreconditionEntry(
            key: RecordKey(
                entityName: T.persistableType,
                id: .string(FieldValueDecoder.idString(item)),
                partitionValues: partitionValues
            ),
            precondition: kind(version)
        )
    }
}

public struct AnnotatedQueryResult<T: Persistable>: Sendable {
    public let records: [AnnotatedRecord<T>]
    public let continuation: String?
    public let metadata: [String: FieldValue]

    public var items: [T] {
        records.map(\.item)
    }

    public var hasMore: Bool {
        continuation != nil
    }

    public init(
        records: [AnnotatedRecord<T>],
        continuation: String? = nil,
        metadata: [String: FieldValue] = [:]
    ) {
        self.records = records
        self.continuation = continuation
        self.metadata = metadata
    }
}
