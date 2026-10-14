@testable import DatabaseClient
import DatabaseTypes
import DatabaseWire
import DatabaseKit

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

func makeTestQueryResponsePage() throws -> QueryRowPage {
    let json = try QueryJSONValue(
        bytes: ByteString(utf8: "{ \"key\":1.00 }"),
        limits: QueryValueLimits(maximumRetainedBytes: 4096, maximumTotalNodes: 100,
                                 maximumNestingDepth: 16, maximumCollectionElements: 100)
    )
    let numeric = try QueryNumericValue(value: ExactDecimal(coefficient: 1, scale: 0), displayScale: 2)
    let columns = [
        try QueryColumn(number: 1, name: "value", type: .sql(.json), isNullable: false),
        try QueryColumn(number: 2, name: "value", type: .sql(.decimal(precision: nil, scale: nil)), isNullable: false),
    ]
    let rows = [QueryRow(values: [.json(json), .numeric(numeric)])]
    #if DATABASE_CLIENT_MULTI_BASE
    return try QueryRowPage(columns: columns, rows: rows, provenance: nil,
                            consistency: .transactional(DomainReadPoint(domainID: "client-test", position: .version(1))))
    #else
    return try QueryRowPage(columns: columns, rows: rows)
    #endif
}
