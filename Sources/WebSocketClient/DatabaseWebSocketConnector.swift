#if !os(WASI)
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol DatabaseWebSocketConnector: Sendable {
    func connect(
        for request: URLRequest
    ) -> any DatabaseWebSocketConnection
}
#endif
