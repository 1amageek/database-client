import DatabaseAccess
import DatabaseClient
import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Testing

@Suite("Named application access", .timeLimit(.minutes(1)))
struct NamedAccessTests {
    private enum Failure: Error, Equatable { case opening }

    @Test("Lookup is fallible and repeated resolution retains one identity")
    func lookup() async throws {
        let directory = DatabaseDirectory(), endpoint = DirectoryTestEndpoint()
        #expect(throws: AccessError.self) { try directory.database("primary") }
        try await directory.configure(databases: ["primary": configuration(endpoint)])
        defer { await directory.shutdown() }
        #expect(try directory.database("primary") === directory.database("primary"))
        #expect(throws: AccessError.self) { try directory.database("missing") }
        #expect(throws: AccessError.self) { try directory.database("") }
        await #expect(throws: AccessError.self) { try await directory.configure(databases: [:]) }
        #expect(await endpoint.inputs.isEmpty)
    }

    @Test("All names are validated before any acquisition")
    func validatesBeforeOpening() async throws {
        let directory = DatabaseDirectory(), endpoint = DirectoryTestEndpoint()
        let gate = QueryExchangeGate()
        let config = try DatabaseConfiguration(opening: DirectoryTestOpening {
            await gate.hold(); return endpoint
        }, maximumConcurrentExecutions: 1)
        await #expect(throws: AccessError.self) { try await directory.configure(databases: ["": config, "valid": config]) }
        #expect(await endpoint.closeCount == 0)
        #expect(throws: AccessError.self) { try directory.database("valid") }
    }

    @Test("Failure retains the failing alias and closes prior acquisitions")
    func failedStartup() async throws {
        let directory = DatabaseDirectory(), endpoint = DirectoryTestEndpoint()
        let failing = try DatabaseConfiguration(opening: DirectoryTestOpening { throw Failure.opening }, maximumConcurrentExecutions: 1)
        do {
            try await directory.configure(databases: ["a": configuration(endpoint), "b": failing])
            Issue.record("Expected acquisition failure")
        } catch let error as AccessError {
            guard case .initializationFailed(let name, let cause) = error else { Issue.record("Wrong startup failure"); return }
            #expect(name == "b" && cause as? Failure == .opening)
        }
        #expect(await endpoint.closeCount == 1)
        #expect(throws: AccessError.self) { try directory.database("a") }
        try await directory.configure(databases: ["fresh": configuration(DirectoryTestEndpoint())])
        await directory.shutdown()
    }

    @Test("Configuration publishes no partial aliases and rejects a competing configure")
    func atomicPublication() async throws {
        let directory = DatabaseDirectory(), first = DirectoryTestEndpoint(), second = DirectoryTestEndpoint(), gate = QueryExchangeGate()
        let delayed = try DatabaseConfiguration(opening: DirectoryTestOpening { await gate.hold(); return second }, maximumConcurrentExecutions: 1)
        let opening = Task { try await directory.configure(databases: ["a": configuration(first), "b": delayed]) }
        await gate.waitUntilEntered()
        #expect(throws: AccessError.self) { try directory.database("a") }
        await #expect(throws: AccessError.self) { try await directory.configure(databases: [:]) }
        await gate.release()
        try await opening.value
        #expect(try directory.database("a").name == "a")
        #expect(try directory.database("b").name == "b")
        await directory.shutdown()
        #expect(await first.closeCount == 1)
        #expect(await second.closeCount == 1)
    }

    @Test("Cancellation does not erase a factory's original typed failure")
    func failureDuringCancellation() async throws {
        let directory = DatabaseDirectory(), endpoint = DirectoryTestEndpoint(), gate = QueryExchangeGate()
        let delayed = try DatabaseConfiguration(opening: DirectoryTestOpening {
            await gate.hold(); throw Failure.opening
        }, maximumConcurrentExecutions: 1)
        let opening = Task { try await directory.configure(databases: ["a": configuration(endpoint), "b": delayed]) }
        await gate.waitUntilEntered()
        opening.cancel()
        await gate.release()
        do {
            try await opening.value
            Issue.record("Expected the original typed acquisition failure")
        } catch let error as AccessError {
            guard case .initializationFailed(let name, let cause) = error else { Issue.record("Wrong acquisition failure"); return }
            #expect(name == "b" && cause as? Failure == .opening)
        }
        #expect(await endpoint.closeCount == 1)
    }

    @Test("Caller cancellation waits for all returned resources to close")
    func cancelledStartup() async throws {
        let directory = DatabaseDirectory(), first = DirectoryTestEndpoint(), second = DirectoryTestEndpoint(), gate = QueryExchangeGate()
        let delayed = try DatabaseConfiguration(opening: DirectoryTestOpening { await gate.hold(); return second }, maximumConcurrentExecutions: 1)
        let opening = Task { try await directory.configure(databases: ["a": configuration(first), "b": delayed]) }
        await gate.waitUntilEntered()
        opening.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(await first.closeCount == 1)
        #expect(await second.closeCount == 1)
        #expect(throws: AccessError.self) { try directory.database("a") }
    }

    @Test("Shutdown during initialization cancels and joins unpublished cleanup")
    func shutdownDuringStartup() async throws {
        let directory = DatabaseDirectory(), endpoint = DirectoryTestEndpoint(), gate = QueryExchangeGate()
        let delayed = try DatabaseConfiguration(opening: DirectoryTestOpening { await gate.hold(); return endpoint }, maximumConcurrentExecutions: 1)
        let opening = Task { try await directory.configure(databases: ["primary": delayed]) }
        await gate.waitUntilEntered()
        let stopping = Task { await directory.shutdown() }
        // Wait for shutdown's synchronous admission boundary, not a timed delay.
        while true {
            do { _ = try directory.database("primary") }
            catch let error as AccessError {
                if case .shuttingDown = error { break }
            }
            await Task.yield()
        }
        await gate.release()
        await stopping.value
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(await endpoint.closeCount == 1)
    }

    @Test("Concurrent and cancelled shutdown callers await the same close")
    func sharedShutdown() async throws {
        let gate = QueryExchangeGate(), directory = DatabaseDirectory(), endpoint = DirectoryTestEndpoint(closeGate: gate)
        try await directory.configure(databases: ["primary": configuration(endpoint)])
        let handle = try directory.database("primary")
        let first = Task { await directory.shutdown() }
        await gate.waitUntilEntered()
        let second = Task { await directory.shutdown() }
        first.cancel(); second.cancel()
        await #expect(throws: AccessError.self) { try await handle.execute("SELECT 1") }
        #expect(throws: AccessError.self) { try directory.database("primary") }
        await gate.release()
        await first.value; await second.value
        #expect(await endpoint.closeCount == 1)
        #expect(await endpoint.inputs.isEmpty)
    }

    @Test("Reusing a name never rebinds an old handle or query reference")
    func staleReferences() async throws {
        let directory = DatabaseDirectory(), old = DirectoryTestEndpoint(1), fresh = DirectoryTestEndpoint(2)
        try await directory.configure(databases: ["primary": configuration(old)])
        let previous = try directory.database("primary"), query = previous.entity("items").select("n")
        await directory.shutdown()
        try await directory.configure(databases: ["primary": configuration(fresh)])
        defer { await directory.shutdown() }
        #expect(previous !== (try directory.database("primary")))
        await #expect(throws: AccessError.self) { try await previous.execute("SELECT 1") }
        await #expect(throws: AccessError.self) { try await query.execute() }
        #expect(await fresh.inputs.isEmpty)
        var rows = try await directory.database("primary").execute("SELECT 2").rows.makeAsyncIterator()
        #expect(try await rows.next()?.values == [.primitive(.int32(2))])
    }

    @Test("Isolated directories can use identical aliases without shared state")
    func isolatedDirectories() async throws {
        let first = DatabaseDirectory(), second = DatabaseDirectory()
        let a = DirectoryTestEndpoint(1), b = DirectoryTestEndpoint(2)
        try await first.configure(databases: ["primary": configuration(a)])
        try await second.configure(databases: ["primary": configuration(b)])
        await first.shutdown()
        _ = try await second.database("primary").execute("SELECT 2")
        #expect(await a.inputs.isEmpty)
        #expect(await b.inputs.count == 1)
        await second.shutdown()
    }

    @Test("Typed and named construction performs no invocation and preserves pure IR")
    func queryConstruction() async throws {
        let directory = DatabaseDirectory(), endpoint = DirectoryTestEndpoint()
        try await directory.configure(databases: ["primary": configuration(endpoint)])
        defer { await directory.shutdown() }
        let database = try directory.database("primary")
        let pure = try AccessPerson.select(#field(\AccessPerson.name)).where(#field(\AccessPerson.isActive) == true).limit(5)
        let bound = try database.entity(AccessPerson.self).select(#field(\AccessPerson.name)).where(#field(\AccessPerson.isActive) == true).limit(5)
        #expect(bound.definition == pure.definition)
        let branch = bound.limit(1)
        #expect(branch.definition != bound.definition)
        #expect(await endpoint.inputs.isEmpty)
        _ = try await bound.execute(options: .init(budget: .init(maximumWorkUnits: 42)), metadata: .init(traceID: "trace"))
        _ = try await database.execute(pure)
        #expect(await endpoint.inputs == [.statement(.select(pure.definition)), .statement(.select(pure.definition))])
        let table = TableRef(schema: "Exact.Schema", table: "Exact.Table", alias: "t", partitions: FieldObject())
        let named = database.entity(table).select("name")
        #expect(named.definition.source == table.querySource)
    }

    @Test("Bound joins require access identity and keep canonical source metadata")
    func joins() async throws {
        let directory = DatabaseDirectory()
        try await directory.configure(databases: ["a": configuration(DirectoryTestEndpoint()), "b": configuration(DirectoryTestEndpoint())])
        defer { await directory.shutdown() }
        let a = try directory.database("a"), b = try directory.database("b")
        let query = a.entity("items").selectAll()
        #expect(throws: AccessError.self) { try query.join(b.entity("other"), on: .bool(true)) }
        let joined = try query.join(a.entity(TableRef(schema: "public", table: "other", alias: "o")), on: .bool(true))
        guard case .join(let clause) = joined.definition.source else { Issue.record("Join was lost"); return }
        #expect(clause.right == TableRef(schema: "public", table: "other", alias: "o").querySource)
    }

    @Test("SQL interpolation and execution options remain canonical bound input")
    func forwarding() async throws {
        let directory = DatabaseDirectory(), endpoint = DirectoryTestEndpoint()
        try await directory.configure(databases: ["primary": configuration(endpoint)])
        defer { await directory.shutdown() }
        let hostile = "Robert'); DROP TABLE items; --"
        _ = try await directory.database("primary").execute("SELECT \(hostile)::text", options: .init(budget: .init(maximumWorkUnits: 123)), metadata: .init(traceID: "named"))
        #expect(await endpoint.inputs == [.sql("SELECT $1::text")])
        #expect(await endpoint.parameters == [QueryParameter(position: 1, value: .primitive(.string(hostile)))])
        #expect(await endpoint.options.budget.maximumWorkUnits == 123)
        #expect(await endpoint.metadata.traceID == "named")
    }

    @Test("Application convenience resolves the configured singleton generation")
    func applicationLookup() async throws {
        let endpoint = DirectoryTestEndpoint()
        try await Database.configure(databases: ["primary": configuration(endpoint)])
        defer { await Database.shutdown() }
        #expect(try Database.database("primary") === Database.database("primary"))
        _ = try await Database.database("primary").execute("SELECT 1")
        #expect(await endpoint.inputs.count == 1)
    }

    @Test("Named execution preserves bounded admission and independent cancellation")
    func executionAdmission() async throws {
        let firstGate = QueryExchangeGate(), secondGate = QueryExchangeGate(), directory = DatabaseDirectory()
        let transport = QueryTestTransport { bytes in
            let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
            if request.request.input == .sql("SELECT 1") { await firstGate.hold() }
            if request.request.input == .sql("SELECT 2") { await secondGate.hold() }
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                requestID: request.requestID, response: .rows(try page(1)))
        }
        try await directory.configure(databases: ["primary": .borrowingRemote(
            session: DatabaseClient(transport: transport).database, maximumConcurrentExecutions: 2)])
        defer { await directory.shutdown() }
        let database = try directory.database("primary")
        let first = Task { try await database.execute("SELECT 1") }
        let second = Task { try await database.execute("SELECT 2") }
        await firstGate.waitUntilEntered(); await secondGate.waitUntilEntered()
        await #expect(throws: QueryConnectionError.concurrentExecutionLimitReached(2)) { try await database.execute("SELECT 3") }
        first.cancel()
        await firstGate.release()
        await #expect(throws: (any Error).self) { try await first.value }
        await secondGate.release()
        #expect(try await second.value.columns.count == 1)
        #expect(try await database.execute("SELECT 3").columns.count == 1)
    }

    private func configuration(_ endpoint: DirectoryTestEndpoint) throws -> DatabaseConfiguration {
        try DatabaseConfiguration(opening: DirectoryTestOpening { endpoint }, maximumConcurrentExecutions: 2)
    }
}
