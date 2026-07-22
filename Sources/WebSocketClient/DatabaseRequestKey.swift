#if !os(WASI)
struct DatabaseRequestKey: Sendable, Hashable {
    let connectionID: UInt64
    let requestID: UInt64
}
#endif
