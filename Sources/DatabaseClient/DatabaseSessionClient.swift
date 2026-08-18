import DatabaseKit
public import DatabaseWire

/// Typed client invocation surface bound to one database session.
///
/// Reusing this value for job status, result, and cancellation preserves the
/// exact target selected when the job was created.
public struct DatabaseSessionClient<Transport: DatabaseTransport>: Sendable {
    #if DATABASE_CLIENT_MULTIPLE_BASES
    public let target: DatabaseOperationTarget
    #endif
    let client: DatabaseClient<Transport>
    var limits: DatabaseWireLimits { client.limits }

    #if DATABASE_CLIENT_MULTIPLE_BASES
    init(
        client: DatabaseClient<Transport>,
        target: DatabaseOperationTarget
    ) {
        self.client = client
        self.target = target
    }
    #else
    init(client: DatabaseClient<Transport>) {
        self.client = client
    }
    #endif

    public func execute<Request: Sendable, Response: Sendable>(
        _ operation: DatabaseOperation<Request, Response>,
        request: Request,
        metadata: OperationRequestMetadata = OperationRequestMetadata()
    ) async throws(DatabaseClientError) -> Response {
        #if DATABASE_CLIENT_MULTIPLE_BASES
        try await client.execute(
            operation,
            target: target,
            request: request,
            metadata: metadata
        )
        #else
        try await client.execute(
            operation,
            request: request,
            metadata: metadata
        )
        #endif
    }
}

public extension DatabaseClient {
    var database: DatabaseSessionClient<Transport> {
        #if DATABASE_CLIENT_MULTIPLE_BASES
        targeting(.database)
        #else
        DatabaseSessionClient(client: self)
        #endif
    }

    #if DATABASE_CLIENT_MULTIPLE_BASES
    func base(_ id: Base.ID) -> DatabaseSessionClient<Transport> {
        targeting(.base(id))
    }

    func composition(
        _ id: Base.Composition.ID
    ) -> DatabaseSessionClient<Transport> {
        targeting(.composition(.named(id)))
    }

    func composition(
        bases: [Base.ID]
    ) throws(BaseCompositionError) -> DatabaseSessionClient<Transport> {
        targeting(.composition(try .derived(bases)))
    }

    func targeting(
        _ target: DatabaseOperationTarget
    ) -> DatabaseSessionClient<Transport> {
        DatabaseSessionClient(client: self, target: target)
    }
    #endif
}
