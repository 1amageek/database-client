import DatabaseWire

/// Minimal Database client facade for wire runtimes.
public struct WireClient<Remote: WireTransport>: Sendable {
    private let transport: Remote

    public init(transport: Remote) {
        self.transport = transport
    }

    public func applySchema(
        _ schema: DatabaseWireSchema
    ) throws(ClientError) {
        let response = try dispatch(.applySchema(schema))
        try expectEmpty(response)
    }

    public func putRecord(
        _ record: DatabaseWireRecord
    ) throws(ClientError) {
        let response = try dispatch(.putRecord(record))
        try expectEmpty(response)
    }

    public func getRecord(
        typeName: String,
        id: String
    ) throws(ClientError) -> DatabaseWireRecord? {
        let response = try dispatch(.getRecord(typeName: typeName, id: id))
        switch response {
        case .record(let record):
            return record
        case .failure(let status, let message):
            throw ClientError.remoteFailure(status: status, message: message)
        case .empty, .records:
            throw ClientError.unexpectedResponse(response)
        }
    }

    public func query(
        _ query: DatabaseWireQueryRequest
    ) throws(ClientError) -> [DatabaseWireRecord] {
        let response = try dispatch(.query(query))
        switch response {
        case .records(let records):
            return records
        case .failure(let status, let message):
            throw ClientError.remoteFailure(status: status, message: message)
        case .empty, .record:
            throw ClientError.unexpectedResponse(response)
        }
    }

    private func dispatch(
        _ request: DatabaseWireRequest
    ) throws(ClientError) -> DatabaseWireResponse {
        let requestBytes: [UInt8]
        do {
            requestBytes = try DatabaseWireCodec.encode(request: request)
        } catch {
            throw .wire(error)
        }
        let responseBytes = try transport.send(requestBytes)
        do {
            return try DatabaseWireCodec.decodeResponse(responseBytes)
        } catch {
            throw .wire(error)
        }
    }

    private func expectEmpty(
        _ response: DatabaseWireResponse
    ) throws(ClientError) {
        switch response {
        case .empty:
            return
        case .failure(let status, let message):
            throw ClientError.remoteFailure(status: status, message: message)
        case .record, .records:
            throw ClientError.unexpectedResponse(response)
        }
    }
}
