import DatabaseKit
public import DatabaseWire

/// Typed client invocation surface bound to one semantic database target.
///
/// Reusing this value for job status, result, and cancellation preserves the
/// exact target selected when the job was created.
public struct TargetedDatabaseClient<Transport: DatabaseTransport>: Sendable {
    public let target: DatabaseOperationTarget
    let client: DatabaseClient<Transport>
    var limits: DatabaseWireLimits { client.limits }

    init(
        client: DatabaseClient<Transport>,
        target: DatabaseOperationTarget
    ) {
        self.client = client
        self.target = target
    }

    public func execute<Request: Sendable, Response: Sendable>(
        _ operation: DatabaseOperation<Request, Response>,
        request: Request,
        metadata: OperationRequestMetadata = OperationRequestMetadata()
    ) async throws(DatabaseClientError) -> Response {
        try await client.execute(
            operation,
            target: target,
            request: request,
            metadata: metadata
        )
    }
}

public extension DatabaseClient {
    var database: TargetedDatabaseClient<Transport> {
        targeting(.database)
    }

    func base(_ id: Base.ID) -> TargetedDatabaseClient<Transport> {
        targeting(.base(id))
    }

    func composition(
        _ id: Base.Composition.ID
    ) -> TargetedDatabaseClient<Transport> {
        targeting(.composition(id))
    }

    func targeting(
        _ target: DatabaseOperationTarget
    ) -> TargetedDatabaseClient<Transport> {
        TargetedDatabaseClient(client: self, target: target)
    }
}
