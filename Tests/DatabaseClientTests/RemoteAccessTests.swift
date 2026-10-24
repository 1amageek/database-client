import DatabaseAccess
import DatabaseClient
import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Synchronization
import Testing

@Suite("Remote logical access ownership", .timeLimit(.minutes(1)))
struct RemoteAccessTests {
    private enum Failure: Error, Equatable { case selection }

    @Test("Original input, options and metadata reach the existing Client once")
    func forwarding() async throws {
        let captured = Mutex<[QueryInput]>([])
        let transport = QueryTestTransport { bytes in
            let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
            captured.withLock { $0.append(request.request.input) }
            #expect(request.metadata.traceID == "access-trace")
            #expect(request.metadata.idempotencyKey == "access-idempotency")
            #expect(request.request.budget.maximumWorkUnits == 1234)
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                requestID: request.requestID, response: .block([.rows(try page(7)), .command(.update, affectedRows: 2),
                    .copy(bytes: ByteString([0, 255]), affectedRows: 1), try booleanResponse(true), .rdfGraph(try graphPage(1))]))
        }
        let configuration = try DatabaseConfiguration.borrowingRemote(
            session: DatabaseClient(transport: transport).database, maximumConcurrentExecutions: 2)
        let endpoint = try await configuration.open()
        defer { await endpoint.close() }
        let input = QueryInput.sql("SELECT $1")
        let result = try await endpoint.execute(input,
            parameters: [QueryParameter(position: 1, value: .primitive(.int32(7)))],
            options: .init(budget: .init(maximumWorkUnits: 1234)),
            metadata: .init(traceID: "access-trace", idempotencyKey: "access-idempotency"))
        #expect(captured.withLock { $0 } == [input])
        #expect(result.results.count == 5 && result.results[1].affectedRows == 2)
        var rows = result.results[0].rows.makeAsyncIterator()
        #expect(try await rows.next()?.values == [.primitive(.int32(7))])
    }

    @Test("Borrowed close drains its scope and preserves the external client")
    func borrowedClose() async throws {
        let transport = QueryTestTransport { bytes in
            let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                requestID: request.requestID, response: .rows(try page(1)))
        }
        let client = DatabaseClient(transport: transport)
        let configuration = try DatabaseConfiguration.borrowingRemote(session: client.database, maximumConcurrentExecutions: 1)
        let endpoint = try await configuration.open()
        defer { await endpoint.close() }
        await endpoint.close()
        await #expect(throws: QueryConnectionError.closed) {
            try await endpoint.execute(.sql("SELECT 1"), parameters: [], options: .init(), metadata: .init())
        }
        let independent = try await client.openConnection()
        defer { await independent.close() }
        #expect(try await independent.execute("SELECT 1").columns.count == 1)
    }

    @Test("Owning acquisition is lazy and concurrent close shuts down exactly once")
    func ownedClose() async throws {
        let opened = Mutex(0), closed = Mutex(0)
        let configuration = try DatabaseConfiguration.owningRemote(maximumConcurrentExecutions: 2,
            makeTransport: { opened.withLock { $0 += 1 }; return QueryTestTransport { _ in throw Failure.selection } },
            shutdown: { _ in closed.withLock { $0 += 1 } })
        #expect(opened.withLock { $0 } == 0)
        let endpoint = try await configuration.open()
        defer { await endpoint.close() }
        #expect(opened.withLock { $0 } == 1)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await endpoint.close() }
            group.addTask { await endpoint.close() }
        }
        #expect(closed.withLock { $0 } == 1)
    }

    @Test("Failure after transport acquisition awaits owned cleanup")
    func failedSelection() async throws {
        let closed = Mutex(0)
        let configuration = try DatabaseConfiguration.owningRemote(maximumConcurrentExecutions: 1,
            makeTransport: { QueryTestTransport { _ in throw Failure.selection } },
            session: { _ in throw Failure.selection }, shutdown: { _ in closed.withLock { $0 += 1 } })
        await #expect(throws: Failure.selection) { try await configuration.open() }
        #expect(closed.withLock { $0 } == 1)
    }

    @Test("A consumed configuration cannot transfer one owner twice")
    func singleUse() async throws {
        let configuration = try DatabaseConfiguration.borrowingRemote(
            session: DatabaseClient(transport: QueryTestTransport { _ in throw Failure.selection }).database,
            maximumConcurrentExecutions: 1)
        let endpoint = try await configuration.open()
        defer { await endpoint.close() }
        await #expect(throws: AccessConfigurationError.openingAlreadyUsed) { try await configuration.open() }
    }

    @Test("Invalid concurrency is rejected without invoking the factory")
    func invalidConcurrency() throws {
        let opened = Mutex(0)
        #expect(throws: AccessConfigurationError.invalidConcurrencyLimit(0)) {
            try DatabaseConfiguration.owningRemote(maximumConcurrentExecutions: 0,
                makeTransport: { opened.withLock { $0 += 1 }; return QueryTestTransport { _ in throw Failure.selection } },
                shutdown: { _ in })
        }
        #expect(opened.withLock { $0 } == 0)
    }

    @Test("Cancellation after acquisition closes the new scope and owned transport")
    func cancelledAcquisition() async throws {
        let gate = QueryExchangeGate(), closed = Mutex(0)
        let configuration = try DatabaseConfiguration.owningRemote(maximumConcurrentExecutions: 1,
            makeTransport: {
                await gate.hold()
                return QueryTestTransport { _ in throw Failure.selection }
            }, shutdown: { _ in closed.withLock { $0 += 1 } })
        let opening = Task { try await configuration.open() }
        await gate.waitUntilEntered()
        opening.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(closed.withLock { $0 } == 1)
    }
}
