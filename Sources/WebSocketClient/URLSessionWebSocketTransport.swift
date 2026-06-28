#if !os(WASI)
import DatabaseClient
import Foundation
import DatabaseClientProtocol
import Synchronization

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// WebSocket-based transport using URLSessionWebSocketTask
///
/// URLSession-backed implementation for native platforms.
public final class URLSessionWebSocketTransport: Transport, Sendable {
    private struct PendingRequest {
        let continuation: CheckedContinuation<ServiceEnvelope, any Error>
        let timeoutTask: Task<Void, Never>?
    }

    private struct RequestState {
        var pending: [String: PendingRequest] = [:]
        var canceledBeforeRegistration: Set<String> = []
    }

    private let url: URL
    private let authToken: String?
    private let requestTimeout: TimeInterval
    private let session: URLSession
    private let task: Mutex<URLSessionWebSocketTask?>
    private let requests: Mutex<RequestState>

    public init(
        url: URL,
        authToken: String? = nil,
        requestTimeout: TimeInterval = 30
    ) {
        self.url = url
        self.authToken = authToken
        self.requestTimeout = requestTimeout
        self.session = URLSession(configuration: .default)
        self.task = Mutex(nil)
        self.requests = Mutex(RequestState())
    }

    public func connect() async throws {
        var request = URLRequest(url: url)
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let wsTask = session.webSocketTask(with: request)
        wsTask.resume()
        task.withLock { $0 = wsTask }
        startReceiving()
    }

    public func send(_ envelope: ServiceEnvelope) async throws -> ServiceEnvelope {
        let wsTask = task.withLock { $0 }
        guard let wsTask else {
            throw ServiceError(code: "NOT_CONNECTED", message: "WebSocket is not connected")
        }

        let data = try JSONEncoder().encode(envelope)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let timeoutTask = makeTimeoutTask(for: envelope.requestID)
                let shouldCancelImmediately = requests.withLock { state in
                    if state.canceledBeforeRegistration.remove(envelope.requestID) != nil {
                        return true
                    }
                    state.pending[envelope.requestID] = PendingRequest(
                        continuation: continuation,
                        timeoutTask: timeoutTask
                    )
                    return false
                }

                if shouldCancelImmediately {
                    timeoutTask?.cancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }

                Task {
                    do {
                        try await wsTask.send(.data(data))
                    } catch {
                        resumePendingRequest(id: envelope.requestID, throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelPendingRequest(id: envelope.requestID)
        }
    }

    private func makeTimeoutTask(for requestID: String) -> Task<Void, Never>? {
        guard requestTimeout > 0 else {
            return nil
        }

        let nanoseconds = UInt64((requestTimeout * 1_000_000_000).rounded(.up))
        return Task { [requestTimeout] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            resumePendingRequest(
                id: requestID,
                throwing: ServiceError(
                    code: "TIMEOUT",
                    message: "Request timed out after \(requestTimeout) seconds"
                )
            )
        }
    }

    private func cancelPendingRequest(id: String) {
        let pending = requests.withLock { state -> PendingRequest? in
            if let pending = state.pending.removeValue(forKey: id) {
                return pending
            }
            state.canceledBeforeRegistration.insert(id)
            return nil
        }

        if let pending {
            pending.timeoutTask?.cancel()
            pending.continuation.resume(throwing: CancellationError())
        }
    }

    private func resumePendingRequest(
        id: String,
        returning response: ServiceEnvelope
    ) {
        let pending = requests.withLock { state in
            state.pending.removeValue(forKey: id)
        }

        if let pending {
            pending.timeoutTask?.cancel()
            pending.continuation.resume(returning: response)
        }
    }

    private func resumePendingRequest(
        id: String,
        throwing error: any Error
    ) {
        let pending = requests.withLock { state in
            state.pending.removeValue(forKey: id)
        }

        if let pending {
            pending.timeoutTask?.cancel()
            pending.continuation.resume(throwing: error)
        }
    }

    private func failAllPendingRequests(throwing error: any Error) {
        let pending = requests.withLock { state -> [PendingRequest] in
            let current = Array(state.pending.values)
            state.pending.removeAll()
            state.canceledBeforeRegistration.removeAll()
            return current
        }

        for request in pending {
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func resumeResponse(_ response: ServiceEnvelope) {
        resumePendingRequest(id: response.requestID, returning: response)
    }

    private func decodeResponse(from message: URLSessionWebSocketTask.Message) throws -> ServiceEnvelope? {
        switch message {
        case .data(let data):
            return try JSONDecoder().decode(ServiceEnvelope.self, from: data)
        case .string(let text):
            guard let data = text.data(using: .utf8) else {
                return nil
            }
            return try JSONDecoder().decode(ServiceEnvelope.self, from: data)
        @unknown default:
            return nil
        }
    }

    public func disconnect() async {
        let wsTask = task.withLock { t -> URLSessionWebSocketTask? in
            let current = t
            t = nil
            return current
        }
        wsTask?.cancel(with: .normalClosure, reason: nil)

        failAllPendingRequests(
            throwing: ServiceError(code: "DISCONNECTED", message: "Connection closed")
        )
    }

    // MARK: - Private

    private func startReceiving() {
        Task { [weak self] in
            guard let self else { return }
            while let wsTask = self.task.withLock({ $0 }) {
                do {
                    let message = try await wsTask.receive()
                    if let response = try self.decodeResponse(from: message) {
                        self.resumeResponse(response)
                    }
                } catch {
                    // Connection closed or error
                    self.failAllPendingRequests(throwing: error)
                    break
                }
            }
        }
    }
}

#endif
