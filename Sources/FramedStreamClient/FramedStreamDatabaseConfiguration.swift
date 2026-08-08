public enum FramedStreamDatabaseConfigurationError:
    Error,
    Sendable,
    Equatable
{
    case invalidMaximumRequestBytes
    case invalidMaximumResponseBytes
}

public struct FramedStreamDatabaseConfiguration: Sendable, Hashable {
    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int

    public init(
        maximumRequestBytes: Int = 16 * 1_024 * 1_024,
        maximumResponseBytes: Int = 16 * 1_024 * 1_024
    ) throws(FramedStreamDatabaseConfigurationError) {
        guard maximumRequestBytes > 0,
              UInt64(maximumRequestBytes) <= UInt64(UInt32.max)
        else {
            throw .invalidMaximumRequestBytes
        }
        guard maximumResponseBytes > 0,
              UInt64(maximumResponseBytes) <= UInt64(UInt32.max)
        else {
            throw .invalidMaximumResponseBytes
        }
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
    }
}
