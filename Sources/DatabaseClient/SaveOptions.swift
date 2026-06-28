#if !os(WASI)
import DatabaseClientProtocol

/// Options for one raw save request.
///
/// Idempotency is intentionally not exposed here because raw save replay state
/// is not yet committed atomically by the server runtime. Use typed command
/// operations for retry-safe non-idempotent mutations.
public struct SaveOptions: Sendable {
    public let preconditions: [WritePreconditionEntry]
    public let metadata: [String: String]

    public init(
        preconditions: [WritePreconditionEntry] = [],
        metadata: [String: String] = [:]
    ) {
        self.preconditions = preconditions
        self.metadata = metadata
    }

    public static let `default` = SaveOptions()
}

#endif
