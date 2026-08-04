#if os(WASI)
@_spi(ExperimentalScheduling) import _Concurrency
import _CJavaScriptEventLoop
import JavaScriptEventLoop

@_expose(wasm, "database_client_install_test_executor")
@_cdecl("database_client_install_test_executor")
func installTestExecutor() {
    JavaScriptEventLoop.installGlobalExecutor()
    installDeadlineExecutorHook()
}

private func installDeadlineExecutorHook() {
    typealias DeadlineHook =
        @convention(thin) (
            Int64,
            Int64,
            Int64,
            Int64,
            Int32,
            UnownedJob,
            swift_task_enqueueGlobalWithDeadline_original
        ) -> Void
    let hook: DeadlineHook = {
        seconds,
        nanoseconds,
        _,
        _,
        clock,
        job,
        _ in
        var currentSeconds: Int64 = 0
        var currentNanoseconds: Int64 = 0
        swiftGetTime(&currentSeconds, &currentNanoseconds, clock)
        let delayMilliseconds = max(
            0,
            Double(seconds - currentSeconds) * 1_000
                + Double(nanoseconds - currentNanoseconds) / 1_000_000
        )
        JavaScriptEventLoop.shared.setTimeout(delayMilliseconds) {
            job.runSynchronously(
                on: JavaScriptEventLoop.shared.asUnownedSerialExecutor()
            )
        }
    }

    // The concurrency runtime owns each job until the installed process-wide
    // hook schedules it exactly once. The function pointer remains valid for
    // the test process lifetime, and no raw pointer is retained by Swift code.
    swift_task_enqueueGlobalWithDeadline_hook = unsafeBitCast(
        hook,
        to: UnsafeMutableRawPointer?.self
    )
}

@_silgen_name("swift_get_time")
private func swiftGetTime(
    _ seconds: UnsafeMutablePointer<Int64>,
    _ nanoseconds: UnsafeMutablePointer<Int64>,
    _ clock: CInt
)
#endif
