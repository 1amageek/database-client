#if !os(WASI)
import DatabaseTypes
import Foundation
@testable import DatabaseClientHTTP
import Testing

@Suite("HTTP response body ownership")
struct HTTPDatabaseResponseBodyTests {
    @Test("a single URLSession chunk becomes independently bounded response storage")
    func singleChunkHasBoundedOwnedStorage() throws {
        let data = Data(repeating: 0xa5, count: 4_096)
        var body = HTTPDatabaseResponseBody()

        let accepted = body.append(data, maximumBytes: data.count)
        #expect(accepted)
        let bytes = body.assembleBytes()

        #expect(try address(of: bytes) != address(of: data))
        #expect(try #require(bytes.retainedByteCount) >= bytes.count)
        #expect(bytes.isStorageSelfContained)
        #expect(bytes.count == data.count)
        #expect(bytes.first == 0xa5)
    }

    @Test("a sliced Data chunk does not retain its enclosing allocation")
    func slicedChunkBecomesSelfContained() throws {
        let enclosing = Data(repeating: 0x5a, count: 8192)
        let slice = enclosing[1024..<4096]
        var body = HTTPDatabaseResponseBody()
        let accepted = body.append(slice, maximumBytes: slice.count)
        #expect(accepted)
        let bytes = body.assembleBytes()
        #expect(bytes.count == 3072)
        #expect(try #require(bytes.retainedByteCount) >= bytes.count)
        #expect(bytes.isStorageSelfContained)
        #expect(bytes.allSatisfy { $0 == 0x5a })
        #expect(try address(of: bytes) != address(of: slice))
    }

    @Test("multiple chunks consolidate directly into one final allocation")
    func multipleChunksAllocateOneContiguousResponse() throws {
        var body = HTTPDatabaseResponseBody()

        let acceptedFirst = body.append(Data([1, 2]), maximumBytes: 5)
        let acceptedSecond = body.append(Data([3, 4, 5]), maximumBytes: 5)
        #expect(acceptedFirst)
        #expect(acceptedSecond)
        let bytes = body.assembleBytes()

        #expect(try #require(bytes.retainedByteCount) >= bytes.count)
        #expect(bytes.withUnsafeBytes { $0.count } == 5)
        #expect(bytes == [1, 2, 3, 4, 5])
    }

    @Test("the byte limit is checked before an oversized chunk is retained")
    func oversizedChunkIsNotRetained() {
        var body = HTTPDatabaseResponseBody()

        let accepted = body.append(Data([1, 2]), maximumBytes: 3)
        let rejected = body.append(Data([3, 4]), maximumBytes: 3)
        #expect(accepted)
        #expect(!rejected)
        #expect(body.byteCount == 2)
        #expect(body.fragments.count == 1)
        #expect(body.assembleBytes() == [1, 2])
    }

    @Test("empty chunks do not consume fragment storage")
    func emptyChunkDoesNotConsumeFragmentStorage() {
        var body = HTTPDatabaseResponseBody()

        let accepted = body.append(Data(), maximumBytes: 2)
        #expect(accepted)
        #expect(body.byteCount == 0)
        #expect(body.fragments.isEmpty)
    }

    private func address(of bytes: ByteString) throws -> UInt {
        try #require(bytes.withUnsafeBytes { buffer in
            buffer.baseAddress.map { UInt(bitPattern: $0) }
        })
    }

    private func address(of data: Data) throws -> UInt {
        try #require(data.withUnsafeBytes { buffer in
            buffer.baseAddress.map { UInt(bitPattern: $0) }
        })
    }
}
#endif
