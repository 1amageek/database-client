#if os(WASI)
import DatabaseWire

public struct WorkerDatabaseConfiguration: Sendable, Hashable {
    public let requestEntrypointName: String
    public let requestTimeoutMilliseconds: UInt32
    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int

    public init(
        requestEntrypointName: String = "__databaseExecute",
        requestTimeoutMilliseconds: UInt32 = 25_000,
        maximumRequestBytes: Int = DatabaseWireLimits.default.maximumFrameBytes,
        maximumResponseBytes: Int = DatabaseWireLimits.default.maximumFrameBytes
    ) throws(WorkerDatabaseConfigurationError) {
        guard !requestEntrypointName.isEmpty else {
            throw .emptyRequestEntrypointName
        }
        guard requestTimeoutMilliseconds > 0 else {
            throw .invalidRequestTimeoutMilliseconds
        }
        guard maximumRequestBytes > 0 else {
            throw .invalidMaximumRequestBytes
        }
        guard maximumResponseBytes > 0 else {
            throw .invalidMaximumResponseBytes
        }
        self.requestEntrypointName = requestEntrypointName
        self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
    }

    public static let `default` = WorkerDatabaseConfiguration(
        validatedRequestEntrypointName: "__databaseExecute",
        requestTimeoutMilliseconds: 25_000,
        maximumRequestBytes: DatabaseWireLimits.default.maximumFrameBytes,
        maximumResponseBytes: DatabaseWireLimits.default.maximumFrameBytes
    )

    private init(
        validatedRequestEntrypointName: String,
        requestTimeoutMilliseconds: UInt32,
        maximumRequestBytes: Int,
        maximumResponseBytes: Int
    ) {
        self.requestEntrypointName = validatedRequestEntrypointName
        self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
    }
}
#endif
