#if os(WASI)
import DatabaseClient
import DatabaseTypes
import JavaScriptKit
import Synchronization

final class PendingJavaScriptRequest: Sendable {
    private struct State {
        var continuation: CheckedContinuation<
            Result<ByteString, DatabaseTransportError>,
            Never
        >?
        var unclaimedResult: Result<ByteString, DatabaseTransportError>?
        var deadline: JavaScriptRequestDeadline?
        var isCompleted = false
    }

    private let timeoutMilliseconds: UInt32
    private let maximumResponseBytes: Int
    private let state = Mutex(State())

    init(
        timeoutMilliseconds: UInt32,
        maximumResponseBytes: Int
    ) {
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumResponseBytes = maximumResponseBytes
    }

    func wait(
        for responsePromise: JSPromise
    ) async -> Result<ByteString, DatabaseTransportError> {
        await observe(for: responsePromise)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                attachResponseContinuation(continuation)
            }
        } onCancel: {
            self.complete(with: .failure(.cancelled))
        }
    }

    private func observe(
        for responsePromise: JSPromise
    ) async {
        let deadline = JavaScriptRequestDeadline()
        await deadline.schedule(
            afterMilliseconds: timeoutMilliseconds
        ) {
            self.complete(with: .failure(.timeout))
        }
        let shouldObserveResponse = state.withLock { state in
            guard !state.isCompleted else {
                return false
            }
            state.deadline = deadline
            return true
        }
        guard shouldObserveResponse else {
            await deadline.cancel()
            return
        }
        _ = responsePromise.then(
            success: { value in
                let result = Self.decodeResponse(
                    value,
                    maximumResponseBytes: self.maximumResponseBytes
                )
                self.complete(with: result)
                return .undefined
            },
            failure: { reason in
                let error = Self.transportError(from: reason)
                self.complete(with: .failure(error))
                return .undefined
            }
        )
    }

    private func attachResponseContinuation(
        _ continuation: CheckedContinuation<
            Result<ByteString, DatabaseTransportError>,
            Never
        >
    ) {
        let unclaimedResult = state.withLock { state
            -> Result<ByteString, DatabaseTransportError>? in
            if let result = state.unclaimedResult {
                state.unclaimedResult = nil
                return result
            }
            state.continuation = continuation
            return nil
        }
        if let unclaimedResult {
            continuation.resume(returning: unclaimedResult)
        }
    }

    private func complete(
        with result: Result<ByteString, DatabaseTransportError>
    ) {
        let completion = state.withLock { state
            -> (
                CheckedContinuation<
                    Result<ByteString, DatabaseTransportError>,
                    Never
                >?,
                JavaScriptRequestDeadline?
            )? in
            guard !state.isCompleted else {
                return nil
            }
            state.isCompleted = true
            let continuation = state.continuation
            state.continuation = nil
            if continuation == nil {
                state.unclaimedResult = result
            }
            let deadline = state.deadline
            state.deadline = nil
            return (continuation, deadline)
        }
        guard let completion else {
            return
        }
        if let deadline = completion.1 {
            Task {
                await deadline.cancel()
            }
        }
        if let continuation = completion.0 {
            continuation.resume(returning: result)
        }
    }

    private static func decodeResponse(
        _ value: JSValue,
        maximumResponseBytes: Int
    ) -> Result<ByteString, DatabaseTransportError> {
        guard let responseArray = JSUint8Array(from: value) else {
            return .failure(
                .invalidResponse(
                    "Database request entrypoint did not return Uint8Array"
                )
            )
        }
        guard responseArray.length <= maximumResponseBytes else {
            return .failure(
                .invalidResponse(
                    "Database response exceeds the configured byte limit"
                )
            )
        }
        // JavaScript memory cannot be adopted by Swift. Copy directly into the
        // final ByteString allocation from the exact Uint8Array view without
        // an intermediate Swift array or retaining its backing ArrayBuffer.
        let response = ByteString.copying(
            count: responseArray.length
        ) { bytes in
            responseArray.copyMemory(
                to: bytes.bindMemory(to: UInt8.self)
            )
        }
        return .success(response)
    }

    private static func transportError(
        from reason: JSValue
    ) -> DatabaseTransportError {
        .rejected(
            code: "database_entrypoint_rejected",
            message: String(describing: reason)
        )
    }
}
#endif
