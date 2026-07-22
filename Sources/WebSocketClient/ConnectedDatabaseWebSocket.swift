#if !os(WASI)
import DatabaseClient
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ConnectedDatabaseWebSocket:
    DatabaseWebSocketConnection {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    public func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    public func receive() async throws -> DatabaseWebSocketMessage {
        switch try await task.receive() {
        case .data(let data):
            return .data(data)
        case .string(let string):
            return .string(string)
        @unknown default:
            throw DatabaseTransportError.invalidResponse(
                "Unknown WebSocket frame type"
            )
        }
    }

    public func cancel() async {
        task.cancel(with: .goingAway, reason: nil)
    }
}
#endif
