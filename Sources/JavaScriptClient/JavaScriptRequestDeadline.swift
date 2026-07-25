#if os(WASI)
import JavaScriptKit

actor JavaScriptRequestDeadline {
    private var timer: JSTimer?
    private var isCancelled = false

    func schedule(
        afterMilliseconds delay: UInt32,
        onExpiration: @escaping @Sendable () -> Void
    ) {
        guard !isCancelled, timer == nil else {
            return
        }
        timer = JSTimer(millisecondsDelay: Double(delay)) {
            onExpiration()
        }
    }

    func cancel() {
        isCancelled = true
        timer = nil
    }
}
#endif
