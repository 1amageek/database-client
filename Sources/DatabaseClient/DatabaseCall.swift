public import DatabaseTypes
public import DatabaseWire

public struct DatabaseCall<Request: Sendable, Response: Sendable>: Sendable {
    public let operation: DatabaseOperation<Request, Response>
    public let requestID: UInt64
    #if DATABASE_CLIENT_MULTI_BASE
    public let target: DatabaseOperationTarget
    #endif
    public let metadata: OperationRequestMetadata
    public let request: Request

    #if DATABASE_CLIENT_MULTI_BASE
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
    #else
    public init(
        operation: DatabaseOperation<Request, Response>,
        requestID: UInt64,
        metadata: OperationRequestMetadata = OperationRequestMetadata(),
        request: Request
    ) {
        self.operation = operation
        self.requestID = requestID
        self.metadata = metadata
        self.request = request
    }
    #endif

    public func encode(
        limits: DatabaseWireLimits = .default
    ) throws(DatabaseCallError) -> ByteString {
        do {
            #if DATABASE_CLIENT_MULTI_BASE
            return try DatabaseWireEncoder(limits: limits).encodeRequest(
                operation,
                requestID: requestID,
                target: target,
                metadata: metadata,
                request: request,
            )
            #else
            return try DatabaseWireEncoder(limits: limits).encodeRequest(
                operation,
                requestID: requestID,
                metadata: metadata,
                request: request,
            )
            #endif
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
