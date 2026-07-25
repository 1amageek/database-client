#if !os(WASI)
import DatabaseTypes
import Foundation

/// Keeps a received Foundation data frame alive while DatabaseWire borrows it.
struct ReceivedWebSocketFrameByteOwner: ByteStringOwner {
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
