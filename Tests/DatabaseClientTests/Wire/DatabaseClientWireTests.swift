import Testing
import DatabaseKitWasmCore
@testable import DatabaseClient

@Suite("DatabaseClient Tests")
struct DatabaseClientWireTests {
    @Test func putRecordSendsBinaryRequestAndAcceptsEmptyResponse() throws {
        let expected = DatabaseKitWasmRecord(
            typeName: "Article",
            id: "article-1",
            fields: [
                DatabaseKitWasmNamedValue(name: "title", value: .string("Hello"))
            ]
        )
        let transport = FakeDatabaseTransport { request in
            #expect(request == .putRecord(expected))
            return .empty
        }
        let client = DatabaseClient(transport: transport)

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
        let transport = FakeDatabaseTransport { request in
            #expect(request == .getRecord(typeName: "Article", id: "article-1"))
            return .record(expected)
        }
        let client = DatabaseClient(transport: transport)

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
        let transport = FakeDatabaseTransport { request in
            #expect(request == .query(query))
            return .records([first, second])
        }
        let client = DatabaseClient(transport: transport)

        let records = try client.query(query)

        #expect(records == [first, second])
    }

    @Test func remoteFailureThrowsTypedClientError() {
        let transport = FakeDatabaseTransport { _ in
            .failure(status: .executionFailure, message: "storage unavailable")
        }
        let client = DatabaseClient(transport: transport)

        let operation: () throws(DatabaseClientError) -> Void = {
            _ = try client.getRecord(typeName: "Article", id: "article-1")
        }
        let error = captureError(operation)

        #expect(error == DatabaseClientError.remoteFailure(
            status: .executionFailure,
            message: "storage unavailable"
        ))
    }

    @Test func unexpectedPayloadThrowsTypedClientError() {
        let transport = FakeDatabaseTransport { _ in
            .records([])
        }
        let client = DatabaseClient(transport: transport)

        let operation: () throws(DatabaseClientError) -> Void = {
            _ = try client.getRecord(typeName: "Article", id: "article-1")
        }
        let error = captureError(operation)

        #expect(error == DatabaseClientError.unexpectedResponse(.records([])))
    }

    private func captureError(
        _ operation: () throws(DatabaseClientError) -> Void
    ) -> DatabaseClientError? {
        do {
            try operation()
            return nil
        } catch {
            return error
        }
    }
}

private struct FakeDatabaseTransport: DatabaseClientTransport {
    private let handler: @Sendable (DatabaseKitWasmRequest) -> DatabaseKitWasmResponse

    init(
        _ handler: @escaping @Sendable (DatabaseKitWasmRequest) -> DatabaseKitWasmResponse
    ) {
        self.handler = handler
    }

    func send(_ request: [UInt8]) throws(DatabaseClientError) -> [UInt8] {
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
