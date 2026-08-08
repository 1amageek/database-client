import DatabaseClient
@testable import DatabaseClientFramedStream
import DatabaseTypes
import DatabaseWire
import Testing

@Suite("DatabaseWire framed stream transport")
struct FramedStreamDatabaseTransportTests {
    @Test("request and response use the length-prefixed stream without combining payloads")
    func requestAndResponseTraverseStream() async throws {
        let call = DatabaseCall(
            operation: DatabaseOperations.capabilitiesDescribe,
            requestID: 41,
            request: EmptyOperationPayload()
        )
        let request = try call.encode()
        let response = try successResponse(requestID: 41)
        let connection = ScriptedFramedStreamConnection(
            reads: [.bytes(prefix(for: response.count)), .bytes(response)]
        )
        let transport = FramedStreamDatabaseTransport(
            configuration: try FramedStreamDatabaseConfiguration(),
            connection: connection
        )

        let received = try await transport.send(request)

        #expect(try call.decodeResponse(received).runtimeVersion == "v1")
        #expect(await connection.writtenBytes() == [prefix(for: request.count), request])
        await transport.shutdown()
        #expect(await connection.shutdownCount() == 1)
    }

    @Test("empty response frame is a typed protocol failure and closes the stream")
    func emptyResponseIsRejected() async throws {
        let request = try requestBytes(requestID: 42)
        let connection = ScriptedFramedStreamConnection(
            reads: [.bytes([0, 0, 0, 0])]
        )
        let transport = FramedStreamDatabaseTransport(
            configuration: try FramedStreamDatabaseConfiguration(),
            connection: connection
        )

        await #expect(
            throws: DatabaseTransportError.invalidResponse(
                "Framed stream response payload must not be empty"
            )
        ) {
            try await transport.send(request)
        }
        #expect(await connection.shutdownCount() == 1)
    }

    @Test("oversized response is rejected before reading its payload")
    func oversizedResponseIsRejectedBeforePayloadRead() async throws {
        let request = try requestBytes(requestID: 43)
        let connection = ScriptedFramedStreamConnection(
            reads: [.bytes(prefix(for: 5))]
        )
        let transport = FramedStreamDatabaseTransport(
            configuration: try FramedStreamDatabaseConfiguration(
                maximumResponseBytes: 4
            ),
            connection: connection
        )

        await #expect(
            throws: DatabaseTransportError.invalidResponse(
                "Framed stream response exceeds the configured byte limit"
            )
        ) {
            try await transport.send(request)
        }
        #expect(await connection.readCount() == 1)
        #expect(await connection.shutdownCount() == 1)
    }

    @Test("partial end of stream remains a typed invalid response")
    func partialEndOfStreamIsRejected() async throws {
        let request = try requestBytes(requestID: 44)
        let connection = ScriptedFramedStreamConnection(
            reads: [
                .bytes(prefix(for: 8)),
                .failure(.endOfStream(expectedByteCount: 8, actualByteCount: 3)),
            ]
        )
        let transport = FramedStreamDatabaseTransport(
            configuration: try FramedStreamDatabaseConfiguration(),
            connection: connection
        )

        await #expect(
            throws: DatabaseTransportError.invalidResponse(
                "Framed stream ended after 3 of 8 expected bytes"
            )
        ) {
            try await transport.send(request)
        }
        #expect(await connection.shutdownCount() == 1)
    }

    @Test("malformed length prefix closes the stream")
    func malformedLengthPrefixIsRejected() async throws {
        let request = try requestBytes(requestID: 441)
        let connection = ScriptedFramedStreamConnection(
            reads: [.bytes([0, 0, 1])]
        )
        let transport = FramedStreamDatabaseTransport(
            configuration: try FramedStreamDatabaseConfiguration(),
            connection: connection
        )

        await #expect(
            throws: DatabaseTransportError.invalidResponse(
                "Framed stream response length prefix must contain four bytes"
            )
        ) {
            try await transport.send(request)
        }
        #expect(await connection.shutdownCount() == 1)
    }

    @Test("mismatched response identity closes the stream")
    func mismatchedResponseIdentityIsRejected() async throws {
        let request = try requestBytes(requestID: 45)
        let response = try successResponse(requestID: 46)
        let connection = ScriptedFramedStreamConnection(
            reads: [.bytes(prefix(for: response.count)), .bytes(response)]
        )
        let transport = FramedStreamDatabaseTransport(
            configuration: try FramedStreamDatabaseConfiguration(),
            connection: connection
        )

        await #expect(
            throws: DatabaseTransportError.invalidResponse(
                "Framed stream response request identifier does not match"
            )
        ) {
            try await transport.send(request)
        }
        #expect(await connection.shutdownCount() == 1)
    }

    @Test("authoritative shutdown rejects later operations")
    func shutdownRejectsLaterOperations() async throws {
        let connection = ScriptedFramedStreamConnection(reads: [])
        let transport = FramedStreamDatabaseTransport(
            configuration: try FramedStreamDatabaseConfiguration(),
            connection: connection
        )
        await transport.shutdown()

        await #expect(
            throws: DatabaseTransportError.unavailable(
                "Framed stream database transport is shut down"
            )
        ) {
            try await transport.send(try requestBytes(requestID: 47))
        }
        #expect(await connection.shutdownCount() == 1)
    }

    @Test("configuration rejects non-positive and unrepresentable frame limits")
    func configurationRejectsInvalidLimits() {
        #expect(
            throws: FramedStreamDatabaseConfigurationError
                .invalidMaximumRequestBytes
        ) {
            _ = try FramedStreamDatabaseConfiguration(maximumRequestBytes: 0)
        }
        if Int.bitWidth > UInt32.bitWidth {
            #expect(
                throws: FramedStreamDatabaseConfigurationError
                    .invalidMaximumResponseBytes
            ) {
                _ = try FramedStreamDatabaseConfiguration(
                    maximumResponseBytes: Int(Int64(UInt32.max) + 1)
                )
            }
        }
    }
}

private actor ScriptedFramedStreamConnection:
    DatabaseFramedStreamConnection
{
    enum ReadAction: Sendable {
        case bytes(ByteString)
        case failure(DatabaseFramedStreamConnectionError)
    }

    private var reads: [ReadAction]
    private var writes: [ByteString] = []
    private var readsPerformed = 0
    private var shutdowns = 0

    init(reads: [ReadAction]) {
        self.reads = reads
    }

    func write(
        _ bytes: ByteString
    ) async throws(DatabaseFramedStreamConnectionError) {
        guard shutdowns == 0 else { throw .cancelled }
        writes.append(bytes)
    }

    func readExactly(
        _ byteCount: Int
    ) async throws(DatabaseFramedStreamConnectionError) -> ByteString {
        guard shutdowns == 0 else { throw .cancelled }
        guard !reads.isEmpty else {
            throw .endOfStream(expectedByteCount: byteCount, actualByteCount: 0)
        }
        readsPerformed += 1
        switch reads.removeFirst() {
        case .bytes(let bytes):
            return bytes
        case .failure(let error):
            throw error
        }
    }

    func shutdown() async {
        shutdowns += 1
    }

    func writtenBytes() -> [ByteString] {
        writes
    }

    func readCount() -> Int {
        readsPerformed
    }

    func shutdownCount() -> Int {
        shutdowns
    }
}

private func requestBytes(requestID: UInt64) throws -> ByteString {
    try DatabaseCall(
        operation: DatabaseOperations.capabilitiesDescribe,
        requestID: requestID,
        request: EmptyOperationPayload()
    ).encode()
}

private func successResponse(requestID: UInt64) throws -> ByteString {
    try DatabaseWireEncoder().encodeResponse(
        DatabaseOperations.capabilitiesDescribe,
        requestID: requestID,
        response: CapabilitiesDescribeOperation.Response(
            runtimeVersion: "v1",
            features: [],
            jobOperations: []
        )
    )
}

private func prefix(for byteCount: Int) -> ByteString {
    let length = UInt32(byteCount)
    return ByteString([
        UInt8(truncatingIfNeeded: length >> 24),
        UInt8(truncatingIfNeeded: length >> 16),
        UInt8(truncatingIfNeeded: length >> 8),
        UInt8(truncatingIfNeeded: length),
    ])
}
