import Core

/// Paginated query result
public struct QueryResult<T: Persistable>: Sendable {
    /// Matching items
    public let items: [T]

    /// Continuation token for the next page (nil if no more pages)
    public let continuation: String?

    /// Whether there are more pages available
    public var hasMore: Bool { continuation != nil }

    public init(items: [T], continuation: String? = nil) {
        self.items = items
        self.continuation = continuation
    }
}
