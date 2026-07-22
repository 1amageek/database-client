#if !os(WASI)
import Foundation

public protocol DatabaseWebSocketConnection: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> DatabaseWebSocketMessage
    func cancel() async
}
#endif
