import Synchronization

/// Retained identity prevents stale handles from adopting a later configuration.
final class AccessGeneration: Sendable {
    private let valid = Mutex(true)
    var isValid: Bool { valid.withLock { $0 } }
    func invalidate() { valid.withLock { $0 = false } }
}
