#if !os(WASI)
import DatabaseTypes
import Foundation

struct HTTPResponseByteOwner: ByteStringOwner {
    let data: Data

    var count: Int {
        data.count
    }

    func borrowBytes(
        _ body: (UnsafeRawBufferPointer) throws -> Void
    ) rethrows {
        try data.withUnsafeBytes(body)
    }
}
#endif
