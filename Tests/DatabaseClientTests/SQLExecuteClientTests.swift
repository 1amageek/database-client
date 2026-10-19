import DatabaseClient
import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Synchronization
import Testing

@Suite("Complete SQL client calls")
struct SQLExecuteClientTests {
    @Test("Text statement and block calls retain their exact request and ordered owned response")
    func typedInputsAndOwnedResults() async throws {
        let statement = QueryStatement.select(SelectQuery(
            projection: [.expression(.parameter(position: 1), alias: "value")], source: .values([])))
        let inputs: [SQLExecuteOperation.Input] = [
            .text("SELECT $1; SHOW ALL"), .statement(statement),
            .block(try SQLBlock(steps: [.statement(statement), .setting(.show(nil))])),
        ]
        let columns = [try QueryColumn(number: 1, name: "value", type: .sql(.text), isNullable: true)]
        let expected = QueryRow(values: [.primitive(.string("retained value"))])
        let transport = SQLClientTestTransport { bytes in
            let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.sqlExecute, from: bytes)
            #expect(request.request.parameters == [QueryParameter(position: 1, value: .primitive(.null), type: .sql(.text))])
            #expect(request.metadata.traceID == "sql-client")
            #expect(request.request.input == inputs[Int(request.requestID) - 1])
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.sqlExecute,
                requestID: request.requestID, response: .init(results: [
                    .rows(try .init(columns: columns, rows: [expected])),
                    .rows(try .init(columns: columns, rows: [])),
                    .copy(bytes: ByteString([0, 255, 10]), affectedRows: 1),
                    .command(.rollback, affectedRows: nil),
                ]))
        }
        let client = DatabaseClient(transport: transport)
        for input in inputs {
            let response = try await executeTestDatabaseOperation(client: client,
                operation: DatabaseOperationCatalog.sqlExecute,
                request: .init(input: input, parameters: [QueryParameter(position: 1, value: .primitive(.null), type: .sql(.text))]),
                metadata: .init(traceID: "sql-client"))
            #expect(response.results.count == 4)
            guard case .rows(let rows) = response.results[0], case .rows(let empty) = response.results[1],
                  case .copy(let copy, let affected) = response.results[2],
                  case .command(let command, let count) = response.results[3] else {
                Issue.record("Ordered SQL outcomes changed kinds")
                return
            }
            var iterator = rows.makeRowIterator()
            #expect(try iterator.next() == expected)
            #expect(try iterator.next() == nil)
            #expect(empty.rowCount == 0)
            #expect(empty.columns == columns)
            #expect(copy == ByteString([0, 255, 10]))
            #expect(copy.retainedByteCount != nil)
            #expect(affected == 1)
            #expect(command == .rollback && count == nil)
        }
    }

    @Test("SQL diagnostics remain typed remote failures with exact identifiers")
    func remoteDiagnosticRemainsTyped() async throws {
        let diagnostic = try SQLDiagnostic(sqlState: "23505", category: .constraint, message: "Duplicate key",
            position: 7, schema: "s", table: "t", column: "c", constraint: "unique_c")
        let failure = try RemoteOperationError(category: .constraint, code: "sql_failure", message: "Failed",
            retryability: .never, sqlDiagnostic: diagnostic)
        let transport = SQLClientTestTransport { bytes in
            let request = try DatabaseWireDecoder().decodeRequestEnvelope(bytes)
            return try DatabaseWireEncoder().encodeFailure(requestID: request.requestID,
                operation: .sqlExecute, error: failure)
        }
        do {
            _ = try await executeTestDatabaseOperation(client: DatabaseClient(transport: transport),
                operation: DatabaseOperationCatalog.sqlExecute, request: .init(input: .text("INSERT")))
            Issue.record("SQL failure became success")
        } catch DatabaseClientError.call(.remote(let remote)) {
            #expect(try remote.sqlDiagnostic() == diagnostic)
            #expect(remote == failure)
        }
    }

    @Test("Complete SQL correlation rejects a response for another request")
    func rejectsMismatchedCorrelation() async throws {
        let transport = SQLClientTestTransport { bytes in
            let request = try DatabaseWireDecoder().decodeRequestEnvelope(bytes)
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.sqlExecute,
                requestID: request.requestID + 1, response: .init(results: [.command(.commit, affectedRows: nil)]))
        }
        await #expect(throws: DatabaseClientError.call(.wire(.unexpectedRequestIdentifier(expected: 1, actual: 2)))) {
            try await executeTestDatabaseOperation(client: DatabaseClient(transport: transport),
                operation: DatabaseOperationCatalog.sqlExecute, request: .init(input: .text("COMMIT")))
        }
    }

    @Test("Cancelled complete SQL calls are never automatically replayed")
    func cancellationDoesNotReplay() async {
        let calls = Mutex(0)
        let transport = SQLClientTestTransport { _ in
            calls.withLock { $0 += 1 }
            throw DatabaseTransportError.cancelled
        }
        await #expect(throws: DatabaseClientError.transport(.cancelled)) {
            try await executeTestDatabaseOperation(client: DatabaseClient(transport: transport),
                operation: DatabaseOperationCatalog.sqlExecute, request: .init(input: .text("UPDATE t SET v = 1")))
        }
        #expect(calls.withLock { $0 } == 1)
    }
}

private struct SQLClientTestTransport: DatabaseTransport {
    let exchange: @Sendable (ByteString) async throws -> ByteString

    init(_ exchange: @escaping @Sendable (ByteString) async throws -> ByteString) {
        self.exchange = exchange
    }

    func send(_ request: ByteString) async throws(DatabaseTransportError) -> ByteString {
        do { return try await exchange(request) }
        catch let error as DatabaseTransportError { throw error }
        catch { throw .invalidResponse(String(describing: error)) }
    }
}
