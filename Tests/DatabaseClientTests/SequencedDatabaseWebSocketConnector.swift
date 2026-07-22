#if !os(WASI)
import DatabaseClientWebSocket
import Foundation
import Synchronization

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SequencedDatabaseWebSocketConnector: DatabaseWebSocketConnector {
    private struct State {
        let connections: [ScriptedDatabaseWebSocketConnection]
        var requests: [URLRequest] = []
        var nextConnectionIndex = 0
    }

    private let state: Mutex<State>

    init(connections: [ScriptedDatabaseWebSocketConnection]) {
        precondition(!connections.isEmpty)
        state = Mutex(State(connections: connections))
    }

    func connect(
        for request: URLRequest
    ) -> any DatabaseWebSocketConnection {
        state.withLock { state in
            precondition(
                state.nextConnectionIndex < state.connections.count,
                "Test connector received more connection attempts than configured"
            )
            let connection = state.connections[state.nextConnectionIndex]
            state.nextConnectionIndex += 1
            state.requests.append(request)
            return connection
        }
    }

    var connectionCount: Int {
        state.withLock { $0.nextConnectionIndex }
    }
}
#endif
