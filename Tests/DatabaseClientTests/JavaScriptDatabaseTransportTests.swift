#if os(WASI)
import DatabaseClient
import DatabaseClientJavaScript
import DatabaseKit
import DatabaseTypes
import DatabaseWire
import JavaScriptKit
import Testing

@Suite("JavaScript database transport", .serialized)
struct JavaScriptDatabaseTransportTests {
    @Test("Complete SQL rows and COPY traverse the JavaScript Promise boundary", .timeLimit(.minutes(1)))
    func completeSQLResponseIsOwned() async throws {
        let columns = [try QueryColumn(number: 1, name: "value", type: .sql(.text), isNullable: false)]
        let bytes = try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.sqlExecute,
            requestID: 1, response: .init(results: [
                .rows(try .init(columns: columns, rows: [QueryRow(values: [.primitive(.string("owned"))])])),
                .copy(bytes: ByteString([0, 255, 10]), affectedRows: 1),
            ]))
        JSObject.global.__databaseSQLResponse = .string("[" + bytes.map { String($0) }.joined(separator: ",") + "]")
        let transport = JavaScriptDatabaseTransport(configuration: try .init(requestEntrypointName: "__databaseExecute_sql"))
        let response = try await executeTestDatabaseOperation(client: DatabaseClient(transport: transport),
            operation: DatabaseOperationCatalog.sqlExecute, request: .init(input: .text("SELECT 1; COPY t TO STDOUT")))
        JSObject.global.__databaseSQLResponse = .undefined
        guard case .rows(let rows) = response.results[0], case .copy(let copy, _) = response.results[1] else {
            Issue.record("SQL outcomes changed across JavaScript")
            return
        }
        var iterator = rows.makeRowIterator()
        #expect(try iterator.next()?.values == [.primitive(.string("owned"))])
        #expect(copy == ByteString([0, 255, 10]))
        let captured = try #require(JSObject.global.__databaseCapturedRequest.object)
        #expect(captured["length"].number ?? 0 > 0)
    }

    @Test("Typed SQL failure metadata crosses the JavaScript Promise boundary", .timeLimit(.minutes(1)))
    func completeSQLDiagnosticIsTyped() async throws {
        let diagnostic = try SQLDiagnostic(sqlState: "42601", category: .syntax, message: "Invalid syntax", position: 4)
        let failure = try RemoteOperationError(category: .invalidRequest, code: "sql_failure", message: "Failed",
            retryability: .never, sqlDiagnostic: diagnostic)
        let bytes = try DatabaseWireEncoder().encodeFailure(requestID: 1, operation: .sqlExecute, error: failure)
        JSObject.global.__databaseSQLResponse = .string("[" + bytes.map { String($0) }.joined(separator: ",") + "]")
        let transport = JavaScriptDatabaseTransport(configuration: try .init(requestEntrypointName: "__databaseExecute_sql"))
        do {
            _ = try await executeTestDatabaseOperation(client: DatabaseClient(transport: transport),
                operation: DatabaseOperationCatalog.sqlExecute, request: .init(input: .text("bad")))
            Issue.record("SQL remote failure became success")
        } catch DatabaseClientError.call(.remote(let remote)) {
            #expect(try remote.sqlDiagnostic() == diagnostic)
        }
        JSObject.global.__databaseSQLResponse = .undefined
    }

    @Test(
        "request bytes and an offset response view preserve their exact ranges",
        .timeLimit(.minutes(1)))
    func requestAndOffsetResponseViewPreserveExactRanges() async throws {
        let entrypointName = "__databaseExecute_success"
        JSObject.global.__databaseCapturedRequest = .undefined
        let transport = JavaScriptDatabaseTransport(
            configuration: try JavaScriptDatabaseConfiguration(
                requestEntrypointName: entrypointName
            )
        )

        let response = try await transport.send([1, 2, 3])

        let capturedRequest = JSObject.global.__databaseCapturedRequest.object!
        #expect(capturedRequest["length"].number == 3)
        #expect(capturedRequest[0].number == 1)
        #expect(capturedRequest[1].number == 2)
        #expect(capturedRequest[2].number == 3)
        #expect(response == [7, 8, 9])
    }

    @Test("a rejected Promise remains a typed transport rejection", .timeLimit(.minutes(1)))
    func rejectedPromiseRemainsTyped() async throws {
        let entrypointName = "__databaseExecute_rejection"
        let transport = JavaScriptDatabaseTransport(
            configuration: try JavaScriptDatabaseConfiguration(
                requestEntrypointName: entrypointName
            )
        )

        do {
            _ = try await transport.send([1])
            Issue.record("Expected the JavaScript Promise to reject")
        } catch let error {
            guard case .rejected(let code, _) = error else {
                Issue.record("Expected a typed JavaScript rejection, received \(error)")
                return
            }
            #expect(code == "database_entrypoint_rejected")
        }
    }

    @Test(
        "a synchronous JavaScript exception remains a typed transport rejection",
        .timeLimit(.minutes(1)))
    func synchronousExceptionRemainsTyped() async throws {
        let entrypointName = "__databaseExecute_synchronous_throw"
        let transport = JavaScriptDatabaseTransport(
            configuration: try JavaScriptDatabaseConfiguration(
                requestEntrypointName: entrypointName
            )
        )

        do {
            _ = try await transport.send([1])
            Issue.record("Expected the JavaScript entrypoint to throw")
        } catch let error {
            guard case .rejected(let code, let message) = error else {
                Issue.record("Expected a typed JavaScript exception, received \(error)")
                return
            }
            #expect(code == "database_entrypoint_threw")
            #expect(message.contains("synchronous denial"))
        }
    }

    @Test("a pending Promise reaches the configured timeout", .timeLimit(.minutes(1)))
    func pendingPromiseTimesOut() async throws {
        let entrypointName = "__databaseExecute_timeout"
        let transport = JavaScriptDatabaseTransport(
            configuration: try JavaScriptDatabaseConfiguration(
                requestEntrypointName: entrypointName,
                requestTimeoutMilliseconds: 10
            )
        )

        await #expect(throws: DatabaseTransportError.timeout) {
            try await transport.send([1])
        }
    }

    @Test("a late response is not decoded after timeout", .timeLimit(.minutes(1)))
    func lateResponseIsNotDecodedAfterTimeout() async throws {
        let entrypointName = "__databaseExecute_late_response"
        JSObject.global.__databaseLateResponseDecodeProbeCount = 0
        let transport = JavaScriptDatabaseTransport(
            configuration: try JavaScriptDatabaseConfiguration(
                requestEntrypointName: entrypointName,
                requestTimeoutMilliseconds: 5
            )
        )

        await #expect(throws: DatabaseTransportError.timeout) {
            try await transport.send([1])
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(
            JSObject.global.__databaseLateResponseDecodeProbeCount.number == 0
        )
    }

    @Test("task cancellation completes a pending Promise wait once", .timeLimit(.minutes(1)))
    func cancellationCompletesPendingPromiseWait() async throws {
        let entrypointName = "__databaseExecute_cancellation"
        JSObject.global.__databaseCancellationWasInvoked = false.jsValue
        let transport = JavaScriptDatabaseTransport(
            configuration: try JavaScriptDatabaseConfiguration(
                requestEntrypointName: entrypointName
            )
        )
        let request = Task {
            try await transport.send([1])
        }
        var yieldCount = 0
        while !JSObject.global.__databaseCancellationWasInvoked.boolean!
            && yieldCount < 100
        {
            await Task.yield()
            yieldCount += 1
        }
        #expect(JSObject.global.__databaseCancellationWasInvoked.boolean!)

        request.cancel()

        await #expect(throws: DatabaseTransportError.cancelled) {
            try await request.value
        }
    }

    @Test("request limits reject bytes before invoking JavaScript", .timeLimit(.minutes(1)))
    func requestLimitPrecedesJavaScriptInvocation() async throws {
        let entrypointName = "__databaseExecute_request_limit"
        JSObject.global.__databaseRequestLimitInvocationCount = 0
        let transport = JavaScriptDatabaseTransport(
            configuration: try JavaScriptDatabaseConfiguration(
                requestEntrypointName: entrypointName,
                maximumRequestBytes: 2
            )
        )

        await #expect(
            throws: DatabaseTransportError.rejected(
                code: "request_too_large",
                message: "Database request exceeds the configured byte limit"
            )
        ) {
            try await transport.send([1, 2, 3])
        }
        #expect(
            JSObject.global.__databaseRequestLimitInvocationCount.number == 0
        )
    }

    @Test("response limits reject an oversized Uint8Array", .timeLimit(.minutes(1)))
    func responseLimitRejectsOversizedTypedArray() async throws {
        let entrypointName = "__databaseExecute_response_limit"
        let transport = JavaScriptDatabaseTransport(
            configuration: try JavaScriptDatabaseConfiguration(
                requestEntrypointName: entrypointName,
                maximumResponseBytes: 2
            )
        )

        await #expect(
            throws: DatabaseTransportError.invalidResponse(
                "Database response exceeds the configured byte limit"
            )
        ) {
            try await transport.send([1])
        }
    }

    @Test("the entrypoint must return a Promise", .timeLimit(.minutes(1)))
    func entrypointMustReturnPromise() async throws {
        let entrypointName = "__databaseExecute_not_promise"
        let transport = JavaScriptDatabaseTransport(
            configuration: try JavaScriptDatabaseConfiguration(
                requestEntrypointName: entrypointName
            )
        )

        await #expect(
            throws: DatabaseTransportError.invalidResponse(
                "Database request entrypoint did not return a Promise"
            )
        ) {
            try await transport.send([1])
        }
    }
}
#endif
