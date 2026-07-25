#if !os(WASI)
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DatabaseClient
import DatabaseTypes
import Foundation
import Synchronization

final class HTTPDatabaseResponseCoordinator:
    NSObject,
    URLSessionDataDelegate,
    Sendable {
    private struct RequestLifecycle: Sendable {
        var body = HTTPDatabaseResponseBody()
        var response: URLResponse?
        var continuation:
            CheckedContinuation<(ByteString, URLResponse), any Error>?
        var task: URLSessionDataTask?
        var cancellationRequested = false
    }

    private struct State: Sendable {
        var nextRequestID: UInt64 = 1
        var requests: [UInt64: RequestLifecycle] = [:]
        var requestIDsByTask: [Int: UInt64] = [:]
        var isInvalidated = false
    }

    private struct Completion: Sendable {
        let continuation:
            CheckedContinuation<(ByteString, URLResponse), any Error>
        let body: HTTPDatabaseResponseBody
        let response: URLResponse?
    }

    private enum RequestActivation {
        case resume(URLSessionDataTask)
        case complete(
            CheckedContinuation<(ByteString, URLResponse), any Error>,
            any Error
        )
    }

    private let maximumResponseBytes: Int
    private let state = Mutex(State())

    init(maximumResponseBytes: Int) {
        self.maximumResponseBytes = maximumResponseBytes
    }

    func reserveRequest() throws -> UInt64 {
        try state.withLock { state in
            guard !state.isInvalidated else {
                throw DatabaseTransportError.unavailable(
                    "HTTP database session is invalidated"
                )
            }
            let requestID = state.nextRequestID
            let next = requestID.addingReportingOverflow(1)
            guard !next.overflow else {
                throw DatabaseTransportError.unavailable(
                    "HTTP database request identifier space is exhausted"
                )
            }
            state.nextRequestID = next.partialValue
            state.requests[requestID] = RequestLifecycle()
            return requestID
        }
    }

    func response(
        for request: URLRequest,
        requestID: UInt64,
        session: URLSession
    ) async throws -> (ByteString, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let activation = state.withLock { state -> RequestActivation in
                guard !state.isInvalidated,
                      var lifecycle = state.requests[requestID] else {
                    return .complete(
                        continuation,
                        DatabaseTransportError.unavailable(
                            "HTTP database session is invalidated"
                        )
                    )
                }
                guard !lifecycle.cancellationRequested else {
                    state.requests.removeValue(forKey: requestID)
                    return .complete(continuation, CancellationError())
                }

                let task = session.dataTask(with: request)
                lifecycle.continuation = continuation
                lifecycle.task = task
                state.requests[requestID] = lifecycle
                state.requestIDsByTask[task.taskIdentifier] = requestID
                return .resume(task)
            }

            switch activation {
            case .resume(let task):
                task.resume()
            case .complete(let continuation, let error):
                continuation.resume(throwing: error)
            }
        }
    }

    func cancelRequest(_ requestID: UInt64) {
        let cancellation = state.withLock { state -> (
            URLSessionDataTask?,
            CheckedContinuation<(ByteString, URLResponse), any Error>?
        ) in
            guard var lifecycle = state.requests[requestID] else {
                return (nil, nil)
            }
            guard let continuation = lifecycle.continuation else {
                lifecycle.cancellationRequested = true
                state.requests[requestID] = lifecycle
                return (nil, nil)
            }
            state.requests.removeValue(forKey: requestID)
            if let task = lifecycle.task {
                state.requestIDsByTask.removeValue(
                    forKey: task.taskIdentifier
                )
            }
            return (lifecycle.task, continuation)
        }
        cancellation.0?.cancel()
        cancellation.1?.resume(throwing: CancellationError())
    }

    func invalidate() {
        let pending = state.withLock { state -> [RequestLifecycle] in
            guard !state.isInvalidated else {
                return []
            }
            state.isInvalidated = true
            let pending = Array(state.requests.values)
            state.requests.removeAll(keepingCapacity: false)
            state.requestIDsByTask.removeAll(keepingCapacity: false)
            return pending
        }
        for lifecycle in pending {
            lifecycle.task?.cancel()
            lifecycle.continuation?.resume(
                throwing: DatabaseTransportError.unavailable(
                    "HTTP database session is invalidated"
                )
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (
            URLSession.ResponseDisposition
        ) -> Void
    ) {
        let expected = response.expectedContentLength
        guard expected < 0 || expected <= Int64(maximumResponseBytes) else {
            completionHandler(.cancel)
            reject(
                dataTask,
                error: DatabaseTransportError.invalidResponse(
                    "HTTP response exceeds the configured byte limit"
                )
            )
            return
        }

        let shouldAllow = state.withLock { state in
            guard let requestID = state.requestIDsByTask[
                dataTask.taskIdentifier
            ], var lifecycle = state.requests[requestID] else {
                return false
            }
            lifecycle.response = response
            state.requests[requestID] = lifecycle
            return true
        }
        completionHandler(shouldAllow ? .allow : .cancel)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let exceededLimit = state.withLock { state in
            guard let requestID = state.requestIDsByTask[
                dataTask.taskIdentifier
            ], var lifecycle = state.requests[requestID] else {
                return false
            }
            guard lifecycle.body.append(
                data,
                maximumBytes: maximumResponseBytes
            ) else {
                return true
            }
            state.requests[requestID] = lifecycle
            return false
        }
        guard exceededLimit else {
            return
        }
        dataTask.cancel()
        reject(
            dataTask,
            error: DatabaseTransportError.invalidResponse(
                "HTTP response exceeds the configured byte limit"
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let completion = takeCompletion(for: task) else {
            return
        }
        if let error {
            completion.continuation.resume(throwing: error)
            return
        }
        guard let response = completion.response else {
            completion.continuation.resume(
                throwing: DatabaseTransportError.invalidResponse(
                    "HTTP transport received no response"
                )
            )
            return
        }
        completion.continuation.resume(
            returning: (completion.body.assembleBytes(), response)
        )
    }

    private func reject(
        _ task: URLSessionTask,
        error: any Error
    ) {
        guard let completion = takeCompletion(for: task) else {
            return
        }
        completion.continuation.resume(throwing: error)
    }

    private func takeCompletion(
        for task: URLSessionTask
    ) -> Completion? {
        state.withLock { state in
            guard let requestID = state.requestIDsByTask.removeValue(
                forKey: task.taskIdentifier
            ), let lifecycle = state.requests.removeValue(
                forKey: requestID
            ), let continuation = lifecycle.continuation else {
                return nil
            }
            return Completion(
                continuation: continuation,
                body: lifecycle.body,
                response: lifecycle.response
            )
        }
    }
}
#endif
