#if !os(WASI)
import DatabaseValue
import Foundation

struct HTTPResponseByteOwner: DatabaseByteOwner {
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
