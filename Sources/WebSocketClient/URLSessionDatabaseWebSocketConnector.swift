#if !os(WASI)
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct URLSessionDatabaseWebSocketConnector:
    DatabaseWebSocketConnector {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(
        for request: URLRequest
    ) -> any DatabaseWebSocketConnection {
        let task = session.webSocketTask(with: request)
        task.resume()
        return ConnectedDatabaseWebSocket(task: task)
    }
}
#endif
