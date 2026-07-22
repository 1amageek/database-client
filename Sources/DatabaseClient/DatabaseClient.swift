import DatabaseValue
public import DatabaseWire

public actor DatabaseClient<Transport: DatabaseTransport> {
    private let transport: Transport
    let limits: DatabaseWireLimits
    private var nextRequestID: UInt64

    public init(
        transport: Transport,
        limits: DatabaseWireLimits = .default,
        firstRequestID: UInt64 = 1
    ) {
        self.transport = transport
        self.limits = limits
        self.nextRequestID = firstRequestID
    }

    public func execute<Operation: DatabaseOperation>(
        _ operation: Operation.Type = Operation.self,
        request: Operation.Request,
        metadata: DatabaseRequestMetadata = DatabaseRequestMetadata()
    ) async throws(DatabaseClientError) -> Operation.Response {
        let requestID = reserveRequestID()
        let call = DatabaseCall<Operation>(
            requestID: requestID,
            metadata: metadata,
            request: request
        )

        let requestBytes: DatabaseBytes
        do {
            requestBytes = try call.encode(limits: limits)
        } catch let error {
            throw .call(error)
        }

        let responseBytes: DatabaseBytes
        do {
            responseBytes = try await transport.send(requestBytes)
        } catch let error {
            throw .transport(error)
        }

        do {
            return try call.decodeResponse(responseBytes, limits: limits)
        } catch let error {
            throw .call(error)
        }
    }

    private func reserveRequestID() -> UInt64 {
        let reservedRequestID = nextRequestID
        nextRequestID = nextRequestID == UInt64.max ? 0 : nextRequestID + 1
        return reservedRequestID
    }
}
