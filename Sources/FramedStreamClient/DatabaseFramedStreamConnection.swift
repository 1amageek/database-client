import DatabaseTypes

public enum DatabaseFramedStreamConnectionError: Error, Sendable, Equatable {
    case unavailable(String)
    case endOfStream(expectedByteCount: Int, actualByteCount: Int)
    case cancelled
}

/// A cancellation-aware, ordered byte stream owned by one framed transport.
///
/// `write` must not return until it has accepted the complete byte range. The
/// returned `ByteString` from `readExactly` must own or retain its bytes. Calling
/// `shutdown` must unblock every outstanding read and write before it returns.
public protocol DatabaseFramedStreamConnection: Sendable {
    func write(
        _ bytes: ByteString
    ) async throws(DatabaseFramedStreamConnectionError)

    func readExactly(
        _ byteCount: Int
    ) async throws(DatabaseFramedStreamConnectionError) -> ByteString

    func shutdown() async
}
