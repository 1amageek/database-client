#if !os(WASI)
import DatabaseClientWebSocket
import Foundation
import Synchronization

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CapturingDatabaseWebSocketConnector:
    DatabaseWebSocketConnector {
    private let connection: ScriptedDatabaseWebSocketConnection
    private let capturedRequestState = Mutex<URLRequest?>(nil)

    init(connection: ScriptedDatabaseWebSocketConnection) {
        self.connection = connection
    }

    func connect(
        for request: URLRequest
    ) -> any DatabaseWebSocketConnection {
        capturedRequestState.withLock { $0 = request }
        return connection
    }

    var capturedRequest: URLRequest? {
        capturedRequestState.withLock { $0 }
    }
}
#endif
