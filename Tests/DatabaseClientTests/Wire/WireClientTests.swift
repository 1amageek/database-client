import Testing
import DatabaseWire
@testable import DatabaseClient

@Suite("DatabaseClient Tests")
struct WireClientTests {
    @Test func putRecordSendsBinaryRequestAndAcceptsEmptyResponse() throws {
        let expected = DatabaseWireRecord(
            typeName: "Article",
            id: "article-1",
            fields: [
                DatabaseWireNamedValue(name: "title", value: .string("Hello"))
            ]
        )
        let transport = FakeWireTransport { request in
            #expect(request == .putRecord(expected))
            return .empty
        }
        let client = WireClient(transport: transport)

        try client.putRecord(expected)
    }

    @Test func getRecordDecodesOptionalRecordResponse() throws {
        let expected = DatabaseWireRecord(
            typeName: "Article",
            id: "article-1",
            fields: [
                DatabaseWireNamedValue(name: "title", value: .string("Hello"))
            ]
        )
        let transport = FakeWireTransport { request in
            #expect(request == .getRecord(typeName: "Article", id: "article-1"))
            return .record(expected)
        }
        let client = WireClient(transport: transport)

        let record = try client.getRecord(typeName: "Article", id: "article-1")

        #expect(record == expected)
    }

    @Test func queryReturnsRecordList() throws {
        let first = DatabaseWireRecord(typeName: "Article", id: "a", fields: [])
        let second = DatabaseWireRecord(typeName: "Article", id: "b", fields: [])
        let query = DatabaseWireQueryRequest(
            typeName: "Article",
            predicate: .comparison(field: "status", op: .equal, value: .string("published")),
            limit: 10
        )
        let transport = FakeWireTransport { request in
            #expect(request == .query(query))
            return .records([first, second])
        }
        let client = WireClient(transport: transport)

        let records = try client.query(query)

        #expect(records == [first, second])
    }

    @Test func remoteFailureThrowsTypedClientError() {
        let transport = FakeWireTransport { _ in
            .failure(status: .executionFailure, message: "storage unavailable")
        }
        let client = WireClient(transport: transport)

        let operation: () throws(ClientError) -> Void = {
            _ = try client.getRecord(typeName: "Article", id: "article-1")
        }
        let error = captureError(operation)

        #expect(error == ClientError.remoteFailure(
            status: .executionFailure,
            message: "storage unavailable"
        ))
    }

    @Test func unexpectedPayloadThrowsTypedClientError() {
        let transport = FakeWireTransport { _ in
            .records([])
        }
        let client = WireClient(transport: transport)

        let operation: () throws(ClientError) -> Void = {
            _ = try client.getRecord(typeName: "Article", id: "article-1")
        }
        let error = captureError(operation)

        #expect(error == ClientError.unexpectedResponse(.records([])))
    }

    private func captureError(
        _ operation: () throws(ClientError) -> Void
    ) -> ClientError? {
        do {
            try operation()
            return nil
        } catch {
            return error
        }
    }
}

private struct FakeWireTransport: WireTransport {
    private let handler: @Sendable (DatabaseWireRequest) -> DatabaseWireResponse

    init(
        _ handler: @escaping @Sendable (DatabaseWireRequest) -> DatabaseWireResponse
    ) {
        self.handler = handler
    }

    func send(_ request: [UInt8]) throws(ClientError) -> [UInt8] {
        let decodedRequest: DatabaseWireRequest
        do {
            decodedRequest = try DatabaseWireCodec.decodeRequest(request)
        } catch {
            throw .wire(error)
        }
        let response = handler(decodedRequest)
        do {
            return try DatabaseWireCodec.encode(response: response)
        } catch {
            throw .wire(error)
        }
    }
}
