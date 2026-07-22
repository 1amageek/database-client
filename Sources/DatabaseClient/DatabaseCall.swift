public import DatabaseValue
public import DatabaseWire

public struct DatabaseCall<Operation: DatabaseOperation>: Sendable {
    public let requestID: UInt64
    public let metadata: DatabaseRequestMetadata
    public let request: Operation.Request

    public init(
        requestID: UInt64,
        metadata: DatabaseRequestMetadata = DatabaseRequestMetadata(),
        request: Operation.Request
    ) {
        self.requestID = requestID
        self.metadata = metadata
        self.request = request
    }

    public func encode(
        limits: DatabaseWireLimits = .default
    ) throws(DatabaseCallError) -> DatabaseBytes {
        do {
            return try DatabaseEnvelopeCodec.encodeRequest(
                Operation.self,
                requestID: requestID,
                metadata: metadata,
                request: request,
                limits: limits
            )
        } catch let error {
            throw .wire(error)
        }
    }

    public func decodeResponse(
        _ bytes: DatabaseBytes,
        limits: DatabaseWireLimits = .default
    ) throws(DatabaseCallError) -> Operation.Response {
        let envelope: DatabaseWireResponseEnvelope
        do {
            envelope = try DatabaseEnvelopeCodec.decodeResponse(bytes, limits: limits)
        } catch let error {
            throw .wire(error)
        }

        guard envelope.requestID == requestID else {
            throw .mismatchedRequestID(expected: requestID, actual: envelope.requestID)
        }
        guard envelope.operation == Operation.identifier else {
            throw .mismatchedOperation(expected: Operation.identifier, actual: envelope.operation)
        }

        switch envelope.payload {
        case .failure(let error):
            throw .remote(error)
        case .success(let payload):
            do {
                return try DatabaseEnvelopeCodec.decode(
                    Operation.Response.self,
                    from: payload,
                    limits: limits
                )
            } catch let error {
                throw .wire(error)
            }
        }
    }
}
