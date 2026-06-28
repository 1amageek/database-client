import DatabaseKitWasmCore

/// Minimal Database client facade for wire runtimes.
public struct DatabaseClient<Transport: DatabaseClientTransport>: Sendable {
    private let transport: Transport

    public init(transport: Transport) {
        self.transport = transport
    }

    public func applySchema(
        _ schema: DatabaseKitWasmSchema
    ) throws(DatabaseClientError) {
        let response = try dispatch(.applySchema(schema))
        try expectEmpty(response)
    }

    public func putRecord(
        _ record: DatabaseKitWasmRecord
    ) throws(DatabaseClientError) {
        let response = try dispatch(.putRecord(record))
        try expectEmpty(response)
    }

    public func getRecord(
        typeName: String,
        id: String
    ) throws(DatabaseClientError) -> DatabaseKitWasmRecord? {
        let response = try dispatch(.getRecord(typeName: typeName, id: id))
        switch response {
        case .record(let record):
            return record
        case .failure(let status, let message):
            throw DatabaseClientError.remoteFailure(status: status, message: message)
        case .empty, .records:
            throw DatabaseClientError.unexpectedResponse(response)
        }
    }

    public func query(
        _ query: DatabaseKitWasmQueryRequest
    ) throws(DatabaseClientError) -> [DatabaseKitWasmRecord] {
        let response = try dispatch(.query(query))
        switch response {
        case .records(let records):
            return records
        case .failure(let status, let message):
            throw DatabaseClientError.remoteFailure(status: status, message: message)
        case .empty, .record:
            throw DatabaseClientError.unexpectedResponse(response)
        }
    }

    private func dispatch(
        _ request: DatabaseKitWasmRequest
    ) throws(DatabaseClientError) -> DatabaseKitWasmResponse {
        let requestBytes: [UInt8]
        do {
            requestBytes = try DatabaseKitWasmCodec.encode(request: request)
        } catch {
            throw .wire(error)
        }
        let responseBytes = try transport.send(requestBytes)
        do {
            return try DatabaseKitWasmCodec.decodeResponse(responseBytes)
        } catch {
            throw .wire(error)
        }
    }

    private func expectEmpty(
        _ response: DatabaseKitWasmResponse
    ) throws(DatabaseClientError) {
        switch response {
        case .empty:
            return
        case .failure(let status, let message):
            throw DatabaseClientError.remoteFailure(status: status, message: message)
        case .record, .records:
            throw DatabaseClientError.unexpectedResponse(response)
        }
    }
}
