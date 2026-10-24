import DatabaseAccess
import DatabaseClient
import DatabaseKit
import DatabaseTypes
import DatabaseWire
#if canImport(WASILibc)
import WASILibc
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct AccessRuntimeContract {
    enum Failure: Error { case assertion }

    static func main() async {
        print("ACCESS_RUNTIME_BEGIN")
        do {
            try await retainedRows()
            try await remoteRows()
            try await remoteGraph()
            try await terminalFailure()
            try await closeRetained()
            try await outcomes()
            try await ownedAccess()
            try await borrowedAccess()
            try await namedAccess()
            try await applicationAccess()
            try await startupShutdown()
            print("ACCESS_RUNTIME_PASS cases=11")
        } catch {
            print("ACCESS_RUNTIME_FAIL")
            exit(1)
        }
    }

    static func require(_ condition: Bool) throws(Failure) {
        guard condition else { throw .assertion }
    }

    static func retainedRows() async throws {
        let page = try AccessRuntimeTransport.page(7, continuation: nil)
        let stream = try RowStream(page: page)
        var first = stream.makeAsyncIterator()
        var second = first
        try require(try await first.next()?.values == [.primitive(.int32(7))])
        try require(try await second.next()?.values == [.primitive(.int32(7))])
        try require(try await first.next() == nil)
        var pages = stream.pages.makeAsyncIterator()
        try require(try await pages.next()?.columns == page.columns)
        try require(try await pages.next() == nil)
        print("ACCESS_RUNTIME_CASE retained-rows PASS")
    }

    static func remoteRows() async throws {
        let connection = try await DatabaseClient(transport: AccessRuntimeTransport(mode: .rows)).openConnection()
        defer { await connection.close() }
        guard case .rows(let rows) = try await connection.execute("SELECT n", options: .init(pageSize: 1)) else { throw Failure.assertion }
        let stream = RowStream(rows)
        var iterator = stream.makeAsyncIterator()
        try require(try await iterator.next()?.values == [.primitive(.int32(1))])
        try require(try await iterator.next()?.values == [.primitive(.int32(2))])
        try require(try await iterator.next() == nil)
        var pages = stream.pages.makeAsyncIterator()
        try require(try await pages.next()?.continuation == ByteString([1]))
        try require(try await pages.next()?.continuation == nil)
        try require(try await pages.next() == nil)
        print("ACCESS_RUNTIME_CASE paged-rows PASS")
    }

    static func remoteGraph() async throws {
        let connection = try await DatabaseClient(transport: AccessRuntimeTransport(mode: .graph)).openConnection()
        defer { await connection.close() }
        guard case .rdfGraph(let graph) = try await connection.execute("SELECT graph", options: .init(pageSize: 1)) else { throw Failure.assertion }
        let stream = GraphStream(graph)
        var iterator = stream.makeAsyncIterator()
        try require(try await iterator.next() != nil)
        try require(try await iterator.next() != nil)
        try require(try await iterator.next() == nil)
        var pages = stream.pages.makeAsyncIterator()
        try require(try await pages.next()?.continuation == ByteString([1]))
        try require(try await pages.next()?.continuation == nil)
        try require(try await pages.next() == nil)
        print("ACCESS_RUNTIME_CASE paged-graph PASS")
    }

    static func terminalFailure() async throws {
        let connection = try await DatabaseClient(transport: AccessRuntimeTransport(mode: .changedColumns)).openConnection()
        defer { await connection.close() }
        guard case .rows(let rows) = try await connection.execute("SELECT n", options: .init(pageSize: 1)) else { throw Failure.assertion }
        var iterator = RowStream(rows).makeAsyncIterator()
        try require(try await iterator.next() != nil)
        var rejected = false
        do { _ = try await iterator.next() }
        catch { rejected = true }
        try require(rejected)
        try require(try await iterator.next() == nil)
        print("ACCESS_RUNTIME_CASE terminal-failure PASS")
    }

    static func closeRetained() async throws {
        let connection = try await DatabaseClient(transport: AccessRuntimeTransport(mode: .rows)).openConnection()
        defer { await connection.close() }
        guard case .rows(let rows) = try await connection.execute("SELECT n", options: .init(pageSize: 1)) else { throw Failure.assertion }
        var iterator = RowStream(rows).makeAsyncIterator()
        await connection.close()
        try require(try await iterator.next() != nil)
        var rejected = false
        do { _ = try await iterator.next() }
        catch { rejected = true }
        try require(rejected)
        try require(try await iterator.next() == nil)
        print("ACCESS_RUNTIME_CASE close-retained PASS")
    }

    static func outcomes() async throws {
        let rows = try RowStream(page: AccessRuntimeTransport.page(1, continuation: nil))
        let graph = try GraphStream(page: AccessRuntimeTransport.graph(1, continuation: nil))
        #if DATABASE_CLIENT_MULTI_BASE
        let truth = try QueryBooleanResult(value: true, provenance: nil,
            consistency: .transactional(DomainReadPoint(domainID: "access", position: .version(1))))
        #else
        let truth = true
        #endif
        let result = AccessResult.block([.rows(rows), .boolean(truth), .rdfGraph(graph),
            .command(.update, affectedRows: 2), .copy(bytes: ByteString([0, 255]), affectedRows: 1)])
        try require(result.results.count == 5 && result.results[3].affectedRows == 2)
        guard case .copy(let bytes, let count) = result.results[4] else { throw Failure.assertion }
        try require(bytes == ByteString([0, 255]) && count == 1)
        var empty = result.results[3].rows.makeAsyncIterator()
        try require(try await empty.next() == nil)
        print("ACCESS_RUNTIME_CASE outcome-kinds PASS")
    }

    static func ownedAccess() async throws {
        let closed = AccessRuntimeCount()
        let configuration = try DatabaseConfiguration.owningRemote(maximumConcurrentExecutions: 2,
            makeTransport: { AccessRuntimeTransport(mode: .rows) },
            shutdown: { _ in closed.recordShutdown() })
        let access = try await configuration.open()
        let result = try await access.execute(.sql("SELECT n"), parameters: [], options: .init(pageSize: 1), metadata: .init())
        var iterator = result.rows.makeAsyncIterator()
        try require(try await iterator.next()?.values == [.primitive(.int32(1))])
        try require(try await iterator.next()?.values == [.primitive(.int32(2))])
        await access.close()
        await access.close()
        try require(closed.count == 1)
        var rejected = false
        do { _ = try await access.execute(.sql("SELECT n"), parameters: [], options: .init(), metadata: .init()) }
        catch { rejected = true }
        try require(rejected)
        print("ACCESS_RUNTIME_CASE owned-access PASS")
    }

    static func borrowedAccess() async throws {
        let client = DatabaseClient(transport: AccessRuntimeTransport(mode: .rows))
        let configuration = try DatabaseConfiguration.borrowingRemote(session: client.database, maximumConcurrentExecutions: 1)
        let access = try await configuration.open()
        await access.close()
        let independent = try await client.openConnection()
        defer { await independent.close() }
        let result = try await independent.execute("SELECT n", options: .init(pageSize: 1))
        var rows = result.rows.makeAsyncIterator()
        try require(try await rows.next()?.values == [.primitive(.int32(1))])
        print("ACCESS_RUNTIME_CASE borrowed-access PASS")
    }

    static func namedAccess() async throws {
        let directory = DatabaseDirectory()
        let client = DatabaseClient(transport: AccessRuntimeTransport(mode: .rows))
        try await directory.configure(databases: ["primary": .borrowingRemote(session: client.database, maximumConcurrentExecutions: 2)])
        defer { await directory.shutdown() }
        let provider: any DatabaseProviding = directory
        let database = try provider.database("primary")
        let querying: any DatabaseQuerying = database
        _ = try await querying.execute(.sql("SELECT n"), parameters: [], options: .init(pageSize: 1), metadata: .init())
        try require(database === directory.database("primary"))
        let pure = try AccessRuntimePerson.select(AccessRuntimePerson.fields.name, AccessRuntimePerson.fields.isActive)
            .where(AccessRuntimePerson.fields.isActive == true).limit(2)
        let bound = try database.entity(AccessRuntimePerson.self).select(AccessRuntimePerson.fields.name, AccessRuntimePerson.fields.isActive)
            .where(AccessRuntimePerson.fields.isActive == true).limit(2)
        try require(bound.definition == pure.definition)
        let result = try await bound.execute(options: .init(pageSize: 1))
        var rows = result.rows.makeAsyncIterator()
        try require(try await rows.next()?.values == [.primitive(.int32(1))])
        try require(try await rows.next()?.values == [.primitive(.int32(2))])
        await directory.shutdown()
        try await directory.configure(databases: ["primary": .borrowingRemote(session: client.database, maximumConcurrentExecutions: 2)])
        var rejected = false
        do { _ = try await bound.execute() } catch { rejected = true }
        try require(rejected)
        try require(database !== directory.database("primary"))
        _ = try await directory.database("primary").execute(pure, options: .init(pageSize: 1))
        print("ACCESS_RUNTIME_CASE named-access PASS")
    }

    static func applicationAccess() async throws {
        let client = DatabaseClient(transport: AccessRuntimeTransport(mode: .rows))
        try await Database.configure(databases: ["primary": .borrowingRemote(session: client.database, maximumConcurrentExecutions: 2)])
        defer { await Database.shutdown() }
        let database = try Database.database("primary")
        try require(database === Database.database("primary"))
        _ = try await database.execute("SELECT n", options: .init(pageSize: 1))
        await Database.shutdown()
        var rejected = false
        do { _ = try await database.execute("SELECT n") } catch { rejected = true }
        try require(rejected)
        print("ACCESS_RUNTIME_CASE application-access PASS")
    }

    static func startupShutdown() async throws {
        let directory = DatabaseDirectory(), gate = AccessRuntimeGate(), closed = AccessRuntimeCount()
        let first = try DatabaseConfiguration.owningRemote(maximumConcurrentExecutions: 1,
            makeTransport: { AccessRuntimeTransport(mode: .rows) }, shutdown: { _ in closed.recordShutdown() })
        let second = try DatabaseConfiguration.owningRemote(maximumConcurrentExecutions: 1,
            makeTransport: { await gate.hold(); return AccessRuntimeTransport(mode: .rows) },
            shutdown: { _ in closed.recordShutdown() })
        let opening = Task { try await directory.configure(databases: ["a": first, "b": second]) }
        await gate.waitUntilEntered()
        let stopping = Task { await directory.shutdown() }
        var closing = false
        while !closing {
            do { _ = try directory.database("a") }
            catch { if case .shuttingDown = error { closing = true } }
            if !closing { await Task.yield() }
        }
        await gate.release()
        await stopping.value
        var rejected = false
        do { try await opening.value } catch { rejected = true }
        try require(rejected && closed.count == 2)
        print("ACCESS_RUNTIME_CASE startup-shutdown PASS")
    }
}
