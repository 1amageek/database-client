public import DatabaseTypes
public import DatabaseWire

public struct DatabaseCall<Request: Sendable, Response: Sendable>: Sendable {
    public let operation: DatabaseOperation<Request, Response>
    public let requestID: UInt64
    public let target: DatabaseOperationTarget
    public let metadata: OperationRequestMetadata
    public let request: Request

    public init(
        operation: DatabaseOperation<Request, Response>,
        requestID: UInt64,
        target: DatabaseOperationTarget,
        metadata: OperationRequestMetadata = OperationRequestMetadata(),
        request: Request
    ) {
        self.operation = operation
        self.requestID = requestID
        self.target = target
        self.metadata = metadata
        self.request = request
    }

    public func encode(
        limits: DatabaseWireLimits = .default
    ) throws(DatabaseCallError) -> ByteString {
        do {
            return try DatabaseWireEncoder(limits: limits).encodeRequest(
                operation,
                requestID: requestID,
                target: target,
                metadata: metadata,
                request: request,
            )
        } catch let error {
            throw .wire(error)
        }
    }

    public func decodeResponse(
        _ bytes: ByteString,
        limits: DatabaseWireLimits = .default
    ) throws(DatabaseCallError) -> Response {
        let result: Result<Response, RemoteOperationError>
        do {
            result = try DatabaseWireDecoder(limits: limits).decodeResponse(
                operation,
                from: bytes,
                matching: requestID
            )
        } catch let error {
            throw .wire(error)
        }
        switch result {
        case .success(let response):
            return response
        case .failure(let error):
            throw .remote(error)
        }
    }
}
