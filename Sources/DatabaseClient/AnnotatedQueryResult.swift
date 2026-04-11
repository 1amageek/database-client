import Core

public struct AnnotatedRecord<T: Persistable>: Sendable {
    public let item: T
    public let annotations: [String: FieldValue]

    public init(item: T, annotations: [String: FieldValue]) {
        self.item = item
        self.annotations = annotations
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
