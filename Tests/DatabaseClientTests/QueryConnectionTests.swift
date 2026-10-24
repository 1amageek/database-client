import DatabaseClient
import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Synchronization
import Testing

@Suite("Canonical query connections", .timeLimit(.minutes(1)))
struct QueryConnectionTests {
    @Test("Complete inputs and ordered outcomes retain exact canonical values after close")
    func inputsAndOutcomes() async throws {
        let captured = Mutex<[QueryInput]>([])
        let expected = try makeTestQueryResponsePage()
        let transport = QueryTestTransport { bytes in
            let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
            #expect(request.request.page == nil)
            captured.withLock { $0.append(request.request.input) }
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                requestID: request.requestID, response: .init(results: [
                    .rows(expected), .command(.update, affectedRows: 2),
                    .copy(bytes: ByteString([0, 255]), affectedRows: 1),
                    booleanResponse(true), .rdfGraph(try graphPage(1)),
                ]))
        }
        let connection = try await DatabaseClient(transport: transport).openConnection()
        defer { await connection.close() }
        let statement = QueryStatement.select(SelectQuery(projection: [.expression(.int(7), alias: "v")], source: .values([[]])))
        let block = try SQLBlock(steps: [.statement(statement)])
        let first = try await connection.execute("SELECT \(Int32(7)) AS v")
        _ = try await connection.execute(statement)
        _ = try await connection.execute(block)
        #expect(captured.withLock { $0 } == [.sql("SELECT $1 AS v"), .statement(statement), .block(block)])
        await connection.close()
        #expect(first.results.count == 5 && first.results[1].affectedRows == 2)
        #expect(try await values(first.results[0].rows) == expected.materializedRows(maximumCount: 1))
        #expect(try await values(first.results[1].rows).isEmpty)
        guard case .copy(let bytes, let count) = first.results[2] else { Issue.record("COPY kind lost"); return }
        #expect(bytes == ByteString([0, 255]) && count == 1)
        guard case .boolean(let truth) = first.results[3], case .rdfGraph(let graph) = first.results[4] else {
            Issue.record("Boolean or RDF kind lost"); return
        }
        #expect(truth.value)
        var graphIterator = graph.makeAsyncIterator()
        #expect(try await graphIterator.next() != nil)
        #expect(try await graphIterator.next() == nil)
    }

    @Test("Read pages preserve original invocation and release their iterator at EOF")
    func pages() async throws {
        let calls = Mutex<[QueryExecuteOperation.Request]>([])
        let transport = QueryTestTransport { bytes in
            let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
            calls.withLock { $0.append(request.request) }
            #expect(request.metadata.traceID == "query-pages")
            let first = request.request.page?.continuation == nil
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                requestID: request.requestID, response: .rows(try page(first ? 1 : 2,
                    continuation: first ? ByteString(utf8: "next") : nil)))
        }
        let connection = try await DatabaseClient(transport: transport).openConnection()
        defer { await connection.close() }
        let response = try await connection.execute("SELECT \(Int32(1))", options: .init(pageSize: 1), metadata: .init(traceID: "query-pages"))
        #expect(try await values(response.rows).map { $0.values } == [[.primitive(.int32(1))], [.primitive(.int32(2))]])
        let requests = calls.withLock { $0 }
        #expect(requests.count == 2 && requests[0].input == requests[1].input)
        #expect(requests[0].parameters == requests[1].parameters && requests[0].budget == requests[1].budget)
        #expect(requests[1].page?.limit == 1 && requests[1].page?.continuation == ByteString(utf8: "next"))
        let graphTransport = QueryTestTransport { bytes in
            let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
            let first = request.request.page?.continuation == nil
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                requestID: request.requestID, response: .rdfGraph(try graphPage(first ? 1 : 2,
                    continuation: first ? ByteString(utf8: "graph-next") : nil)))
        }
        let graphConnection = try await DatabaseClient(transport: graphTransport).openConnection()
        defer { await graphConnection.close() }
        let graphResult = try await graphConnection.execute(QueryInput.text(language: .sparql, statement: "CONSTRUCT {} WHERE {}"),
            options: .init(pageSize: 1))
        guard case .rdfGraph(let graph) = graphResult else { Issue.record("Expected RDF"); return }
        var quads: [RDFQuad] = []
        for try await quad in graph { quads.append(quad) }
        let firstQuad = try graphPage(1).materializedQuads(maximumCount: 1)
        let secondQuad = try graphPage(2).materializedQuads(maximumCount: 1)
        #expect(quads == firstQuad + secondQuad)
        #if DATABASE_CLIENT_MULTI_BASE
        let baseA = try Base.ID("a"), baseB = try Base.ID("b")
        let composition = try CompositionResolution.derived([baseA, baseB])
        let consistency = DatabaseReadConsistency.transactional(try DomainReadPoint(domainID: "pages", position: .version(1)))
        let provenanceTransport = QueryTestTransport { bytes in
            let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
            let first = request.request.page?.continuation == nil
            let ordinary = try page(first ? 1 : 2)
            let selected = try QueryRowPage(columns: ordinary.columns,
                rows: ordinary.materializedRows(maximumCount: 1),
                continuation: first ? ByteString(utf8: "origin-next") : nil,
                provenance: CompositionPageProvenance(composition: composition,
                    origins: [.source(first ? baseA : baseB)]), consistency: consistency)
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                requestID: request.requestID, response: .rows(selected))
        }
        let provenanceConnection = try await DatabaseClient(transport: provenanceTransport).openConnection()
        defer { await provenanceConnection.close() }
        let sourced = try await provenanceConnection.execute("SELECT 1", options: .init(pageSize: 1))
        var origins: [CompositionOrigin] = []
        for try await page in sourced.rows.pages {
            var iterator = page.provenance?.makeOriginIterator()
            if let origin = try iterator?.next() { origins.append(origin) }
        }
        #expect(origins == [.source(baseA), .source(baseB)])
        #endif
    }

    @Test("Malformed page progress, schema and kind are typed terminal failures")
    func invalidPages() async throws {
        for mode in 0..<3 {
            let transport = QueryTestTransport { bytes in
                let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
                let first = request.request.page?.continuation == nil
                let response: QueryExecuteOperation.Response
                if first { response = .rows(try page(1, continuation: ByteString(utf8: "next"))) }
                else if mode == 0 { response = .rows(try page(2, continuation: ByteString(utf8: "next"))) }
                else if mode == 1 { response = .rows(try page(2, name: "changed")) }
                else { response = .command(.update, affectedRows: 1) }
                return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                    requestID: request.requestID, response: response)
            }
            let connection = try await DatabaseClient(transport: transport).openConnection()
            defer { await connection.close() }
            let response = try await connection.execute("SELECT 1", options: .init(pageSize: 1))
            var iterator = response.rows.makeAsyncIterator()
            #expect(try await iterator.next()?.values == [.primitive(.int32(1))])
            let failure: QueryStreamError = mode == 0 ? .continuationDidNotAdvance : mode == 1 ? .changedColumns : .unexpectedResultKind
            await #expect(throws: failure) { try await iterator.next() }
            #expect(try await iterator.next() == nil)
        }
    }

    @Test("Close cancels and drains admitted work and leaves the shared transport usable")
    func closeDrains() async throws {
        let gate = QueryExchangeGate()
        let calls = Mutex(0)
        let transport = QueryTestTransport { bytes in
            let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
            let count = calls.withLock { $0 += 1; return $0 }
            if count == 1 {
                await gate.hold()
                if Task.isCancelled { throw DatabaseTransportError.cancelled }
            }
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                requestID: request.requestID, response: .command(.update, affectedRows: 1))
        }
        let client = DatabaseClient(transport: transport)
        let connection = try await client.openConnection()
        defer { await connection.close() }
        defer { await gate.release() }
        let execution = Task { try await connection.execute("UPDATE t SET n = 1") }
        await gate.waitUntilEntered()
        let finished = Mutex(false)
        let closing = Task { await connection.close(); finished.withLock { $0 = true } }
        var rejected = false
        for _ in 0..<1000 {
            do { _ = try await connection.execute("SELECT 1") }
            catch QueryConnectionError.closed { rejected = true; break }
            catch QueryConnectionError.concurrentExecutionLimitReached { await Task.yield() }
        }
        #expect(rejected && !finished.withLock { $0 })
        await gate.release()
        await closing.value
        await #expect(throws: DatabaseClientError.transport(.cancelled)) { try await execution.value }
        #expect(calls.withLock { $0 } == 1)
        let independent = try await client.openConnection()
        defer { await independent.close() }
        #expect(try await independent.execute("UPDATE t SET n = 2").affectedRows == 1)
        await connection.close()
    }

    @Test("Transport failure and mismatched correlation never replay effects")
    func errorsDoNotRetry() async throws {
        for mismatch in [false, true] {
            let calls = Mutex(0)
            let transport = QueryTestTransport { bytes in
                calls.withLock { $0 += 1 }
                if !mismatch { throw DatabaseTransportError.timeout }
                let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
                return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                    requestID: request.requestID + 1, response: .command(.update, affectedRows: 1))
            }
            let connection = try await DatabaseClient(transport: transport).openConnection()
            defer { await connection.close() }
            let failure: DatabaseClientError = mismatch
                ? .call(.wire(.unexpectedRequestIdentifier(expected: 1, actual: 2))) : .transport(.timeout)
            await #expect(throws: failure) { try await connection.execute("UPDATE t SET n = 1") }
            #expect(calls.withLock { $0 } == 1)
        }
    }

    @Test("Rows and graphs terminate adjacent, alternating and prefixed continuation cycles")
    func continuationCycles() async throws {
        for graph in [false, true] {
            for (prefix, period) in [(0, 1), (0, 2), (3, 2), (5, 17)] {
                let calls = Mutex(0)
                let transport = QueryTestTransport { bytes in
                    let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
                    let index = calls.withLock { let value = $0; $0 += 1; return value }
                    let name = index < prefix ? "prefix-\(index)" : "cycle-\((index - prefix) % period)"
                    let token = ByteString(utf8: name)
                    let result: QueryExecuteOperation.Response = graph
                        ? .rdfGraph(try graphPage(index, continuation: token))
                        : .rows(try page(Int32(index), continuation: token))
                    return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                        requestID: request.requestID, response: result)
                }
                let connection = try await DatabaseClient(transport: transport).openConnection()
                defer { await connection.close() }
                let result = try await connection.execute("SELECT 1", options: .init(pageSize: 1))
                let bound = prefix + period * 4 + 16
                if case .rdfGraph(let values) = result {
                    try await expectTerminalFailure(values.pages, error: .continuationDidNotAdvance, maximumElements: bound)
                } else {
                    try await expectTerminalFailure(result.rows.pages, error: .continuationDidNotAdvance, maximumElements: bound)
                }
                #expect(calls.withLock { $0 } <= bound + 1)
            }
        }
    }

    @Test("Initial and continuation row or graph responses cannot exceed the explicit page size")
    func oversizedPages() async throws {
        for graph in [false, true] {
            for initial in [false, true] {
                let calls = Mutex(0)
                let transport = QueryTestTransport { bytes in
                    let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
                    let first = calls.withLock { $0 += 1; return $0 == 1 }
                    let count = initial || !first ? 2 : 1
                    let token = !initial && first ? ByteString(utf8: "next") : nil
                    let result: QueryExecuteOperation.Response = graph
                        ? .rdfGraph(try graphPage(1, continuation: token, count: count))
                        : .rows(try page(1, continuation: token, count: count))
                    return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                        requestID: request.requestID, response: result)
                }
                let connection = try await DatabaseClient(transport: transport).openConnection()
                defer { await connection.close() }
                let expected = QueryStreamError.pageLimitExceeded(actual: 2, maximum: 1)
                if initial {
                    await #expect(throws: expected) {
                        try await connection.execute("SELECT 1", options: .init(pageSize: 1))
                    }
                } else {
                    let result = try await connection.execute("SELECT 1", options: .init(pageSize: 1))
                    if case .rdfGraph(let values) = result {
                        try await expectTerminalFailure(values.pages, error: expected, maximumElements: 2)
                    } else {
                        try await expectTerminalFailure(result.rows.pages, error: expected, maximumElements: 2)
                    }
                }
                #expect(calls.withLock { $0 } == (initial ? 1 : 2))
            }
        }
    }

    @Test("Paged requests reject complete block, command and COPY envelopes before adapting rows")
    func invalidInitialPageKinds() async throws {
        let outcomes: [QueryExecuteOperation.Response] = [
            .block([.rows(try page(1, count: 2))]),
            .block([.rdfGraph(try graphPage(1, count: 2))]),
            .command(.update, affectedRows: 1), .copy(bytes: ByteString([1]), affectedRows: 1),
        ]
        for outcome in outcomes {
            let transport = QueryTestTransport { bytes in
                let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
                return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                    requestID: request.requestID, response: outcome)
            }
            let connection = try await DatabaseClient(transport: transport).openConnection()
            defer { await connection.close() }
            await #expect(throws: QueryStreamError.unexpectedResultKind) {
                try await connection.execute("SELECT 1", options: .init(pageSize: 1))
            }
            let complete = try await connection.execute("SELECT 1")
            #expect(complete.results.count == outcome.results.count)
        }
    }

    @Test("Long acyclic row and graph continuations retain order and terminate normally")
    func longContinuationChains() async throws {
        for graph in [false, true] {
            let calls = Mutex(0)
            let transport = QueryTestTransport { bytes in
                let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
                let index = calls.withLock { $0 += 1; return $0 }
                let token = index < 257 ? ByteString(utf8: "next-\(index)") : nil
                let result: QueryExecuteOperation.Response = graph
                    ? .rdfGraph(try graphPage(index, continuation: token))
                    : .rows(try page(Int32(index), continuation: token))
                return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                    requestID: request.requestID, response: result)
            }
            let connection = try await DatabaseClient(transport: transport).openConnection()
            defer { await connection.close() }
            let result = try await connection.execute("SELECT 1", options: .init(pageSize: 1))
            var count = 0
            if case .rdfGraph(let values) = result {
                for try await _ in values { count += 1 }
            } else {
                for try await value in result.rows {
                    count += 1
                    #expect(value.values == [.primitive(.int32(Int32(count)))])
                }
            }
            #expect(count == 257 && calls.withLock { $0 } == 257)
        }
    }

    private func expectTerminalFailure<Pages: AsyncSequence>(_ pages: Pages,
        error expected: QueryStreamError, maximumElements: Int) async throws {
        var iterator = pages.makeAsyncIterator()
        var failed = false
        for _ in 0..<maximumElements {
            do {
                guard try await iterator.next() != nil else { break }
            } catch let error as QueryStreamError {
                #expect(error == expected)
                failed = true
                break
            }
        }
        #expect(failed)
        #expect(try await iterator.next() == nil)
    }

    private func values<Rows: QueryRows>(_ rows: Rows) async throws -> [QueryRow] {
        var result: [QueryRow] = []
        for try await row in rows { result.append(row) }
        return result
    }
}

private func booleanResponse(_ value: Bool) throws -> QueryExecuteOperation.Response {
    #if DATABASE_CLIENT_MULTI_BASE
    .boolean(try QueryBooleanResult(value: value, provenance: nil,
        consistency: .transactional(DomainReadPoint(domainID: "pages", position: .version(1)))))
    #else
    .boolean(value)
    #endif
}

private func graphPage(_ number: Int, continuation: ByteString? = nil, count: Int = 1) throws -> RDFGraphPage {
    let quad = RDFQuad(subject: .iri(try RDFIRI("urn:s\(number)")),
        predicate: RDFPredicateIRI(try RDFIRI("urn:p")), object: .iri(try RDFIRI("urn:o")))
    #if DATABASE_CLIENT_MULTI_BASE
    return try RDFGraphPage(quads: Array(repeating: quad, count: count), continuation: continuation, provenance: nil,
        consistency: .transactional(DomainReadPoint(domainID: "pages", position: .version(1))))
    #else
    return RDFGraphPage(quads: Array(repeating: quad, count: count), continuation: continuation, snapshotVersion: 1)
    #endif
}

private func page(_ value: Int32, name: String = "n", continuation: ByteString? = nil, count: Int = 1) throws -> QueryRowPage {
    let columns = [try QueryColumn(number: 1, name: name, type: .sql(.integer), isNullable: false)]
    #if DATABASE_CLIENT_MULTI_BASE
    return try QueryRowPage(columns: columns, rows: Array(repeating: QueryRow(values: [.primitive(.int32(value))]), count: count),
        continuation: continuation, consistency: .transactional(DomainReadPoint(domainID: "pages", position: .version(1))))
    #else
    return try QueryRowPage(columns: columns, rows: Array(repeating: QueryRow(values: [.primitive(.int32(value))]), count: count),
        continuation: continuation, snapshotVersion: 1)
    #endif
}

private struct QueryTestTransport: DatabaseTransport {
    let exchange: @Sendable (ByteString) async throws -> ByteString
    init(_ exchange: @escaping @Sendable (ByteString) async throws -> ByteString) { self.exchange = exchange }
    func send(_ request: ByteString) async throws(DatabaseTransportError) -> ByteString {
        do { return try await exchange(request) }
        catch let error as DatabaseTransportError { throw error }
        catch { throw .invalidResponse(String(describing: error)) }
    }
}

private actor QueryExchangeGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation; entered = true
            enteredWaiter?.resume(); enteredWaiter = nil
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() {
        releaseWaiter?.resume(); releaseWaiter = nil
    }
}
