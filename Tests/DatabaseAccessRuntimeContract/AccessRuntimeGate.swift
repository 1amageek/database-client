/// Coordinates lifecycle races without depending on elapsed wall time.
actor AccessRuntimeGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var releaseWait: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation { continuation in
            releaseWait = continuation
            entered = true
            entry?.resume(); entry = nil
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }
    func release() { releaseWait?.resume(); releaseWait = nil }
}
