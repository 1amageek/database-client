@testable import DatabaseClient
import DatabaseTypes
import DatabaseWire

func makeTestDatabaseCall<Request: Sendable, Response: Sendable>(
    operation: DatabaseOperation<Request, Response>,
    requestID: UInt64,
    metadata: OperationRequestMetadata = OperationRequestMetadata(),
    request: Request
) -> DatabaseCall<Request, Response> {
    #if DATABASE_CLIENT_MULTI_BASE
    DatabaseCall(
        operation: operation,
        requestID: requestID,
        target: .database,
        metadata: metadata,
        request: request
    )
    #else
    DatabaseCall(
        operation: operation,
        requestID: requestID,
        metadata: metadata,
        request: request
    )
    #endif
}

func executeTestDatabaseOperation<
    Transport: DatabaseTransport,
    Request: Sendable,
    Response: Sendable
>(
    client: DatabaseClient<Transport>,
    operation: DatabaseOperation<Request, Response>,
    request: Request,
    metadata: OperationRequestMetadata = OperationRequestMetadata()
) async throws(DatabaseClientError) -> Response {
    #if DATABASE_CLIENT_MULTI_BASE
    try await client.execute(
        operation,
        target: .database,
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

func makeTestJobIdentity(
    jobID: DatabaseTypes.UUID,
    operation: JobOperationIdentifier
) -> JobIdentity {
    #if DATABASE_CLIENT_MULTI_BASE
    JobIdentity(jobID: jobID, operation: operation, target: .database)
    #else
    JobIdentity(jobID: jobID, operation: operation)
    #endif
}

func makeTestJobResultDigestAccumulator(
    operation: JobOperationIdentifier
) -> JobResultDigestAccumulator {
    #if DATABASE_CLIENT_MULTI_BASE
    JobResultDigestAccumulator(operation: operation, target: .database)
    #else
    JobResultDigestAccumulator(operation: operation)
    #endif
}
