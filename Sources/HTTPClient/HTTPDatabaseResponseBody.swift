#if !os(WASI)
import DatabaseTypes
import Foundation

struct HTTPDatabaseResponseBody: Sendable {
    private(set) var fragments: [Data] = []
    private(set) var byteCount = 0

    mutating func append(
        _ fragment: Data,
        maximumBytes: Int
    ) -> Bool {
        guard !fragment.isEmpty else {
            return true
        }
        guard fragment.count <= maximumBytes,
              byteCount <= maximumBytes - fragment.count else {
            return false
        }
        fragments.append(fragment)
        byteCount += fragment.count
        return true
    }

    func assembleBytes() -> ByteString {
        switch fragments.count {
        case 0:
            return []
        case 1:
            return ByteString(
                retaining: HTTPResponseByteOwner(data: fragments[0])
            )
        default:
            return ByteString.copying(count: byteCount) { destination in
                var offset = 0
                for fragment in fragments {
                    fragment.withUnsafeBytes { source in
                        guard source.count > 0 else {
                            return
                        }
                        destination.baseAddress!
                            .advanced(by: offset)
                            .copyMemory(
                                from: source.baseAddress!,
                                byteCount: source.count
                            )
                        offset += source.count
                    }
                }
            }
        }
    }
}
#endif
