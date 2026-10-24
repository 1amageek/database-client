import DatabaseClient
import DatabaseKit
import DatabaseTypes
import DatabaseWire

/// Fixture bytes exercise the real client, codec and continuation consumers.
public struct AccessRuntimeTransport: DatabaseTransport {
    enum Mode: Sendable { case rows, graph, changedColumns }
    let mode: Mode

    public func send(_ bytes: ByteString) async throws(DatabaseTransportError) -> ByteString {
        do {
            let request = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
            let first = request.request.page?.continuation == nil
            let response: QueryExecuteOperation.Response
            switch mode {
            case .rows, .changedColumns:
                response = .rows(try Self.page(first ? 1 : 2, continuation: first ? ByteString([1]) : nil,
                    name: mode == .changedColumns && !first ? "changed" : "n"))
            case .graph:
                response = .rdfGraph(try Self.graph(first ? 1 : 2, continuation: first ? ByteString([1]) : nil))
            }
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                requestID: request.requestID, response: response)
        } catch { throw .invalidResponse("Access runtime fixture failed") }
    }

    static func page(_ value: Int32, continuation: ByteString?, name: String = "n") throws -> QueryRowPage {
        let columns = [try QueryColumn(number: 1, name: name, type: .sql(.integer), isNullable: false)]
        #if DATABASE_CLIENT_MULTI_BASE
        return try QueryRowPage(columns: columns, rows: [QueryRow(values: [.primitive(.int32(value))])],
            continuation: continuation, consistency: .transactional(DomainReadPoint(domainID: "access", position: .version(1))))
        #else
        return try QueryRowPage(columns: columns, rows: [QueryRow(values: [.primitive(.int32(value))])],
            continuation: continuation, snapshotVersion: 1)
        #endif
    }

    static func graph(_ value: Int32, continuation: ByteString?) throws -> RDFGraphPage {
        let quad = RDFQuad(subject: .iri(try RDFIRI("urn:s\(value)")),
            predicate: RDFPredicateIRI(try RDFIRI("urn:p")), object: .iri(try RDFIRI("urn:o")))
        #if DATABASE_CLIENT_MULTI_BASE
        return try RDFGraphPage(quads: [quad], continuation: continuation, provenance: nil,
            consistency: .transactional(DomainReadPoint(domainID: "access", position: .version(1))))
        #else
        return RDFGraphPage(quads: [quad], continuation: continuation, snapshotVersion: 1)
        #endif
    }
}
