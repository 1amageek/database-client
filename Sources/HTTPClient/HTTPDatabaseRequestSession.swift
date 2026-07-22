#if !os(WASI)
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DatabaseClient
import DatabaseValue
import Foundation
import Synchronization

final class HTTPDatabaseRequestSession:
    NSObject,
    URLSessionDataDelegate,
    Sendable {
    private struct RequestLifecycle: Sendable {
        var body = HTTPDatabaseResponseBody()
        var response: URLResponse?
        var continuation:
            CheckedContinuation<(DatabaseBytes, URLResponse), any Error>?
        var session: URLSession?
        var task: URLSessionDataTask?
        var cancellationRequested = false
        var completed = false
    }

    private let maximumResponseBytes: Int
    private let configuration: URLSessionConfiguration
    private let state = Mutex(RequestLifecycle())

    init(
        maximumResponseBytes: Int,
        configuration: URLSessionConfiguration
    ) {
        self.maximumResponseBytes = maximumResponseBytes
        self.configuration = configuration
    }

    func data(
        for request: URLRequest
    ) async throws -> (DatabaseBytes, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                let task = session.dataTask(with: request)
                let cancellationRequested = state.withLock { state in
                    state.continuation = continuation
                    state.session = session
                    state.task = task
                    return state.cancellationRequested
                }
                if cancellationRequested {
                    completeRequest(
                        .failure(CancellationError()),
                        cancelSession: true
                    )
                    return
                }
                task.resume()
            }
        } onCancel: {
            self.cancelRequest()
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
            completeRequest(
                .failure(
                    DatabaseTransportError.invalidResponse(
                        "HTTP response exceeds the configured byte limit"
                    )
                ),
                cancelSession: true
            )
            return
        }
        let shouldAllow = state.withLock { state in
            guard !state.completed else {
                return false
            }
            state.response = response
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
            guard !state.completed else {
                return false
            }
            return !state.body.append(
                data,
                maximumBytes: maximumResponseBytes
            )
        }
        guard exceededLimit else {
            return
        }
        dataTask.cancel()
        completeRequest(
            .failure(
                DatabaseTransportError.invalidResponse(
                    "HTTP response exceeds the configured byte limit"
                )
            ),
            cancelSession: true
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            completeRequest(.failure(error), cancelSession: false)
            return
        }
        let result: Result<(DatabaseBytes, URLResponse), any Error> =
            state.withLock { state in
                guard let response = state.response else {
                    return .failure(
                        DatabaseTransportError.invalidResponse(
                            "HTTP transport received no response"
                        )
                    )
                }
                return .success((state.body.assembleBytes(), response))
            }
        completeRequest(result, cancelSession: false)
    }

    private func cancelRequest() {
        let hasRegisteredContinuation = state.withLock { state in
            state.cancellationRequested = true
            return state.continuation != nil
        }
        guard hasRegisteredContinuation else {
            return
        }
        completeRequest(.failure(CancellationError()), cancelSession: true)
    }

    private func completeRequest(
        _ result: Result<(DatabaseBytes, URLResponse), any Error>,
        cancelSession: Bool
    ) {
        let completionResources = state.withLock { state -> (
            CheckedContinuation<(DatabaseBytes, URLResponse), any Error>?,
            URLSession?
        ) in
            guard !state.completed, let continuation = state.continuation else {
                return (nil, nil)
            }
            state.completed = true
            let session = state.session
            state.continuation = nil
            state.session = nil
            state.task = nil
            state.body = HTTPDatabaseResponseBody()
            return (continuation, session)
        }
        guard let continuation = completionResources.0 else {
            return
        }
        if cancelSession {
            completionResources.1?.invalidateAndCancel()
        } else {
            completionResources.1?.finishTasksAndInvalidate()
        }
        continuation.resume(with: result)
    }
}
#endif
