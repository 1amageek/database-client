import DatabaseAccess
import DatabaseClient
import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Testing

@Suite("Common access result carriers", .timeLimit(.minutes(1)))
struct AccessResultTests {
    @Test("Retained rich rows preserve duplicate columns and canonical values")
    func localRichRows() async throws {
        let original = try makeTestQueryResponsePage()
        let stream = try RowStream(page: original)
        #expect(stream.columns == original.columns)
        #expect(stream.metadata == original.metadata)
        #expect(stream.affectedRows == original.affectedRows)
        #expect(try await values(stream) == original.materializedRows(maximumCount: 1))
    }

    @Test("Independent and copied value iterators do not share progress")
    func iteratorCopies() async throws {
        let stream = try RowStream(page: page(7, count: 2))
        var first = stream.makeAsyncIterator()
        var copied = first
        var independent = stream.makeAsyncIterator()
        #expect(try await first.next() == copied.next())
        #expect(try await first.next() == independent.next())
        #expect(try await first.next() == nil)
        #expect(try await copied.next() != nil)
        #expect(try await independent.next() != nil)
    }

    @Test("Page views retain original schema and read metadata")
    func pageIdentity() async throws {
        let original = try page(9)
        let stream = try RowStream(page: original)
        var iterator = stream.pages.makeAsyncIterator()
        let retained = try #require(try await iterator.next())
        #expect(retained.columns == original.columns)
        #expect(retained.metadata == original.metadata)
        #expect(retained.rowCount == original.rowCount)
        #if DATABASE_CLIENT_MULTI_BASE
        #expect(retained.consistency == original.consistency)
        #else
        #expect(retained.snapshotVersion == original.snapshotVersion)
        #endif
        #expect(try await iterator.next() == nil)
    }

    @Test("Incomplete direct pages are typed failures rather than truncated success")
    func incompletePages() throws {
        #expect(throws: StreamAdaptationError.missingPageSource) {
            try RowStream(page: page(1, continuation: ByteString([1])))
        }
        #expect(throws: StreamAdaptationError.missingPageSource) {
            try GraphStream(page: graphPage(1, continuation: ByteString([1])))
        }
    }

    @Test("Graph values and original pages retain independent cursors")
    func graphRows() async throws {
        let original = try graphPage(1, count: 2)
        let stream = try GraphStream(page: original)
        var first = stream.makeAsyncIterator()
        var second = stream.makeAsyncIterator()
        #expect(try await first.next() == second.next())
        #expect(try await first.next() != nil)
        #expect(try await first.next() == nil)
        #expect(try await second.next() != nil)
        var pages = stream.pages.makeAsyncIterator()
        #expect(try await pages.next()?.quadCount == 2)
        #expect(try await pages.next() == nil)
    }

    @Test("Empty carriers terminate without synthetic rows or graph values")
    func emptySequences() async throws {
        var rows = RowStream.empty.makeAsyncIterator()
        #expect(try await rows.next() == nil)
        #expect(try await rows.next() == nil)
        let emptyGraph = try GraphStream(page: graphPage(1, count: 0))
        var graph = emptyGraph.makeAsyncIterator()
        #expect(try await graph.next() == nil)
    }

    @Test("Actual Client row and graph streams preserve checked pagination")
    func remotePages() async throws {
        let transport = QueryTestTransport { bytes in
            let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
            let response = QueryExecuteOperation.Response.rows(try page(request.request.page?.continuation == nil ? 1 : 2,
                continuation: request.request.page?.continuation == nil ? ByteString([1]) : nil))
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                requestID: request.requestID, response: response)
        }
        let connection = try await DatabaseClient(transport: transport).openConnection()
        defer { await connection.close() }
        guard case .rows(let original) = try await connection.execute("SELECT n", options: .init(pageSize: 1)) else {
            Issue.record("Expected rows"); return
        }
        let stream = RowStream(original)
        #expect(try await values(stream).map(\.values) == [[.primitive(.int32(1))], [.primitive(.int32(2))]])
        var pages = stream.pages.makeAsyncIterator()
        #expect(try await pages.next()?.continuation == ByteString([1]))
        #expect(try await pages.next()?.continuation == nil)
        #expect(try await pages.next() == nil)
        let graphTransport = QueryTestTransport { bytes in
            let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                requestID: request.requestID, response: .rdfGraph(try graphPage(
                    request.request.page?.continuation == nil ? 1 : 2,
                    continuation: request.request.page?.continuation == nil ? ByteString([1]) : nil)))
        }
        let graphConnection = try await DatabaseClient(transport: graphTransport).openConnection()
        defer { await graphConnection.close() }
        guard case .rdfGraph(let originalGraph) = try await graphConnection.execute("SELECT graph", options: .init(pageSize: 1)) else {
            Issue.record("Expected graph"); return
        }
        let graphStream = GraphStream(originalGraph)
        var quads = graphStream.makeAsyncIterator()
        #expect(try await quads.next() != nil)
        #expect(try await quads.next() != nil)
        #expect(try await quads.next() == nil)
        var graphPages = graphStream.pages.makeAsyncIterator()
        #expect(try await graphPages.next()?.continuation == ByteString([1]))
        #expect(try await graphPages.next()?.continuation == nil)
        #expect(try await graphPages.next() == nil)
    }

    @Test("Underlying schema failures remain terminal typed failures")
    func terminalPageFailure() async throws {
        let transport = QueryTestTransport { bytes in
            let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                requestID: request.requestID, response: .rows(try page(1,
                    name: request.request.page?.continuation == nil ? "n" : "changed",
                    continuation: request.request.page?.continuation == nil ? ByteString([1]) : nil)))
        }
        let connection = try await DatabaseClient(transport: transport).openConnection()
        defer { await connection.close() }
        guard case .rows(let original) = try await connection.execute("SELECT n", options: .init(pageSize: 1)) else {
            Issue.record("Expected rows"); return
        }
        var iterator = RowStream(original).makeAsyncIterator()
        #expect(try await iterator.next() != nil)
        await #expect(throws: QueryStreamError.changedColumns) { try await iterator.next() }
        #expect(try await iterator.next() == nil)
    }

    @Test("Closing before continuation keeps retained values and rejects further I/O")
    func closeContinuation() async throws {
        let transport = QueryTestTransport { bytes in
            let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                requestID: request.requestID, response: .rows(try page(1, continuation: ByteString([1]))))
        }
        let connection = try await DatabaseClient(transport: transport).openConnection()
        defer { await connection.close() }
        guard case .rows(let original) = try await connection.execute("SELECT n", options: .init(pageSize: 1)) else {
            Issue.record("Expected rows"); return
        }
        var iterator = RowStream(original).makeAsyncIterator()
        await connection.close()
        #expect(try await iterator.next()?.values == [.primitive(.int32(1))])
        await #expect(throws: QueryConnectionError.closed) { try await iterator.next() }
        #expect(try await iterator.next() == nil)
    }

    @Test("All result kinds retain their distinct outcomes and ordered block members")
    func resultKinds() async throws {
        let rows = try RowStream(page: page(1))
        let graph = try GraphStream(page: graphPage(1))
        #if DATABASE_CLIENT_MULTI_BASE
        let truth = try QueryBooleanResult(value: true, provenance: nil,
            consistency: .transactional(DomainReadPoint(domainID: "pages", position: .version(1))))
        #else
        let truth = true
        #endif
        let result = AccessResult.block([.rows(rows), .command(.update, affectedRows: 2),
            .copy(bytes: ByteString([0, 255]), affectedRows: 1), .boolean(truth), .rdfGraph(graph)])
        #expect(result.results.count == 5)
        #expect(result.results[1].affectedRows == 2)
        #expect(try await values(result.results[1].rows).isEmpty)
        guard case .copy(let bytes, let count) = result.results[2], case .boolean(let value) = result.results[3] else {
            Issue.record("Expected original result kinds"); return
        }
        #expect(bytes == ByteString([0, 255]) && count == 1 && value.value)
    }

    private func values<Rows: QueryRows>(_ rows: Rows) async throws -> [QueryRow] {
        var values: [QueryRow] = []
        for try await row in rows { values.append(row) }
        return values
    }
}
