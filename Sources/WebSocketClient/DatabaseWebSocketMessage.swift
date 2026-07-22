#if !os(WASI)
import Foundation

public enum DatabaseWebSocketMessage: Sendable {
    case data(Data)
    case string(String)
}
#endif
