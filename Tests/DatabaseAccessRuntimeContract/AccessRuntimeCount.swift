import Synchronization

/// Retains synchronized fixture state across an escaping shutdown operation.
final class AccessRuntimeCount: Sendable {
    private let state = Mutex(0)
    var count: Int { state.withLock { $0 } }
    func recordShutdown() { state.withLock { $0 += 1 } }
}
