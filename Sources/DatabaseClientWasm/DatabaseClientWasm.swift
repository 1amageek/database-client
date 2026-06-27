import DatabaseKitWasmCore

/// Minimal Database client facade for WASM runtimes.
public struct DatabaseClientWasm<Transport: DatabaseClientWasmTransport>: Sendable {
    private let transport: Transport

    public init(transport: Transport) {
        self.transport = transport
    }

    public func applySchema(
        _ schema: DatabaseKitWasmSchema
    ) throws(DatabaseClientWasmError) {
        let response = try dispatch(.applySchema(schema))
        try expectEmpty(response)
    }

    public func putRecord(
        _ record: DatabaseKitWasmRecord
    ) throws(DatabaseClientWasmError) {
        let response = try dispatch(.putRecord(record))
        try expectEmpty(response)
    }

    public func getRecord(
        typeName: String,
        id: String
    ) throws(DatabaseClientWasmError) -> DatabaseKitWasmRecord? {
        let response = try dispatch(.getRecord(typeName: typeName, id: id))
        switch response {
        case .record(let record):
            return record
        case .failure(let status, let message):
            throw DatabaseClientWasmError.remoteFailure(status: status, message: message)
        case .empty, .records:
            throw DatabaseClientWasmError.unexpectedResponse(response)
        }
    }

    public func query(
        _ query: DatabaseKitWasmQueryRequest
    ) throws(DatabaseClientWasmError) -> [DatabaseKitWasmRecord] {
        let response = try dispatch(.query(query))
        switch response {
        case .records(let records):
            return records
        case .failure(let status, let message):
            throw DatabaseClientWasmError.remoteFailure(status: status, message: message)
        case .empty, .record:
            throw DatabaseClientWasmError.unexpectedResponse(response)
        }
    }

    private func dispatch(
        _ request: DatabaseKitWasmRequest
    ) throws(DatabaseClientWasmError) -> DatabaseKitWasmResponse {
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
    ) throws(DatabaseClientWasmError) {
        switch response {
        case .empty:
            return
        case .failure(let status, let message):
            throw DatabaseClientWasmError.remoteFailure(status: status, message: message)
        case .record, .records:
            throw DatabaseClientWasmError.unexpectedResponse(response)
        }
    }
}
