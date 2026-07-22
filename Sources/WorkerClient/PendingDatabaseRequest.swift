#if os(WASI)
import DatabaseClient
import DatabaseValue
import JavaScriptKit

@MainActor
final class PendingDatabaseRequest {
    private static let cancellationReason = "database-client:cancelled"
    private static let timeoutReason = "database-client:timeout"

    private let timeoutMilliseconds: UInt32
    private let maximumResponseBytes: Int
    private var continuation: CheckedContinuation<
        Result<DatabaseBytes, DatabaseTransportError>,
        Never
    >?
    private var unclaimedResult: Result<DatabaseBytes, DatabaseTransportError>?
    private var resolveCancellation: ((JSPromise.Result) -> Void)?
    private var resolveTimeout: ((JSPromise.Result) -> Void)?
    private var timeoutTimer: JSTimer?
    private var isCompleted = false

    init(
        timeoutMilliseconds: UInt32,
        maximumResponseBytes: Int
    ) {
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumResponseBytes = maximumResponseBytes
    }

    func wait(
        for responsePromise: JSPromise
    ) async -> Result<DatabaseBytes, DatabaseTransportError> {
        if let setupError = prepareResponseObservation(for: responsePromise) {
            return .failure(setupError)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                attachResponseContinuation(continuation)
            }
        } onCancel: {
            Task { @MainActor in
                self.handleCancellation()
            }
        }
    }

    private func prepareResponseObservation(
        for responsePromise: JSPromise
    ) -> DatabaseTransportError? {
        var resolveCancellation: ((JSPromise.Result) -> Void)?
        let cancellationPromise = JSPromise { resolution in
            resolveCancellation = resolution
        }
        var resolveTimeout: ((JSPromise.Result) -> Void)?
        let timeoutPromise = JSPromise { resolution in
            resolveTimeout = resolution
        }
        guard let resolveCancellation,
              let resolveTimeout,
              let promiseConstructor = JSPromise.constructor,
              let arrayConstructor = JSArray.constructor,
              let raceFunction = promiseConstructor["race"].function else {
            return .unavailable(
                "Database request completion support is unavailable"
            )
        }
        self.resolveCancellation = resolveCancellation
        self.resolveTimeout = resolveTimeout

        let promises = arrayConstructor.new(
            responsePromise.jsObject,
            cancellationPromise.jsObject,
            timeoutPromise.jsObject
        )
        let raceValue = raceFunction(
            this: promiseConstructor,
            promises
        )
        guard let racePromise = JSPromise(from: raceValue) else {
            return .unavailable(
                "Database request completion did not return a Promise"
            )
        }
        timeoutTimer = JSTimer(
            millisecondsDelay: Double(timeoutMilliseconds)
        ) {
            Task { @MainActor in
                self.handleTimeout()
            }
        }
        _ = racePromise.then(
            success: { value in
                let result = Self.decodeResponse(
                    value,
                    maximumResponseBytes: self.maximumResponseBytes
                )
                Task { @MainActor in
                    self.complete(with: result)
                }
                return .undefined
            },
            failure: { reason in
                let error = Self.transportError(from: reason)
                Task { @MainActor in
                    self.complete(with: .failure(error))
                }
                return .undefined
            }
        )
        return nil
    }

    private func attachResponseContinuation(
        _ continuation: CheckedContinuation<
            Result<DatabaseBytes, DatabaseTransportError>,
            Never
        >
    ) {
        if let unclaimedResult {
            self.unclaimedResult = nil
            continuation.resume(returning: unclaimedResult)
            return
        }
        self.continuation = continuation
    }

    private func handleCancellation() {
        guard !isCompleted else {
            return
        }
        resolveCancellation?(
            .failure(.string(Self.cancellationReason))
        )
        complete(with: .failure(.cancelled))
    }

    private func handleTimeout() {
        guard !isCompleted else {
            return
        }
        resolveTimeout?(
            .failure(.string(Self.timeoutReason))
        )
        complete(with: .failure(.timeout))
    }

    private func complete(
        with result: Result<DatabaseBytes, DatabaseTransportError>
    ) {
        guard !isCompleted else {
            return
        }
        isCompleted = true
        timeoutTimer = nil
        resolveCancellation = nil
        resolveTimeout = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        } else {
            unclaimedResult = result
        }
    }

    private static func decodeResponse(
        _ value: JSValue,
        maximumResponseBytes: Int
    ) -> Result<DatabaseBytes, DatabaseTransportError> {
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
        // final DatabaseBytes allocation from the exact Uint8Array view without
        // an intermediate Swift array or retaining its backing ArrayBuffer.
        let response = DatabaseBytes.copying(
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
        switch reason.string {
        case Self.cancellationReason:
            return .cancelled
        case Self.timeoutReason:
            return .timeout
        default:
            return .rejected(
                code: "database_entrypoint_rejected",
                message: String(describing: reason)
            )
        }
    }
}
#endif
