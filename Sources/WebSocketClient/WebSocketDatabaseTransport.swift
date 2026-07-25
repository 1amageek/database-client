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
                registerPendingRequest(
                    requestKey: requestKey,
                    continuation: continuation
                )
                Task {
                    await self.sendFrame(
                        request,
                        requestKey: requestKey,
                        over: activeConnection.connection
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(requestKey) }
        }
        return try result.get()
    }

    public func shutdown() async {
        responseReception?.cancel()
        responseReception = nil
        let activeConnection = connection
        connection = nil
        failAllPending(with: DatabaseTransportError.cancelled)
        retiredRequestIDs.removeAll()
        if let activeConnection {
            await activeConnection.connection.cancel()
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
            retainCompletion: true
        )
    }

    private func timeoutRequest(_ requestKey: DatabaseRequestKey) async {
        await failRequest(
            requestKey,
            with: DatabaseTransportError.timeout,
            retainCompletion: true
        )
    }

    private func registerPendingRequest(
        requestKey: DatabaseRequestKey,
        continuation: CheckedContinuation<
            Result<ByteString, DatabaseTransportError>,
            Never
        >
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
            timeoutTask: timeoutTask
        )
    }

    private func failRequest(
        _ requestKey: DatabaseRequestKey,
        with error: DatabaseTransportError,
        retainCompletion: Bool = false
    ) async {
        guard let request = pending.removeValue(forKey: requestKey) else {
            return
        }
        request.timeoutTask.cancel()
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
                return
            }
        }
        request.continuation.resume(returning: .failure(error))
    }

    private func failAllPending(with error: DatabaseTransportError) {
        let requests = pending.values
        pending.removeAll(keepingCapacity: true)
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(returning: .failure(error))
        }
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
        failAllPending(with: error)
        retiredRequestIDs.removeAll()
        await activeConnection.connection.cancel()
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
    }
}
#endif
