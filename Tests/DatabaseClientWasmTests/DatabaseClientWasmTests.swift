import Testing
import DatabaseKitWasmCore
@testable import DatabaseClientWasm

@Suite("DatabaseClientWasm Tests")
struct DatabaseClientWasmTests {
    @Test func putRecordSendsBinaryRequestAndAcceptsEmptyResponse() throws {
        let expected = DatabaseKitWasmRecord(
            typeName: "Article",
            id: "article-1",
            fields: [
                DatabaseKitWasmNamedValue(name: "title", value: .string("Hello"))
            ]
        )
        let transport = FakeWasmTransport { request in
            #expect(request == .putRecord(expected))
            return .empty
        }
        let client = DatabaseClientWasm(transport: transport)

        try client.putRecord(expected)
    }

    @Test func getRecordDecodesOptionalRecordResponse() throws {
        let expected = DatabaseKitWasmRecord(
            typeName: "Article",
            id: "article-1",
            fields: [
                DatabaseKitWasmNamedValue(name: "title", value: .string("Hello"))
            ]
        )
        let transport = FakeWasmTransport { request in
            #expect(request == .getRecord(typeName: "Article", id: "article-1"))
            return .record(expected)
        }
        let client = DatabaseClientWasm(transport: transport)

        let record = try client.getRecord(typeName: "Article", id: "article-1")

        #expect(record == expected)
    }

    @Test func queryReturnsRecordList() throws {
        let first = DatabaseKitWasmRecord(typeName: "Article", id: "a", fields: [])
        let second = DatabaseKitWasmRecord(typeName: "Article", id: "b", fields: [])
        let query = DatabaseKitWasmQueryRequest(
            typeName: "Article",
            predicate: .comparison(field: "status", op: .equal, value: .string("published")),
            limit: 10
        )
        let transport = FakeWasmTransport { request in
            #expect(request == .query(query))
            return .records([first, second])
        }
        let client = DatabaseClientWasm(transport: transport)

        let records = try client.query(query)

        #expect(records == [first, second])
    }

    @Test func remoteFailureThrowsTypedClientError() {
        let transport = FakeWasmTransport { _ in
            .failure(status: .executionFailure, message: "storage unavailable")
        }
        let client = DatabaseClientWasm(transport: transport)

        let operation: () throws(DatabaseClientWasmError) -> Void = {
            _ = try client.getRecord(typeName: "Article", id: "article-1")
        }
        let error = captureError(operation)

        #expect(error == DatabaseClientWasmError.remoteFailure(
            status: .executionFailure,
            message: "storage unavailable"
        ))
    }

    @Test func unexpectedPayloadThrowsTypedClientError() {
        let transport = FakeWasmTransport { _ in
            .records([])
        }
        let client = DatabaseClientWasm(transport: transport)

        let operation: () throws(DatabaseClientWasmError) -> Void = {
            _ = try client.getRecord(typeName: "Article", id: "article-1")
        }
        let error = captureError(operation)

        #expect(error == DatabaseClientWasmError.unexpectedResponse(.records([])))
    }

    private func captureError(
        _ operation: () throws(DatabaseClientWasmError) -> Void
    ) -> DatabaseClientWasmError? {
        do {
            try operation()
            return nil
        } catch {
            return error
        }
    }
}

private struct FakeWasmTransport: DatabaseClientWasmTransport {
    private let handler: @Sendable (DatabaseKitWasmRequest) -> DatabaseKitWasmResponse

    init(
        _ handler: @escaping @Sendable (DatabaseKitWasmRequest) -> DatabaseKitWasmResponse
    ) {
        self.handler = handler
    }

    func send(_ request: [UInt8]) throws(DatabaseClientWasmError) -> [UInt8] {
        let decodedRequest: DatabaseKitWasmRequest
        do {
            decodedRequest = try DatabaseKitWasmCodec.decodeRequest(request)
        } catch {
            throw .wire(error)
        }
        let response = handler(decodedRequest)
        do {
            return try DatabaseKitWasmCodec.encode(response: response)
        } catch {
            throw .wire(error)
        }
    }
}
