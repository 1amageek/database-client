import Foundation
import DatabaseClientProtocol
import Synchronization

/// WebSocket-based transport using URLSessionWebSocketTask
///
/// Internal implementation — users interact with DatabaseContext only.
final class WebSocketTransport: DatabaseTransport, Sendable {

    private let url: URL
    private let authToken: String?
    private let session: URLSession
    private let task: Mutex<URLSessionWebSocketTask?>
    private let pendingRequests: Mutex<[String: CheckedContinuation<ServiceEnvelope, any Error>]>

    init(url: URL, authToken: String? = nil) {
        self.url = url
        self.authToken = authToken
        self.session = URLSession(configuration: .default)
        self.task = Mutex(nil)
        self.pendingRequests = Mutex([:])
    }

    func connect() async throws {
        var request = URLRequest(url: url)
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let wsTask = session.webSocketTask(with: request)
        wsTask.resume()
        task.withLock { $0 = wsTask }
        startReceiving()
    }

    func send(_ envelope: ServiceEnvelope) async throws -> ServiceEnvelope {
        let wsTask = task.withLock { $0 }
        guard let wsTask else {
            throw ServiceError(code: "NOT_CONNECTED", message: "WebSocket is not connected")
        }

        let data = try JSONEncoder().encode(envelope)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests.withLock { $0[envelope.requestID] = continuation }

            Task {
                do {
                    try await wsTask.send(.data(data))
                } catch {
                    pendingRequests.withLock {
                        if let cont = $0.removeValue(forKey: envelope.requestID) {
                            cont.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }

    func disconnect() async {
        let wsTask = task.withLock { t -> URLSessionWebSocketTask? in
            let current = t
            t = nil
            return current
        }
        wsTask?.cancel(with: .normalClosure, reason: nil)

        // Cancel all pending requests
        let pending = pendingRequests.withLock { p -> [String: CheckedContinuation<ServiceEnvelope, any Error>] in
            let current = p
            p.removeAll()
            return current
        }
        for (_, continuation) in pending {
            continuation.resume(throwing: ServiceError(code: "DISCONNECTED", message: "Connection closed"))
        }
    }

    // MARK: - Private

    private func startReceiving() {
        Task { [weak self] in
            guard let self else { return }
            while let wsTask = self.task.withLock({ $0 }) {
                do {
                    let message = try await wsTask.receive()
                    switch message {
                    case .data(let data):
                        let response = try JSONDecoder().decode(ServiceEnvelope.self, from: data)
                        self.pendingRequests.withLock {
                            if let continuation = $0.removeValue(forKey: response.requestID) {
                                continuation.resume(returning: response)
                            }
                        }
                    case .string(let text):
                        guard let data = text.data(using: .utf8) else { continue }
                        let response = try JSONDecoder().decode(ServiceEnvelope.self, from: data)
                        self.pendingRequests.withLock {
                            if let continuation = $0.removeValue(forKey: response.requestID) {
                                continuation.resume(returning: response)
                            }
                        }
                    @unknown default:
                        continue
                    }
                } catch {
                    // Connection closed or error
                    break
                }
            }
        }
    }
}
