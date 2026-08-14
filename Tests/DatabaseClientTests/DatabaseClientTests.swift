@testable import DatabaseClient
import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Synchronization
import Testing

@Suite("DatabaseClient")
struct DatabaseClientTests {
    @Test("typed calls encode metadata and decode the matching response")
    func typedCallRoundTrips() async throws {
        let capturedIDs = Mutex<[UInt64]>([])
        #if DATABASE_CLIENT_MULTIPLE_BASES
        let capturedTargets = Mutex<[DatabaseOperationTarget]>([])
        #endif
        let transport = ScriptedDatabaseTransport {
            bytes throws(DatabaseTransportError) in
            let request = try decodeRequest(
                DatabaseOperationCatalog.capabilitiesDescribe,
                from: bytes
            )
            capturedIDs.withLock { $0.append(request.requestID) }
            #if DATABASE_CLIENT_MULTIPLE_BASES
            capturedTargets.withLock { $0.append(request.target) }
            #endif
            if request.requestID == 1 {
                #expect(request.metadata.traceID == "trace-a")
            } else {
                #expect(request.metadata.traceID == nil)
            }
            return try encodeResponse(
                DatabaseOperationCatalog.capabilitiesDescribe,
                requestID: request.requestID,
                response: capabilitiesResponse()
            )
        }
        let client = DatabaseClient(transport: transport)
        #if DATABASE_CLIENT_MULTIPLE_BASES
        let baseID = try Base.ID("company-a")
        let compositionID = try Base.Composition.ID("shared-world")

        let first = try await client.execute(
            DatabaseOperationCatalog.capabilitiesDescribe,
            target: .database,
            request: EmptyOperationPayload(),
            metadata: OperationRequestMetadata(traceID: "trace-a")
        )
        let second = try await client.base(baseID).execute(
            DatabaseOperationCatalog.capabilitiesDescribe,
            request: EmptyOperationPayload()
        )
        let third = try await client.composition(compositionID).execute(
            DatabaseOperationCatalog.capabilitiesDescribe,
            request: EmptyOperationPayload()
        )
        #else
        let first = try await executeTestDatabaseOperation(
            client: client,
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            request: EmptyOperationPayload(),
            metadata: OperationRequestMetadata(traceID: "trace-a")
        )
        let second = try await executeTestDatabaseOperation(
            client: client,
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            request: EmptyOperationPayload()
        )
        let third = try await client.database.execute(
            DatabaseOperationCatalog.capabilitiesDescribe,
            request: EmptyOperationPayload()
        )
        #endif

        #expect(first.runtimeVersion == "1")
        #expect(second.runtimeVersion == "1")
        #expect(third.runtimeVersion == "1")
        #expect(capturedIDs.withLock { $0 } == [1, 2, 3])
        #if DATABASE_CLIENT_MULTIPLE_BASES
        #expect(
            capturedTargets.withLock { $0 }
                == [
                    .database,
                    .base(baseID),
                    .composition(compositionID),
                ]
        )
        #endif
    }

    @Test("concurrent calls reserve unique identifiers without serializing transport I/O")
    func concurrentCallsRemainIndependent() async throws {
        let barrier = ConcurrentCallBarrier(participantCount: 2)
        let capturedIDs = Mutex<[UInt64]>([])
        let transport = ScriptedDatabaseTransport {
            bytes throws(DatabaseTransportError) in
            let request = try decodeRequest(
                DatabaseOperationCatalog.capabilitiesDescribe,
                from: bytes
            )
            capturedIDs.withLock { $0.append(request.requestID) }
            await barrier.arrive()
            return try encodeResponse(
                DatabaseOperationCatalog.capabilitiesDescribe,
                requestID: request.requestID,
                response: capabilitiesResponse()
            )
        }
        let client = DatabaseClient(transport: transport)

        async let first = executeTestDatabaseOperation(
            client: client,
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            request: EmptyOperationPayload()
        )
        async let second = executeTestDatabaseOperation(
            client: client,
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            request: EmptyOperationPayload()
        )
        let responses = try await [first, second]

        #expect(responses.allSatisfy { $0.runtimeVersion == "1" })
        #expect(capturedIDs.withLock { $0.sorted() } == [1, 2])
    }

    @Test("request identifier exhaustion is a typed client failure")
    func requestIdentifierExhaustionIsTyped() async throws {
        let transport = ScriptedDatabaseTransport {
            bytes throws(DatabaseTransportError) in
            let request = try decodeRequest(
                DatabaseOperationCatalog.capabilitiesDescribe,
                from: bytes
            )
            return try encodeResponse(
                DatabaseOperationCatalog.capabilitiesDescribe,
                requestID: request.requestID,
                response: capabilitiesResponse()
            )
        }
        let client = DatabaseClient(
            transport: transport,
            firstRequestID: UInt64.max
        )

        _ = try await executeTestDatabaseOperation(
            client: client,
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            request: EmptyOperationPayload()
        )
        await #expect(throws: DatabaseClientError.requestIdentifierExhausted) {
            _ = try await executeTestDatabaseOperation(
                client: client,
                operation: DatabaseOperationCatalog.capabilitiesDescribe,
                request: EmptyOperationPayload()
            )
        }
    }

    @Test("remote failures remain typed")
    func remoteFailureRemainsTyped() throws {
        let remoteError = RemoteOperationError(
            category: .authorization,
            code: "admin_required",
            message: "This operation requires the admin boundary",
            retryability: .never
        )
        let call = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.maintenanceExecute,
            requestID: 1,
            request: MaintenanceExecuteOperation.Request(
                invocation: .compact
            )
        )
        let response = try DatabaseWireEncoder().encodeFailure(
            requestID: 1,
            operation: .maintenanceExecute,
            error: remoteError
        )

        #expect(throws: DatabaseCallError.remote(remoteError)) {
            _ = try call.decodeResponse(response)
        }
    }

    @Test("transport failures remain distinct from call failures")
    func transportFailureRemainsTyped() async {
        let client = DatabaseClient(transport: TimeoutDatabaseTransport())

        await #expect(
            throws: DatabaseClientError.transport(.timeout)
        ) {
            _ = try await executeTestDatabaseOperation(
                client: client,
                operation: DatabaseOperationCatalog.capabilitiesDescribe,
                request: EmptyOperationPayload()
            )
        }
    }

    @Test("response correlation rejects a mismatched request identifier")
    func responseCorrelationRejectsMismatch() throws {
        let call = makeTestDatabaseCall(
            operation: DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 8,
            request: EmptyOperationPayload()
        )
        let response = try encodeResponse(
            DatabaseOperationCatalog.capabilitiesDescribe,
            requestID: 9,
            response: capabilitiesResponse()
        )

        #expect(
            throws: DatabaseCallError.wire(
                .unexpectedRequestIdentifier(expected: 8, actual: 9)
            )
        ) {
            _ = try call.decodeResponse(response)
        }
    }

    @Test("job lifecycle preserves the exact job identity")
    func jobLifecyclePreservesIdentity() async throws {
        let jobOperation = JobOperations.maintenance
        let job = makeTestJobIdentity(
            jobID: UUID(high: 0x1111, low: 0x2222),
            operation: jobOperation.identifier
        )
        let statusResponse = try JobStatusOperation.Response(
            state: .running,
            job: job,
            completedWorkUnits: 3,
            totalWorkUnits: 9,
            executionCount: 1,
            currentSliceAttempt: 1,
            updatedAt: Timestamp(
                secondsSinceUnixEpoch: 1_700_000_000
            )
        )
        let cancellationResponse = try JobCancelOperation.Response(
            job: job,
            state: .committingUnsuccessfulOutcome,
            accepted: true
        )
        let observedOperations = Mutex<[DatabaseOperationIdentifier]>([])
        let transport = ScriptedDatabaseTransport {
            bytes throws(DatabaseTransportError) in
            let envelope = try decodeEnvelope(bytes)
            observedOperations.withLock { $0.append(envelope.operation) }
            switch envelope.operation {
            case .jobStart:
                let request = try decodeRequest(
                    DatabaseOperationCatalog.jobStart,
                    from: bytes
                )
                #if DATABASE_CLIENT_MULTIPLE_BASES
                #expect(request.target == job.target)
                #endif
                #expect(request.request.maximumSliceWorkUnits == 17)
                #expect(request.request.operation == jobOperation.identifier)
                return try encodeResponse(
                    DatabaseOperationCatalog.jobStart,
                    requestID: request.requestID,
                    response: JobStartOperation.Response(job: job)
                )
            case .jobStatus:
                let request = try decodeRequest(
                    DatabaseOperationCatalog.jobStatus,
                    from: bytes
                )
                #if DATABASE_CLIENT_MULTIPLE_BASES
                #expect(request.target == job.target)
                #endif
                #expect(request.request.job == job)
                return try encodeResponse(
                    DatabaseOperationCatalog.jobStatus,
                    requestID: request.requestID,
                    response: statusResponse
                )
            case .jobCancel:
                let request = try decodeRequest(
                    DatabaseOperationCatalog.jobCancel,
                    from: bytes
                )
                #if DATABASE_CLIENT_MULTIPLE_BASES
                #expect(request.target == job.target)
                #endif
                #expect(request.request.job == job)
                return try encodeResponse(
                    DatabaseOperationCatalog.jobCancel,
                    requestID: request.requestID,
                    response: cancellationResponse
                )
            default:
                throw .invalidResponse(
                    "Unexpected job lifecycle operation"
                )
            }
        }
        let client = DatabaseClient(transport: transport)
        let database = client.database

        let started = try await database.startJob(
            jobOperation,
            request: MaintenanceExecuteOperation.Request(
                invocation: .compact
            ),
            maximumSliceWorkUnits: 17
        )
        let status = try await database.jobStatus(for: started)
        let cancelled = try await database.cancelJob(started)

        #expect(started == job)
        #expect(status.job == job)
        #expect(status.state == .running)
        #expect(cancelled.job == job)
        #expect(cancelled.accepted)
        #expect(
            observedOperations.withLock { $0 }
                == [.jobStart, .jobStatus, .jobCancel]
        )
    }

    #if DATABASE_CLIENT_MULTIPLE_BASES
    @Test("job lifecycle rejects a job from another target before transport")
    func jobLifecycleRejectsAnotherTarget() async throws {
        let baseID = try Base.ID("company-a")
        let job = JobIdentity(
            jobID: UUID(high: 0x9000, low: 0x0001),
            operation: JobOperations.maintenance.identifier,
            target: .base(baseID)
        )
        let transportInvocations = Mutex(0)
        let transport = ScriptedDatabaseTransport {
            _ throws(DatabaseTransportError) in
            transportInvocations.withLock { $0 += 1 }
            throw .invalidResponse("Transport must not be called")
        }
        let database = DatabaseClient(transport: transport).database
        let expectedJob = JobIdentity(
            jobID: job.jobID,
            operation: job.operation,
            target: .database
        )

        await #expect(
            throws: DatabaseClientError.jobLifecycle(
                .mismatchedJob(expected: expectedJob, actual: job)
            )
        ) {
            _ = try await database.jobStatus(for: job)
        }
        #expect(transportInvocations.withLock { $0 } == 0)
    }
    #endif

    @Test("paged job results verify integrity and decode the original response")
    func pagedJobResultDecodesOriginalResponse() async throws {
        let jobOperation = JobOperations.maintenance
        let job = makeTestJobIdentity(
            jobID: UUID(high: 0x1020, low: 0x3040),
            operation: jobOperation.identifier
        )
        let originalResponse = MaintenanceExecuteOperation.Response.execution(
            MaintenanceExecuteOperation.ExecutionResult(
                kind: .compaction,
                completedWorkUnits: 9,
                commitVersion: 42,
                isComplete: true
            )
        )
        let payload = try DatabaseWireEncoder()
            .encodeResponseAndPayload(
                DatabaseOperationCatalog.maintenanceExecute,
                requestID: 0,
                response: originalResponse
            )
            .payload
        let boundaries = [0, 3, payload.count / 2, payload.count]
        let pages = (0..<(boundaries.count - 1)).map { index in
            let lowerBound = payload.startIndex + boundaries[index]
            let upperBound = payload.startIndex + boundaries[index + 1]
            return payload[lowerBound..<upperBound]
        }
        var accumulator = makeTestJobResultDigestAccumulator(
            operation: job.operation
        )
        accumulator.update(payload)
        let digest = accumulator.finalize()
        let capturedRequestIDs = Mutex<[UInt64]>([])
        let transport = ScriptedDatabaseTransport {
            bytes throws(DatabaseTransportError) in
            let request = try decodeRequest(
                DatabaseOperationCatalog.jobResult,
                from: bytes
            )
            capturedRequestIDs.withLock { $0.append(request.requestID) }
            guard request.request.job == job else {
                throw .invalidResponse("Unexpected job identifier")
            }
            let pageIndex = Int(
                request.request.continuation?.nextChunkIndex ?? 0
            )
            guard pageIndex < pages.count else {
                throw .invalidResponse("Unexpected result page")
            }
            let continuation = pageIndex + 1 < pages.count
                ? try makeContinuation(
                    job: job,
                    responseDigest: digest,
                    nextChunkIndex: UInt32(pageIndex + 1)
                )
                : nil
            return try encodeResponse(
                DatabaseOperationCatalog.jobResult,
                requestID: request.requestID,
                response: .succeeded(
                    job: job,
                    responsePayloadPage: pages[pageIndex],
                    totalResponseBytes: UInt64(payload.count),
                    responseDigest: digest,
                    continuation: continuation
                )
            )
        }
        let client = DatabaseClient(transport: transport)
        let database = client.database

        let decoded = try await database.jobResult(
            for: job,
            using: jobOperation
        )

        guard case .execution(let result) = decoded else {
            Issue.record("Expected a maintenance execution result")
            return
        }
        #expect(result.kind == .compaction)
        #expect(result.completedWorkUnits == 9)
        #expect(result.commitVersion == 42)
        #expect(result.isComplete)
        #expect(capturedRequestIDs.withLock { $0 } == [1, 2, 3])
    }

    @Test("paged job results reject a mismatched digest")
    func pagedJobResultRejectsDigestMismatch() async throws {
        let jobOperation = JobOperations.maintenance
        let job = makeTestJobIdentity(
            jobID: UUID(high: 0x5060, low: 0x7080),
            operation: jobOperation.identifier
        )
        let originalResponse = MaintenanceExecuteOperation.Response.execution(
            MaintenanceExecuteOperation.ExecutionResult(
                kind: .compaction,
                completedWorkUnits: 1,
                isComplete: true
            )
        )
        let payload = try DatabaseWireEncoder()
            .encodeResponseAndPayload(
                DatabaseOperationCatalog.maintenanceExecute,
                requestID: 0,
                response: originalResponse
            )
            .payload
        let incorrectDigest = try JobResultDigest(
            [UInt8](repeating: 0, count: JobResultDigest.byteCount)
        )
        let transport = ScriptedDatabaseTransport {
            bytes throws(DatabaseTransportError) in
            let request = try decodeRequest(
                DatabaseOperationCatalog.jobResult,
                from: bytes
            )
            return try encodeResponse(
                DatabaseOperationCatalog.jobResult,
                requestID: request.requestID,
                response: .succeeded(
                    job: job,
                    responsePayloadPage: payload,
                    totalResponseBytes: UInt64(payload.count),
                    responseDigest: incorrectDigest,
                    continuation: nil
                )
            )
        }
        let client = DatabaseClient(transport: transport)
        let database = client.database
        var actualDigestAccumulator = makeTestJobResultDigestAccumulator(
            operation: job.operation
        )
        actualDigestAccumulator.update(payload)
        let actualDigest = actualDigestAccumulator.finalize()

        await #expect(
            throws: DatabaseClientError.jobResult(
                .digestMismatch(
                    expected: incorrectDigest,
                    actual: actualDigest
                )
            )
        ) {
            _ = try await database.jobResult(
                for: job,
                using: jobOperation
            )
        }
    }
}

private struct TimeoutDatabaseTransport: DatabaseTransport {
    func send(
        _ request: ByteString
    ) async throws(DatabaseTransportError) -> ByteString {
        throw .timeout
    }
}

private struct ScriptedDatabaseTransport: DatabaseTransport {
    let responseProvider:
        @Sendable (ByteString)
            async throws(DatabaseTransportError) -> ByteString

    init(
        responseProvider:
            @escaping @Sendable (ByteString)
                async throws(DatabaseTransportError) -> ByteString
    ) {
        self.responseProvider = responseProvider
    }

    func send(
        _ request: ByteString
    ) async throws(DatabaseTransportError) -> ByteString {
        try await responseProvider(request)
    }
}

private actor ConcurrentCallBarrier {
    private let participantCount: Int
    private var arrivalCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        precondition(participantCount > 0)
        self.participantCount = participantCount
    }

    func arrive() async {
        arrivalCount += 1
        if arrivalCount == participantCount {
            let waiters = self.waiters
            self.waiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private func capabilitiesResponse()
    -> CapabilitiesDescribeOperation.Response {
    CapabilitiesDescribeOperation.Response(
        runtimeVersion: "1",
        features: [
            .init(identifier: "graph.sparql", version: 1),
        ],
        jobOperations: []
    )
}

private func decodeEnvelope(
    _ bytes: ByteString
) throws(DatabaseTransportError) -> DatabaseWireRequestEnvelope {
    do {
        return try DatabaseWireDecoder().decodeRequestEnvelope(bytes)
    } catch let error {
        throw .invalidResponse(String(describing: error))
    }
}

private func decodeRequest<Request: Sendable, Response: Sendable>(
    _ operation: DatabaseOperation<Request, Response>,
    from bytes: ByteString
) throws(DatabaseTransportError) -> DecodedOperationRequest<Request> {
    do {
        return try DatabaseWireDecoder().decodeRequest(
            operation,
            from: bytes
        )
    } catch let error {
        throw .invalidResponse(String(describing: error))
    }
}

private func encodeResponse<Request: Sendable, Response: Sendable>(
    _ operation: DatabaseOperation<Request, Response>,
    requestID: UInt64,
    response: Response
) throws(DatabaseTransportError) -> ByteString {
    do {
        return try DatabaseWireEncoder().encodeResponse(
            operation,
            requestID: requestID,
            response: response
        )
    } catch let error {
        throw .invalidResponse(String(describing: error))
    }
}

private func makeContinuation(
    job: JobIdentity,
    responseDigest: JobResultDigest,
    nextChunkIndex: UInt32
) throws(DatabaseTransportError) -> JobResultOperation.Continuation {
    do {
        return try JobResultOperation.Continuation(
            job: job,
            responseDigest: responseDigest,
            nextChunkIndex: nextChunkIndex
        )
    } catch let error {
        throw .invalidResponse(String(describing: error))
    }
}
