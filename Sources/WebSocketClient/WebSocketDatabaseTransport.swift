#if !os(WASI)
import DatabaseClient
import DatabaseTypes
import DatabaseWire
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor WebSocketDatabaseTransport: DatabaseTransport {
    private let configuration: WebSocketDatabaseConfiguration
    private let connector: any DatabaseWebSocketConnector
    private var connection: ActiveConnection?
    private var responseReception: Task<Void, Never>?
    private var nextConnectionID: UInt64 = 1
    private var pending: [DatabaseRequestKey: PendingRequest] = [:]
    private var retiredRequestIDs: RetiredDatabaseRequestIDs
    private var isShutdown = false
    private var isShutdownComplete = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        configuration: WebSocketDatabaseConfiguration,
        connector: any DatabaseWebSocketConnector =
            URLSessionDatabaseWebSocketConnector()
    ) {
        self.configuration = configuration
        self.connector = connector
        self.retiredRequestIDs = RetiredDatabaseRequestIDs(
            capacity: configuration.maximumRetiredRequestIDsPerConnection
        )
    }

    public func send(
        _ request: ByteString
    ) async throws(DatabaseTransportError) -> ByteString {
        guard !isShutdown else {
            throw .unavailable("WebSocket database transport is shut down")
        }
        guard request.count <= configuration.maximumRequestBytes else {
            throw .rejected(
                code: "request_too_large",
                message: "Database request exceeds the configured byte limit"
            )
        }
        let requestHeader: DatabaseWireEnvelopeHeader
        do {
            requestHeader = try DatabaseWireDecoder()
                .decodeRequestHeader(request)
        } catch {
            throw .invalidRequest(
                "WebSocket request has an invalid DatabaseWire header"
            )
        }
        let activeConnection = try ensureConnection()
        let requestKey = DatabaseRequestKey(
            connectionID: activeConnection.id,
            requestID: requestHeader.requestID
        )
        guard pending[requestKey] == nil else {
            throw .rejected(code: "duplicate_request_id", message: "A request with this ID is already pending")
        }
        guard !retiredRequestIDs.contains(requestKey.requestID) else {
            throw .rejected(
                code: "request_id_retired",
                message: "A request with this ID may still receive a late response"
            )
        }

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let frameTransmission = Task {
                    await self.sendFrame(
                        request,
                        requestKey: requestKey,
                        over: activeConnection.connection
                    )
                }
                registerPendingRequest(
                    requestKey: requestKey,
                    continuation: continuation,
                    frameTransmission: frameTransmission
                )
            }
        } onCancel: {
            Task { await self.cancelRequest(requestKey) }
        }
        return try result.get()
    }

    public func shutdown() async {
        if isShutdown {
            guard !isShutdownComplete else {
                return
            }
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
            return
        }
        isShutdown = true
        let reception = responseReception
        responseReception = nil
        reception?.cancel()
        let activeConnection = connection
        connection = nil
        let childTasks = cancelAllPending(
            with: DatabaseTransportError.cancelled
        )
        retiredRequestIDs.removeAll()
        if let activeConnection {
            await activeConnection.connection.cancel()
        }
        for task in childTasks {
            await task.value
        }
        if let reception {
            await reception.value
        }
        isShutdownComplete = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func ensureConnection() throws(DatabaseTransportError)
        -> ActiveConnection {
        if let connection {
            return connection
        }
        guard nextConnectionID != 0 else {
            throw .unavailable(
                "WebSocket connection identifier space is exhausted"
            )
        }
        var request = URLRequest(
            url: configuration.endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: configuration.requestTimeout
        )
        request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.databaseID, forHTTPHeaderField: "x-database-id")
        if let tenantID = configuration.tenantID {
            request.setValue(tenantID, forHTTPHeaderField: "x-tenant-id")
        }
        if let workspaceID = configuration.workspaceID {
            request.setValue(workspaceID, forHTTPHeaderField: "x-workspace-id")
        }
        let connectionID = nextConnectionID
        nextConnectionID = connectionID == UInt64.max
            ? 0
            : connectionID + 1
        let databaseConnection = connector.connect(for: request)
        let activeConnection = ActiveConnection(
            id: connectionID,
            connection: databaseConnection
        )
        connection = activeConnection
        responseReception = Task {
            await self.receiveFrames(from: activeConnection)
        }
        return activeConnection
    }

    private func sendFrame(
        _ bytes: ByteString,
        requestKey: DatabaseRequestKey,
        over connection: any DatabaseWebSocketConnection
    ) async {
        guard !Task.isCancelled,
            !isShutdown,
            self.connection?.id == requestKey.connectionID,
            pending[requestKey] != nil
        else {
            return
        }
        do {
            // URLSessionWebSocketTask owns Data beyond the synchronous borrow.
            // This is the single ownership copy at the Foundation send boundary.
            let data = bytes.withUnsafeBytes { Data($0) }
            try await connection.send(data)
        } catch {
            await failRequest(
                requestKey,
                with: DatabaseTransportError.unavailable(String(describing: error)),
                retainCompletion: true
            )
        }
    }

    private func receiveFrames(from activeConnection: ActiveConnection) async {
        do {
            while !Task.isCancelled {
                let message = try await activeConnection.connection.receive()
                guard connection?.id == activeConnection.id else {
                    return
                }
                let bytes: ByteString
                switch message {
                case .data(let data):
                    guard data.count <= configuration.maximumResponseBytes else {
                        throw DatabaseTransportError.invalidResponse(
                            "WebSocket response exceeds the configured byte limit"
                        )
                    }
                    bytes = ByteString(
                        retaining: ReceivedWebSocketFrameByteOwner(data: data)
                    )
                case .string:
                    throw DatabaseTransportError.invalidResponse(
                        "WebSocket database transport accepts binary frames only"
                    )
                }

                let responseHeader: DatabaseWireEnvelopeHeader
                do {
                    responseHeader = try DatabaseWireDecoder()
                        .decodeResponseHeader(bytes)
                } catch {
                    throw DatabaseTransportError.invalidResponse(
                        "WebSocket response has an invalid DatabaseWire header"
                    )
                }
                let requestKey = DatabaseRequestKey(
                    connectionID: activeConnection.id,
                    requestID: responseHeader.requestID
                )
                guard let request = pending.removeValue(forKey: requestKey) else {
                    if retiredRequestIDs.contains(responseHeader.requestID) {
                        continue
                    }
                    throw DatabaseTransportError.invalidResponse(
                        "WebSocket response has no matching request"
                    )
                }
                request.timeoutTask.cancel()
                request.frameTransmission.cancel()
                await request.frameTransmission.value
                await request.timeoutTask.value
                request.continuation.resume(returning: .success(bytes))
            }
        } catch is CancellationError {
            await closeConnection(activeConnection, error: .cancelled)
        } catch let error as DatabaseTransportError {
            await closeConnection(activeConnection, error: error)
        } catch {
            await closeConnection(
                activeConnection,
                error: .unavailable(String(describing: error))
            )
        }
    }

    private func cancelRequest(_ requestKey: DatabaseRequestKey) async {
        await failRequest(
            requestKey,
            with: DatabaseTransportError.cancelled,
            retainCompletion: true,
            waitsForFrameTransmission: true
        )
    }

    private func timeoutRequest(_ requestKey: DatabaseRequestKey) async {
        await failRequest(
            requestKey,
            with: DatabaseTransportError.timeout,
            retainCompletion: true,
            waitsForFrameTransmission: true
        )
    }

    private func registerPendingRequest(
        requestKey: DatabaseRequestKey,
        continuation: CheckedContinuation<
            Result<ByteString, DatabaseTransportError>,
            Never
        >,
        frameTransmission: Task<Void, Never>
    ) {
        let requestTimeout = configuration.requestTimeout
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: .seconds(requestTimeout))
            } catch {
                return
            }
            await self.timeoutRequest(requestKey)
        }
        pending[requestKey] = PendingRequest(
            continuation: continuation,
            timeoutTask: timeoutTask,
            frameTransmission: frameTransmission
        )
    }

    private func failRequest(
        _ requestKey: DatabaseRequestKey,
        with error: DatabaseTransportError,
        retainCompletion: Bool = false,
        waitsForFrameTransmission: Bool = false
    ) async {
        guard let request = pending.removeValue(forKey: requestKey) else {
            return
        }
        request.timeoutTask.cancel()
        request.frameTransmission.cancel()
        if retainCompletion,
           let activeConnection = connection,
           activeConnection.id == requestKey.connectionID {
            let retained = retiredRequestIDs.insert(requestKey.requestID)
            if !retained {
                request.continuation.resume(returning: .failure(error))
                await closeConnection(
                    activeConnection,
                    error: .rejected(
                        code: "request_history_exhausted",
                        message: "The active connection exhausted its late-response history"
                    )
                )
                if waitsForFrameTransmission {
                    await request.frameTransmission.value
                }
                return
            }
        }
        if waitsForFrameTransmission {
            await request.frameTransmission.value
        }
        request.continuation.resume(returning: .failure(error))
    }

    private func cancelAllPending(
        with error: DatabaseTransportError
    ) -> [Task<Void, Never>] {
        let requests = pending.values
        pending.removeAll(keepingCapacity: true)
        var childTasks: [Task<Void, Never>] = []
        childTasks.reserveCapacity(requests.count * 2)
        for request in requests {
            request.timeoutTask.cancel()
            request.frameTransmission.cancel()
            childTasks.append(request.timeoutTask)
            childTasks.append(request.frameTransmission)
            request.continuation.resume(returning: .failure(error))
        }
        return childTasks
    }

    private func closeConnection(
        _ activeConnection: ActiveConnection,
        error: DatabaseTransportError
    ) async {
        guard connection?.id == activeConnection.id else {
            return
        }
        responseReception?.cancel()
        responseReception = nil
        connection = nil
        let childTasks = cancelAllPending(with: error)
        retiredRequestIDs.removeAll()
        await activeConnection.connection.cancel()
        for task in childTasks {
            await task.value
        }
    }

    private struct ActiveConnection: Sendable {
        let id: UInt64
        let connection: any DatabaseWebSocketConnection
    }

    private struct PendingRequest: Sendable {
        let continuation: CheckedContinuation<
            Result<ByteString, DatabaseTransportError>,
            Never
        >
        let timeoutTask: Task<Void, Never>
        let frameTransmission: Task<Void, Never>
    }
}
#endif
