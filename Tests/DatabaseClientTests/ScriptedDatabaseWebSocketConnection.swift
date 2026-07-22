#if !os(WASI)
import DatabaseClientWebSocket
import Foundation

actor ScriptedDatabaseWebSocketConnection: DatabaseWebSocketConnection {
    private var messages: [DatabaseWebSocketMessage]
    private var sentFrames: [Data] = []
    private var sendWaiter: CheckedContinuation<Void, Never>?
    private var receiveWaiter: CheckedContinuation<Void, Never>?
    private var frameCountWaiters: [FrameCountWaiter] = []
    private let waitsWhenEmpty: Bool
    private var isCancelled = false

    init(
        messages: [DatabaseWebSocketMessage],
        waitsWhenEmpty: Bool = false
    ) {
        self.messages = messages
        self.waitsWhenEmpty = waitsWhenEmpty
    }

    func send(_ data: Data) async throws {
        guard !isCancelled else {
            throw ScriptedDatabaseWebSocketError.cancelled
        }
        sentFrames.append(data)
        resumeFrameCountWaiters()
        sendWaiter?.resume()
        sendWaiter = nil
    }

    func receive() async throws -> DatabaseWebSocketMessage {
        if sentFrames.isEmpty, !isCancelled {
            await withCheckedContinuation { continuation in
                sendWaiter = continuation
            }
        }
        guard !isCancelled else {
            throw ScriptedDatabaseWebSocketError.cancelled
        }
        if messages.isEmpty, waitsWhenEmpty, !isCancelled {
            await withCheckedContinuation { continuation in
                receiveWaiter = continuation
            }
        }
        guard !isCancelled else {
            throw ScriptedDatabaseWebSocketError.cancelled
        }
        guard !messages.isEmpty else {
            throw ScriptedDatabaseWebSocketError.noMessage
        }
        return messages.removeFirst()
    }

    func cancel() async {
        isCancelled = true
        sendWaiter?.resume()
        sendWaiter = nil
        receiveWaiter?.resume()
        receiveWaiter = nil
        for waiter in frameCountWaiters {
            waiter.continuation.resume()
        }
        frameCountWaiters.removeAll()
    }

    func frames() -> [Data] {
        sentFrames
    }

    func append(_ message: DatabaseWebSocketMessage) {
        messages.append(message)
        receiveWaiter?.resume()
        receiveWaiter = nil
    }

    func waitForFrameCount(_ count: Int) async {
        guard sentFrames.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            frameCountWaiters.append(
                FrameCountWaiter(
                    count: count,
                    continuation: continuation
                )
            )
        }
    }

    private func resumeFrameCountWaiters() {
        var remaining: [FrameCountWaiter] = []
        remaining.reserveCapacity(frameCountWaiters.count)
        for waiter in frameCountWaiters {
            if sentFrames.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        frameCountWaiters = remaining
    }

    private struct FrameCountWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }
}

private enum ScriptedDatabaseWebSocketError: Error {
    case cancelled
    case noMessage
}
#endif
