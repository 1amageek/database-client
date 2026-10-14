#if !os(WASI)
import DatabaseClient
import DatabaseKit
@testable import DatabaseClientWebSocket
import DatabaseTypes
import DatabaseWire
import Foundation
import Testing

@Suite("DatabaseWire WebSocket transport")
struct WebSocketDatabaseTransportTests {
    @Test("request and response traverse the injected connection")
    func requestAndResponseTraverseConnection() async throws {
        let call = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 41,
            request: EmptyOperationPayload()
        )
        let requestBytes = try call.encode()
        let responseBytes = try successResponse(requestID: 41)
        let responseData = Data(responseBytes)
        let connection = ScriptedDatabaseWebSocketConnection(
            messages: [.data(responseData)]
        )
        let connector = CapturingDatabaseWebSocketConnector(
            connection: connection
        )
        let transport = WebSocketDatabaseTransport(
            configuration: try configuration(),
            connector: connector
        )

        let response = try await transport.send(requestBytes)
        let request = try #require(connector.capturedRequest)
        let frames = await connection.frames()

        #expect(frames == [Data(requestBytes)])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(request.value(forHTTPHeaderField: "x-database-id") == "calendar")
        #expect(request.value(forHTTPHeaderField: "x-tenant-id") == "tenant-a")
        #expect(request.value(forHTTPHeaderField: "x-workspace-id") == "production")
        #expect(try call.decodeResponse(response).runtimeVersion == "v1")
        #expect(try address(of: response) != address(of: responseData))
        #expect(try #require(response.retainedByteCount) >= response.count)
        #expect(response.isStorageSelfContained)
        await transport.shutdown()
    }

    @Test("sliced WebSocket query frames decode with bounded retention after shutdown")
    func typedQueryResponseHasBoundedOwnership() async throws {
        let page = try makeTestQueryResponsePage()
        let call = makeTestDatabaseCall(operation: DatabaseOperationCatalog.queryExecute,
                                        requestID: 82,
                                        request: QueryExecuteOperation.Request(input: .text(language: .sql, statement: "SELECT 1")))
        let encoded = try DatabaseWireEncoder().encodeResponse(
            DatabaseOperationCatalog.queryExecute, requestID: 82, response: .rows(page)
        )
        var enclosing = Data(repeating: 0xa5, count: 4096)
        enclosing.append(contentsOf: encoded)
        enclosing.append(contentsOf: [UInt8](repeating: 0xa5, count: 4096))
        let slicedFrame = enclosing[4096..<(4096 + encoded.count)]
        let connection = ScriptedDatabaseWebSocketConnection(messages: [.data(slicedFrame)])
        let transport = WebSocketDatabaseTransport(configuration: try configuration(),
                                                    connector: CapturingDatabaseWebSocketConnector(connection: connection))
        let received = try await transport.send(call.encode())
        await transport.shutdown()
        #expect(received == encoded)
        #expect(try #require(received.retainedByteCount) >= received.count)
        #expect(received.isStorageSelfContained)
        #expect(try address(of: received) != address(of: slicedFrame))
        guard case .rows(let decoded) = try call.decodeResponse(received) else {
            Issue.record("Expected a typed query row page")
            return
        }
        #expect(decoded.columns == page.columns)
        var iterator = decoded.makeRowIterator()
        let next = try iterator.next()
        let row = try #require(next)
        #expect(row.values == (try page.materializedRows(maximumCount: 1))[0].values)
        #expect(try iterator.next() == nil)
    }

    @Test("oversized request is rejected before creating a connection")
    func oversizedRequestIsRejectedBeforeConnectionCreation() async throws {
        let connection = ScriptedDatabaseWebSocketConnection(messages: [])
        let connector = CapturingDatabaseWebSocketConnector(
            connection: connection
        )
        let transport = WebSocketDatabaseTransport(
            configuration: try configuration(maximumRequestBytes: 2),
            connector: connector
        )

        await #expect(
            throws: DatabaseTransportError.rejected(
                code: "request_too_large",
                message: "Database request exceeds the configured byte limit"
            )
        ) {
            try await transport.send([1, 2, 3])
        }
        #expect(connector.capturedRequest == nil)
        await transport.shutdown()
    }

    @Test("invalid request header is rejected before creating a connection")
    func invalidRequestHeaderIsRejectedBeforeConnectionCreation() async throws {
        let connection = ScriptedDatabaseWebSocketConnection(messages: [])
        let connector = CapturingDatabaseWebSocketConnector(
            connection: connection
        )
        let transport = WebSocketDatabaseTransport(
            configuration: try configuration(),
            connector: connector
        )

        await #expect(
            throws: DatabaseTransportError.invalidRequest(
                "WebSocket request has an invalid DatabaseWire header"
            )
        ) {
            try await transport.send([1, 2, 3])
        }
        #expect(connector.capturedRequest == nil)
        await transport.shutdown()
    }

    @Test("routing does not decode request payloads with unrelated default limits")
    func routingDoesNotDecodeRequestPayload() async throws {
        let payloadByteCount = DatabaseWireLimits.default.maximumFrameBytes
        let limits = try largeFrameLimits(payloadByteCount: payloadByteCount)
        let requestBytes = try makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.queryExecute,
            requestID: 47,
            request: QueryExecuteOperation.Request(
                input: .text(
                    language: .sql,
                    statement: String(
                        repeating: "a",
                        count: payloadByteCount
                    )
                )
            )
        ).encode(limits: limits)
        let connection = ScriptedDatabaseWebSocketConnection(
            messages: [
                .data(Data(try successResponse(requestID: 47))),
            ]
        )
        let transport = WebSocketDatabaseTransport(
            configuration: try configuration(
                maximumRequestBytes: requestBytes.count
            ),
            connector: CapturingDatabaseWebSocketConnector(
                connection: connection
            )
        )

        _ = try await transport.send(requestBytes)

        let frames = await connection.frames()
        #expect(frames.count == 1)
        #expect(frames[0].count == requestBytes.count)
        await transport.shutdown()
    }

    @Test("routing returns response payloads for the typed call to decode once")
    func routingDoesNotDecodeResponsePayload() async throws {
        let payloadByteCount = DatabaseWireLimits.default.maximumFrameBytes
        let limits = try largeFrameLimits(payloadByteCount: payloadByteCount)
        let responseBytes = try DatabaseWireEncoder(
            limits: limits
        ).encodeResponse(
            DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 48,
            response: CapabilitiesDescribeOperation.Response(
                runtimeVersion: "1",
                features: [
                    .init(
                        identifier: String(
                            repeating: "f",
                            count: payloadByteCount
                        ),
                        version: 1
                    ),
                ],
                jobOperations: []
            )
        )
        let responseData = Data(responseBytes)
        let connection = ScriptedDatabaseWebSocketConnection(
            messages: [.data(responseData)]
        )
        let transport = WebSocketDatabaseTransport(
            configuration: try configuration(
                maximumResponseBytes: responseBytes.count
            ),
            connector: CapturingDatabaseWebSocketConnector(
                connection: connection
            )
        )
        let call = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 48,
            request: EmptyOperationPayload()
        )

        let received = try await transport.send(call.encode())

        #expect(received.count == responseBytes.count)
        #expect(try address(of: received) != address(of: responseData))
        #expect(try #require(received.retainedByteCount) >= received.count)
        #expect(received.isStorageSelfContained)
        await transport.shutdown()
    }

    @Test("oversized response fails every pending request")
    func oversizedResponseIsRejected() async throws {
        let call = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 42,
            request: EmptyOperationPayload()
        )
        let response = Data(try successResponse(requestID: 42))
        let connection = ScriptedDatabaseWebSocketConnection(
            messages: [.data(response)]
        )
        let transport = WebSocketDatabaseTransport(
            configuration: try configuration(maximumResponseBytes: 2),
            connector: CapturingDatabaseWebSocketConnector(
                connection: connection
            )
        )

        await #expect(
            throws: DatabaseTransportError.invalidResponse(
                "WebSocket response exceeds the configured byte limit"
            )
        ) {
            try await transport.send(call.encode())
        }
        await transport.shutdown()
    }

    @Test("text response is rejected")
    func textResponseIsRejected() async throws {
        let call = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 43,
            request: EmptyOperationPayload()
        )
        let connection = ScriptedDatabaseWebSocketConnection(
            messages: [.string("invalid")]
        )
        let transport = WebSocketDatabaseTransport(
            configuration: try configuration(),
            connector: CapturingDatabaseWebSocketConnector(
                connection: connection
            )
        )

        await #expect(
            throws: DatabaseTransportError.invalidResponse(
                "WebSocket database transport accepts binary frames only"
            )
        ) {
            try await transport.send(call.encode())
        }
        await transport.shutdown()
    }

    @Test("configuration rejects invalid resource limits")
    func configurationRejectsInvalidResourceLimits() throws {
        #expect(throws: WebSocketDatabaseConfigurationError.invalidMaximumRequestBytes) {
            _ = try configuration(maximumRequestBytes: 0)
        }
        #expect(throws: WebSocketDatabaseConfigurationError.invalidMaximumResponseBytes) {
            _ = try configuration(maximumResponseBytes: 0)
        }
        #expect(
            throws: WebSocketDatabaseConfigurationError
                .invalidMaximumRetiredRequestIDsPerConnection
        ) {
            _ = try configuration(maximumRetiredRequestIDsPerConnection: 0)
        }
    }

    @Test("response wait is bounded by the configured request timeout")
    func responseWaitTimesOut() async throws {
        let call = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 44,
            request: EmptyOperationPayload()
        )
        let connection = ScriptedDatabaseWebSocketConnection(
            messages: [],
            waitsWhenEmpty: true
        )
        let transport = WebSocketDatabaseTransport(
            configuration: try configuration(requestTimeout: 0.02),
            connector: CapturingDatabaseWebSocketConnector(
                connection: connection
            )
        )

        await #expect(throws: DatabaseTransportError.timeout) {
            try await transport.send(call.encode())
        }
        await transport.shutdown()
    }

    @Test("transport rejects requests after explicit shutdown")
    func transportRejectsRequestsAfterShutdown() async throws {
        let call = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 53,
            request: EmptyOperationPayload()
        )
        let connection = ScriptedDatabaseWebSocketConnection(messages: [])
        let connector = CapturingDatabaseWebSocketConnector(
            connection: connection
        )
        let transport = WebSocketDatabaseTransport(
            configuration: try configuration(),
            connector: connector
        )

        await transport.shutdown()

        await #expect(
            throws: DatabaseTransportError.unavailable(
                "WebSocket database transport is shut down"
            )
        ) {
            try await transport.send(call.encode())
        }
        #expect(connector.capturedRequest == nil)
        await transport.shutdown()
    }

    @Test("shutdown cancels a pending request exactly once")
    func shutdownCancelsPendingRequest() async throws {
        let call = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 54,
            request: EmptyOperationPayload()
        )
        let connection = ScriptedDatabaseWebSocketConnection(
            messages: [],
            waitsWhenEmpty: true
        )
        let transport = WebSocketDatabaseTransport(
            configuration: try configuration(),
            connector: CapturingDatabaseWebSocketConnector(
                connection: connection
            )
        )
        let pendingRequest = Task {
            try await transport.send(call.encode())
        }
        await connection.waitForFrameCount(1)

        await transport.shutdown()

        await #expect(throws: DatabaseTransportError.cancelled) {
            try await pendingRequest.value
        }
        #expect(await connection.cancellationWasRequested())
    }

    @Test("shutdown cancels an in-flight frame transmission")
    func shutdownCancelsInFlightFrameTransmission() async throws {
        let call = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 55,
            request: EmptyOperationPayload()
        )
        let connection = ScriptedDatabaseWebSocketConnection(
            messages: [],
            waitsWhenEmpty: true,
            waitsDuringSend: true
        )
        let transport = WebSocketDatabaseTransport(
            configuration: try configuration(),
            connector: CapturingDatabaseWebSocketConnector(
                connection: connection
            )
        )
        let pendingRequest = Task {
            try await transport.send(call.encode())
        }
        await connection.waitForSendStart()

        await transport.shutdown()

        await #expect(throws: DatabaseTransportError.cancelled) {
            try await pendingRequest.value
        }
        #expect(await connection.frames().isEmpty)
        #expect(await connection.cancellationWasRequested())
        #expect(await connection.childOperationsDidFinish())
    }

    @Test("concurrent shutdown callers wait for the same completed boundary")
    func concurrentShutdownCallersWaitForCompletion() async throws {
        let call = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 56,
            request: EmptyOperationPayload()
        )
        let connection = ScriptedDatabaseWebSocketConnection(
            messages: [],
            waitsWhenEmpty: true,
            waitsDuringSend: true
        )
        let transport = WebSocketDatabaseTransport(
            configuration: try configuration(),
            connector: CapturingDatabaseWebSocketConnector(
                connection: connection
            )
        )
        let pendingRequest = Task {
            try await transport.send(call.encode())
        }
        await connection.waitForSendStart()

        async let firstShutdown: Void = transport.shutdown()
        async let secondShutdown: Void = transport.shutdown()
        _ = await (firstShutdown, secondShutdown)

        await #expect(throws: DatabaseTransportError.cancelled) {
            try await pendingRequest.value
        }
        #expect(await connection.childOperationsDidFinish())
    }

    @Test("a late cancelled response cannot fail another pending request")
    func lateCancelledResponseIsIsolated() async throws {
        let firstCall = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 45,
            request: EmptyOperationPayload()
        )
        let secondCall = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 46,
            request: EmptyOperationPayload()
        )
        let connection = ScriptedDatabaseWebSocketConnection(
            messages: [],
            waitsWhenEmpty: true
        )
        let transport = WebSocketDatabaseTransport(
            configuration: try configuration(requestTimeout: 1),
            connector: CapturingDatabaseWebSocketConnector(
                connection: connection
            )
        )

        let cancelledRequest = Task {
            try await transport.send(firstCall.encode())
        }
        await connection.waitForFrameCount(1)
        cancelledRequest.cancel()
        await #expect(throws: DatabaseTransportError.cancelled) {
            try await cancelledRequest.value
        }

        await connection.append(
            .data(Data(try successResponse(requestID: 45)))
        )
        let activeRequest = Task {
            try await transport.send(secondCall.encode())
        }
        await connection.waitForFrameCount(2)
        await connection.append(
            .data(Data(try successResponse(requestID: 46)))
        )

        let response = try await activeRequest.value
        #expect(try secondCall.decodeResponse(response).runtimeVersion == "v1")
        await transport.shutdown()
    }

    @Test("a late response is retired before cancellation joins the send task")
    func lateResponseIsRetiredBeforeJoiningSendTask() async throws {
        let cancelledCall = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 57,
            request: EmptyOperationPayload()
        )
        let activeCall = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 58,
            request: EmptyOperationPayload()
        )
        let connection = ScriptedDatabaseWebSocketConnection(
            messages: [],
            waitsWhenEmpty: true,
            waitsAfterFirstSend: true,
            releasesBlockedSendOnCancellation: false
        )
        let transport = WebSocketDatabaseTransport(
            configuration: try configuration(requestTimeout: 1),
            connector: CapturingDatabaseWebSocketConnector(
                connection: connection
            )
        )

        let cancelledRequest = Task {
            try await transport.send(cancelledCall.encode())
        }
        await connection.waitForSendStart()
        cancelledRequest.cancel()
        await connection.waitForSendCancellation()

        let activeRequest = Task {
            try await transport.send(activeCall.encode())
        }
        await connection.waitForFrameCount(2)
        await connection.append(
            .data(Data(try successResponse(requestID: 57)))
        )
        await connection.append(
            .data(Data(try successResponse(requestID: 58)))
        )

        let response = try await activeRequest.value
        #expect(try activeCall.decodeResponse(response).runtimeVersion == "v1")
        await connection.releaseBlockedSend()
        await #expect(throws: DatabaseTransportError.cancelled) {
            try await cancelledRequest.value
        }
        #expect(!(await connection.cancellationWasRequested()))
        await transport.shutdown()
    }

    @Test("a cancelled request ID cannot be reused before its late response")
    func cancelledRequestIDCannotBeReused() async throws {
        let call = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 49,
            request: EmptyOperationPayload()
        )
        let connection = ScriptedDatabaseWebSocketConnection(
            messages: [],
            waitsWhenEmpty: true
        )
        let transport = WebSocketDatabaseTransport(
            configuration: try configuration(requestTimeout: 1),
            connector: CapturingDatabaseWebSocketConnector(
                connection: connection
            )
        )
        let firstRequest = Task {
            try await transport.send(call.encode())
        }
        await connection.waitForFrameCount(1)
        firstRequest.cancel()
        await #expect(throws: DatabaseTransportError.cancelled) {
            try await firstRequest.value
        }

        await #expect(
            throws: DatabaseTransportError.rejected(
                code: "request_id_retired",
                message: "A request with this ID may still receive a late response"
            )
        ) {
            try await transport.send(call.encode())
        }
        #expect(await connection.frames().count == 1)
        await transport.shutdown()
    }

    @Test("late-response history never evicts an identifier silently")
    func lateResponseHistoryRejectsOverflow() {
        var identifiers = RetiredDatabaseRequestIDs(capacity: 2)

        let insertedFirst = identifiers.insert(1)
        let insertedSecond = identifiers.insert(2)
        let insertedOverflow = identifiers.insert(3)

        #expect(insertedFirst)
        #expect(insertedSecond)
        #expect(!insertedOverflow)
        #expect(identifiers.contains(1))
        #expect(identifiers.contains(2))
        #expect(!identifiers.contains(3))
    }

    @Test("late-response history overflow rotates the connection generation")
    func lateResponseHistoryOverflowRotatesConnection() async throws {
        let firstConnection = ScriptedDatabaseWebSocketConnection(
            messages: [],
            waitsWhenEmpty: true
        )
        let secondConnection = ScriptedDatabaseWebSocketConnection(
            messages: [
                .data(Data(try successResponse(requestID: 50))),
            ]
        )
        let connector = SequencedDatabaseWebSocketConnector(
            connections: [firstConnection, secondConnection]
        )
        let transport = WebSocketDatabaseTransport(
            configuration: try configuration(
                requestTimeout: 1,
                maximumRetiredRequestIDsPerConnection: 1
            ),
            connector: connector
        )

        let firstCall = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 50,
            request: EmptyOperationPayload()
        )
        let firstRequest = Task {
            try await transport.send(firstCall.encode())
        }
        await firstConnection.waitForFrameCount(1)
        firstRequest.cancel()
        await #expect(throws: DatabaseTransportError.cancelled) {
            try await firstRequest.value
        }

        let secondCall = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 51,
            request: EmptyOperationPayload()
        )
        let secondRequest = Task {
            try await transport.send(secondCall.encode())
        }
        await firstConnection.waitForFrameCount(2)
        secondRequest.cancel()
        await #expect(throws: DatabaseTransportError.cancelled) {
            try await secondRequest.value
        }

        let response = try await transport.send(firstCall.encode())

        #expect(connector.connectionCount == 2)
        #expect(await firstConnection.frames().count == 2)
        #expect(await secondConnection.frames().count == 1)
        #expect(try firstCall.decodeResponse(response).runtimeVersion == "v1")
        await transport.shutdown()
    }

    @Test("request identity includes its connection generation")
    func requestIdentityIncludesConnectionGeneration() {
        let first = DatabaseRequestKey(connectionID: 1, requestID: 52)
        let second = DatabaseRequestKey(connectionID: 2, requestID: 52)

        #expect(first != second)
    }

    private func configuration(
        requestTimeout: TimeInterval = 30,
        maximumRequestBytes: Int = DatabaseWireLimits.default.maximumFrameBytes,
        maximumResponseBytes: Int = DatabaseWireLimits.default.maximumFrameBytes,
        maximumRetiredRequestIDsPerConnection: Int = 1_024
    ) throws -> WebSocketDatabaseConfiguration {
        guard let endpoint = URL(
            string: "wss://database.example.test"
        ) else {
            preconditionFailure("Static WebSocket test URL is invalid")
        }
        return try WebSocketDatabaseConfiguration(
            endpoint: endpoint,
            accessToken: "token",
            databaseID: "calendar",
            tenantID: "tenant-a",
            workspaceID: "production",
            requestTimeout: requestTimeout,
            maximumRequestBytes: maximumRequestBytes,
            maximumResponseBytes: maximumResponseBytes,
            maximumRetiredRequestIDsPerConnection:
                maximumRetiredRequestIDsPerConnection
        )
    }

    private func successResponse(
        requestID: UInt64
    ) throws -> ByteString {
        return try DatabaseWireEncoder().encodeResponse(
            DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: requestID,
            response: CapabilitiesDescribeOperation.Response(
                runtimeVersion: "v1",
                features: [
                    CapabilitiesDescribeOperation.Feature(
                        identifier: String(repeating: "f", count: 256),
                        version: 1
                    )
                ],
                jobOperations: []
            )
        )
    }

    private func largeFrameLimits(
        payloadByteCount: Int
    ) throws -> DatabaseWireLimits {
        try DatabaseWireLimits(
            maximumFrameBytes: payloadByteCount + 1_024,
            maximumStringBytes: payloadByteCount,
            maximumByteStringBytes: payloadByteCount + 1_024,
            maximumCollectionCount: 1_024,
            maximumNestingDepth: 64,
            maximumObjectCount: 1_024
        )
    }

    private func address(of bytes: ByteString) throws -> UInt {
        try #require(bytes.withUnsafeBytes { buffer in
            buffer.baseAddress.map { UInt(bitPattern: $0) }
        })
    }

    private func address(of data: Data) throws -> UInt {
        try #require(data.withUnsafeBytes { buffer in
            buffer.baseAddress.map { UInt(bitPattern: $0) }
        })
    }
}
#endif
