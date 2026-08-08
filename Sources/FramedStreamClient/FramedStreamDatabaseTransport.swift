import DatabaseClient
import DatabaseTypes
import DatabaseWire

public actor FramedStreamDatabaseTransport: DatabaseTransport {
    private struct GateWaiter {
        let identifier: UInt64
        let continuation:
            CheckedContinuation<Result<Void, DatabaseTransportError>, Never>
    }

    private let configuration: FramedStreamDatabaseConfiguration
    private let connection: any DatabaseFramedStreamConnection
    private var gateOwner: UInt64?
    private var gateWaiters: [GateWaiter] = []
    private var gateCancellations: Set<UInt64> = []
    private var nextGateIdentifier: UInt64 = 1
    private var isShutdown = false
    private var isShutdownComplete = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateIdleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        configuration: FramedStreamDatabaseConfiguration,
        connection: any DatabaseFramedStreamConnection
    ) {
        self.configuration = configuration
        self.connection = connection
    }

    public func send(
        _ request: ByteString
    ) async throws(DatabaseTransportError) -> ByteString {
        guard !isShutdown else {
            throw .unavailable("Framed stream database transport is shut down")
        }
        guard !request.isEmpty else {
            throw .invalidRequest("Framed stream request payload must not be empty")
        }
        guard request.count <= configuration.maximumRequestBytes else {
            throw .rejected(
                code: "request_too_large",
                message: "Database request exceeds the configured byte limit"
            )
        }

        let requestHeader: DatabaseWireEnvelopeHeader
        do {
            requestHeader = try DatabaseWireDecoder().decodeRequestHeader(request)
        } catch {
            throw .invalidRequest(
                "Framed stream request has an invalid DatabaseWire header"
            )
        }

        let gateIdentifier = try reserveGateIdentifier()
        try await acquireGate(gateIdentifier)
        defer { releaseGate(gateIdentifier) }
        guard !isShutdown else {
            throw .cancelled
        }
        guard !Task.isCancelled else {
            throw .cancelled
        }

        do {
            try await connection.write(lengthPrefix(for: request.count))
            try await connection.write(request)

            let responseLengthBytes = try await connection.readExactly(4)
            let encodedResponseLength = try decodeLength(responseLengthBytes)
            guard encodedResponseLength > 0 else {
                return try await terminateForInvalidResponse(
                    "Framed stream response payload must not be empty"
                )
            }
            guard UInt64(encodedResponseLength)
                    <= UInt64(configuration.maximumResponseBytes) else {
                return try await terminateForInvalidResponse(
                    "Framed stream response exceeds the configured byte limit"
                )
            }
            let responseLength = Int(encodedResponseLength)
            let response = try await connection.readExactly(responseLength)
            guard response.count == responseLength else {
                return try await terminateForInvalidResponse(
                    "Framed stream response ended before its declared length"
                )
            }

            let responseHeader: DatabaseWireEnvelopeHeader
            do {
                responseHeader = try DatabaseWireDecoder()
                    .decodeResponseHeader(response)
            } catch {
                return try await terminateForInvalidResponse(
                    "Framed stream response has an invalid DatabaseWire header"
                )
            }
            guard responseHeader.requestID == requestHeader.requestID else {
                return try await terminateForInvalidResponse(
                    "Framed stream response request identifier does not match"
                )
            }
            return response
        } catch let error as DatabaseFramedStreamConnectionError {
            if isShutdown || Task.isCancelled || error == .cancelled {
                throw .cancelled
            }
            switch error {
            case .endOfStream(let expected, let actual):
                return try await terminateForInvalidResponse(
                    "Framed stream ended after \(actual) of \(expected) expected bytes"
                )
            case .unavailable(let message):
                await terminateConnection()
                throw .unavailable(message)
            case .cancelled:
                await terminateConnection()
                throw .cancelled
            }
        } catch is CancellationError {
            await terminateConnection()
            throw .cancelled
        } catch let error as DatabaseTransportError {
            if case .invalidResponse = error {
                await terminateConnection()
            }
            throw error
        } catch {
            await terminateConnection()
            throw .unavailable(
                "Framed stream transport failed unexpectedly"
            )
        }
    }

    public func shutdown() async {
        if isShutdown {
            guard !isShutdownComplete else { return }
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
            return
        }
        isShutdown = true
        failQueuedGateRequests(with: .cancelled)
        await connection.shutdown()
        if gateOwner != nil {
            await withCheckedContinuation { continuation in
                gateIdleWaiters.append(continuation)
            }
        }
        completeShutdown()
    }

    private func reserveGateIdentifier()
        throws(DatabaseTransportError) -> UInt64
    {
        guard nextGateIdentifier != 0 else {
            throw .unavailable(
                "Framed stream operation identifier space is exhausted"
            )
        }
        let identifier = nextGateIdentifier
        nextGateIdentifier = identifier == UInt64.max ? 0 : identifier + 1
        return identifier
    }

    private func acquireGate(
        _ identifier: UInt64
    ) async throws(DatabaseTransportError) {
        let result: Result<Void, DatabaseTransportError> =
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    enqueueGateRequest(
                        identifier: identifier,
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task { await self.cancelGateRequest(identifier) }
            }
        try result.get()
    }

    private func enqueueGateRequest(
        identifier: UInt64,
        continuation:
            CheckedContinuation<Result<Void, DatabaseTransportError>, Never>
    ) {
        if isShutdown {
            continuation.resume(returning: .failure(.cancelled))
            return
        }
        if gateCancellations.remove(identifier) != nil {
            continuation.resume(returning: .failure(.cancelled))
            return
        }
        guard gateOwner != nil else {
            gateOwner = identifier
            continuation.resume(returning: .success(()))
            return
        }
        gateWaiters.append(
            GateWaiter(identifier: identifier, continuation: continuation)
        )
    }

    private func cancelGateRequest(_ identifier: UInt64) {
        if gateOwner == identifier {
            return
        }
        if let index = gateWaiters.firstIndex(
            where: { $0.identifier == identifier }
        ) {
            let waiter = gateWaiters.remove(at: index)
            waiter.continuation.resume(returning: .failure(.cancelled))
            return
        }
        gateCancellations.insert(identifier)
    }

    private func releaseGate(_ identifier: UInt64) {
        guard gateOwner == identifier else { return }
        gateOwner = nil
        if !isShutdown {
            while !gateWaiters.isEmpty {
                let waiter = gateWaiters.removeFirst()
                if gateCancellations.remove(waiter.identifier) != nil {
                    waiter.continuation.resume(returning: .failure(.cancelled))
                    continue
                }
                gateOwner = waiter.identifier
                waiter.continuation.resume(returning: .success(()))
                break
            }
        }
        guard gateOwner == nil else { return }
        let waiters = gateIdleWaiters
        gateIdleWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if isShutdown {
            completeShutdown()
        }
    }

    private func failQueuedGateRequests(with error: DatabaseTransportError) {
        let waiters = gateWaiters
        gateWaiters.removeAll(keepingCapacity: false)
        gateCancellations.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.continuation.resume(returning: .failure(error))
        }
    }

    private func terminateForInvalidResponse(
        _ message: String
    ) async throws(DatabaseTransportError) -> ByteString {
        await terminateConnection()
        throw .invalidResponse(message)
    }

    private func terminateConnection() async {
        guard !isShutdown else { return }
        isShutdown = true
        failQueuedGateRequests(with: .cancelled)
        await connection.shutdown()
    }

    private func completeShutdown() {
        guard isShutdown, gateOwner == nil, !isShutdownComplete else { return }
        isShutdownComplete = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func lengthPrefix(for count: Int) -> ByteString {
        let length = UInt32(count)
        return ByteString([
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
        ])
    }

    private func decodeLength(
        _ bytes: ByteString
    ) throws(DatabaseTransportError) -> UInt32 {
        guard bytes.count == 4 else {
            throw .invalidResponse(
                "Framed stream response length prefix must contain four bytes"
            )
        }
        return bytes.withUnsafeBytes { buffer in
            (UInt32(buffer[0]) << 24)
                | (UInt32(buffer[1]) << 16)
                | (UInt32(buffer[2]) << 8)
                | UInt32(buffer[3])
        }
    }
}
