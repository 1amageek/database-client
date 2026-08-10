import DatabaseTypes
public import DatabaseWire
import Synchronization

public final class DatabaseClient<Transport: DatabaseTransport>: Sendable {
    private let transport: Transport
    let limits: DatabaseWireLimits
    private let nextRequestID: Atomic<UInt64>

    public init(
        transport: Transport,
        limits: DatabaseWireLimits = .default
    ) {
        self.transport = transport
        self.limits = limits
        self.nextRequestID = Atomic(1)
    }

    init(
        transport: Transport,
        limits: DatabaseWireLimits = .default,
        firstRequestID: UInt64
    ) {
        precondition(firstRequestID > 0)
        self.transport = transport
        self.limits = limits
        self.nextRequestID = Atomic(firstRequestID)
    }

    public final func execute<Request: Sendable, Response: Sendable>(
        _ operation: DatabaseOperation<Request, Response>,
        target: DatabaseOperationTarget,
        request: Request,
        metadata: OperationRequestMetadata = OperationRequestMetadata()
    ) async throws(DatabaseClientError) -> Response {
        let requestID = try reserveRequestID()
        let call = DatabaseCall(
            operation: operation,
            requestID: requestID,
            target: target,
            metadata: metadata,
            request: request
        )

        let requestBytes: ByteString
        do {
            requestBytes = try call.encode(limits: limits)
        } catch let error {
            throw .call(error)
        }

        let responseBytes: ByteString
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

    private func reserveRequestID() throws(DatabaseClientError) -> UInt64 {
        var candidate = nextRequestID.load(ordering: .relaxed)
        while candidate != 0 {
            let successor = candidate == UInt64.max ? 0 : candidate + 1
            let reservation = nextRequestID.compareExchange(
                expected: candidate,
                desired: successor,
                ordering: .relaxed
            )
            if reservation.exchanged {
                return candidate
            }
            candidate = reservation.original
        }
        throw .requestIdentifierExhausted
    }
}
