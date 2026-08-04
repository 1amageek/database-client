#if !os(WASI)
import DatabaseClientWebSocket
import Foundation

actor ScriptedDatabaseWebSocketConnection: DatabaseWebSocketConnection {
    private var messages: [DatabaseWebSocketMessage]
    private var sentFrames: [Data] = []
    private var sendWaiter: CheckedContinuation<Void, Never>?
    private var sendStartWaiter: CheckedContinuation<Void, Never>?
    private var sendCancellationWaiter: CheckedContinuation<Void, Never>?
    private var blockedSendWaiter: CheckedContinuation<Void, Never>?
    private var receiveWaiter: CheckedContinuation<Void, Never>?
    private var frameCountWaiters: [FrameCountWaiter] = []
    private let waitsWhenEmpty: Bool
    private let waitsDuringSend: Bool
    private let waitsAfterFirstSend: Bool
    private let releasesBlockedSendOnCancellation: Bool
    private var sendWasStarted = false
    private var sendCancellationWasObserved = false
    private var didBlockAfterSend = false
    private var sendDidFinish = false
    private var receiveDidFinish = false
    private var isCancelled = false

    init(
        messages: [DatabaseWebSocketMessage],
        waitsWhenEmpty: Bool = false,
        waitsDuringSend: Bool = false,
        waitsAfterFirstSend: Bool = false,
        releasesBlockedSendOnCancellation: Bool = true
    ) {
        self.messages = messages
        self.waitsWhenEmpty = waitsWhenEmpty
        self.waitsDuringSend = waitsDuringSend
        self.waitsAfterFirstSend = waitsAfterFirstSend
        self.releasesBlockedSendOnCancellation =
            releasesBlockedSendOnCancellation
    }

    func send(_ data: Data) async throws {
        defer { sendDidFinish = true }
        if waitsDuringSend {
            sendWasStarted = true
            sendStartWaiter?.resume()
            sendStartWaiter = nil
            await suspendSend(releaseOnCancellation: true)
        }
        guard !isCancelled, !Task.isCancelled else {
            throw ScriptedDatabaseWebSocketError.cancelled
        }
        sentFrames.append(data)
        resumeFrameCountWaiters()
        sendWaiter?.resume()
        sendWaiter = nil
        if waitsAfterFirstSend, !didBlockAfterSend {
            didBlockAfterSend = true
            sendWasStarted = true
            sendStartWaiter?.resume()
            sendStartWaiter = nil
            await suspendSend(
                releaseOnCancellation: releasesBlockedSendOnCancellation
            )
            guard !isCancelled, !Task.isCancelled else {
                throw ScriptedDatabaseWebSocketError.cancelled
            }
        }
        blockedSendWaiter?.resume()
        blockedSendWaiter = nil
    }

    func receive() async throws -> DatabaseWebSocketMessage {
        defer { receiveDidFinish = true }
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
        releaseBlockedSend()
        for waiter in frameCountWaiters {
            waiter.continuation.resume()
        }
        frameCountWaiters.removeAll()
    }

    func frames() -> [Data] {
        sentFrames
    }

    func cancellationWasRequested() -> Bool {
        isCancelled
    }

    func childOperationsDidFinish() -> Bool {
        sendDidFinish && receiveDidFinish
    }

    func waitForSendStart() async {
        guard !sendWasStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            sendStartWaiter = continuation
        }
    }

    func waitForSendCancellation() async {
        guard !sendCancellationWasObserved else {
            return
        }
        await withCheckedContinuation { continuation in
            sendCancellationWaiter = continuation
        }
    }

    func releaseBlockedSend() {
        blockedSendWaiter?.resume()
        blockedSendWaiter = nil
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

    private func suspendSend(
        releaseOnCancellation: Bool
    ) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                blockedSendWaiter = continuation
            }
        } onCancel: {
            Task {
                await self.observeSendCancellation(
                    releasesBlockedSend: releaseOnCancellation
                )
            }
        }
    }

    private func observeSendCancellation(
        releasesBlockedSend: Bool
    ) {
        sendCancellationWasObserved = true
        sendCancellationWaiter?.resume()
        sendCancellationWaiter = nil
        if releasesBlockedSend {
            releaseBlockedSend()
        }
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
