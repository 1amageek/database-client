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
        var observation: JSPromiseObservation?
        var isCompletionClaimed = false
    }

    private struct CompletionClaim {
        let deadline: JavaScriptRequestDeadline?
        let observation: JSPromiseObservation?
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
        let shouldObserveResponse = state.withLock { state in
            guard !state.isCompletionClaimed else {
                return false
            }
            state.deadline = deadline
            return true
        }
        guard shouldObserveResponse else {
            await deadline.cancel()
            return
        }
        let observation = responsePromise.observe(
            success: { value in
                guard let claim = self.claimCompletion() else {
                    return .undefined
                }
                let result = Self.decodeResponse(
                    value,
                    maximumResponseBytes: self.maximumResponseBytes
                )
                self.finishCompletion(
                    with: result,
                    cancelling: claim
                )
                return .undefined
            },
            failure: { reason in
                guard let claim = self.claimCompletion() else {
                    return .undefined
                }
                let error = Self.transportError(from: reason)
                self.finishCompletion(
                    with: .failure(error),
                    cancelling: claim
                )
                return .undefined
            }
        )
        let didInstallObservation = state.withLock { state in
            guard !state.isCompletionClaimed else {
                return false
            }
            state.observation = observation
            return true
        }
        guard didInstallObservation else {
            observation.cancel()
            await deadline.cancel()
            return
        }
        await deadline.schedule(
            afterMilliseconds: timeoutMilliseconds
        ) {
            self.complete(with: .failure(.timeout))
        }
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
        guard let claim = claimCompletion() else {
            return
        }
        finishCompletion(with: result, cancelling: claim)
    }

    private func claimCompletion() -> CompletionClaim? {
        state.withLock { state in
            guard !state.isCompletionClaimed else {
                return nil
            }
            state.isCompletionClaimed = true
            let deadline = state.deadline
            state.deadline = nil
            let observation = state.observation
            state.observation = nil
            return CompletionClaim(
                deadline: deadline,
                observation: observation
            )
        }
    }

    private func finishCompletion(
        with result: Result<ByteString, DatabaseTransportError>,
        cancelling claim: CompletionClaim
    ) {
        let continuation = state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            if continuation == nil {
                state.unclaimedResult = result
            }
            return continuation
        }
        claim.observation?.cancel()
        if let deadline = claim.deadline {
            Task {
                await deadline.cancel()
            }
        }
        if let continuation {
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
        let responseByteCount: Int
        do {
            responseByteCount = try responseArray.validatedByteLength()
        } catch {
            return .failure(
                .invalidResponse(
                    "Database response contains an invalid Uint8Array view"
                )
            )
        }
        guard responseByteCount <= maximumResponseBytes else {
            return .failure(
                .invalidResponse(
                    "Database response exceeds the configured byte limit"
                )
            )
        }
        // JavaScript memory cannot be adopted by Swift. Copy directly into the
        // final ByteString allocation from the exact Uint8Array view without
        // an intermediate Swift array or retaining its backing ArrayBuffer.
        do {
            let response = try ByteString.copying(
                count: responseByteCount
            ) { bytes throws(JSTypedArrayCopyError) in
                try responseArray.copyBytes(to: bytes)
            }
            return .success(response)
        } catch {
            return .failure(
                .invalidResponse(
                    "Database response Uint8Array changed while being copied"
                )
            )
        }
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
