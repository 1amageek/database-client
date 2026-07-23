import DatabaseClient
import DatabaseValue
import DatabaseWire
import Synchronization
import Testing

@Suite("DatabaseClient")
struct DatabaseClientTests {
    @Test("typed calls encode operation metadata and decode the matching response")
    func typedCallRoundTrips() async throws {
        let capturedIDs = Mutex<[UInt64]>([])
        let transport = ScriptedDatabaseTransport { bytes throws(DatabaseTransportError) in
            let request = try decodeRequest(bytes)
            capturedIDs.withLock { $0.append(request.requestID) }
            #expect(request.operation == .capabilitiesDescribe)
            if request.requestID == 41 {
                #expect(request.metadata.traceID == "trace-a")
            } else {
                #expect(request.metadata.traceID == nil)
            }

            let payload = try encodeWire(
                CapabilitiesDescribeOperation.Response(
                    runtimeVersion: "26.0716.0",
                    features: [
                        CapabilitiesDescribeOperation.Feature(
                            identifier: "graph.sparql",
                            version: 1
                        ),
                    ],
                    jobOperations: []
                )
            )
            return try encodeWire(
                response: DatabaseWireResponseEnvelope(
                    requestID: request.requestID,
                    operation: request.operation,
                    payload: .success(payload)
                )
            )
        }
        let client = DatabaseClient(transport: transport, firstRequestID: 41)

        let first = try await client.execute(
            CapabilitiesDescribeOperation.self,
            request: DatabaseEmpty(),
            metadata: DatabaseRequestMetadata(traceID: "trace-a")
        )
        let second = try await client.execute(
            CapabilitiesDescribeOperation.self,
            request: DatabaseEmpty()
        )

        #expect(first.runtimeVersion == "26.0716.0")
        #expect(first.features.first?.identifier == "graph.sparql")
        #expect(second == first)
        #expect(capturedIDs.withLock { $0 } == [41, 42])
    }

    @Test("concurrent calls reserve unique identifiers without serializing transport I/O")
    func concurrentCallsRemainIndependent() async throws {
        let barrier = ConcurrentCallBarrier(participantCount: 2)
        let capturedIDs = Mutex<[UInt64]>([])
        let transport = ScriptedDatabaseTransport {
            requestBytes throws(DatabaseTransportError) in
            let request = try decodeRequest(requestBytes)
            capturedIDs.withLock { $0.append(request.requestID) }
            await barrier.arrive()
            let payload = try encodeWire(
                CapabilitiesDescribeOperation.Response(
                    runtimeVersion: "1",
                    features: [],
                    jobOperations: []
                )
            )
            return try encodeWire(
                response: DatabaseWireResponseEnvelope(
                    requestID: request.requestID,
                    operation: request.operation,
                    payload: .success(payload)
                )
            )
        }
        let client = DatabaseClient(
            transport: transport,
            firstRequestID: 100
        )

        async let first = client.execute(
            CapabilitiesDescribeOperation.self,
            request: DatabaseEmpty()
        )
        async let second = client.execute(
            CapabilitiesDescribeOperation.self,
            request: DatabaseEmpty()
        )
        let responses = try await [first, second]

        #expect(responses.allSatisfy { $0.runtimeVersion == "1" })
        #expect(capturedIDs.withLock { $0.sorted() } == [100, 101])
    }

    @Test("a remote failure remains typed")
    func remoteFailureRemainsTyped() throws {
        let remoteError = DatabaseRemoteError(
            category: .authorization,
            code: "admin_required",
            message: "This operation requires the admin boundary",
            retryability: .never
        )
        let call = DatabaseCall<MaintenanceExecuteOperation>(
            requestID: 1,
            request: MaintenanceExecuteOperation.Request(invocation: .compact)
        )
        let response = try DatabaseEnvelopeCodec.encode(
            response: DatabaseWireResponseEnvelope(
                requestID: 1,
                operation: .maintenanceExecute,
                payload: .failure(remoteError)
            )
        )

        #expect(throws: DatabaseCallError.remote(remoteError)) {
            _ = try call.decodeResponse(response)
        }
    }

    @Test("typed job lifecycle preserves the exact job identity")
    func typedJobLifecyclePreservesIdentity() async throws {
        let job = DatabaseJobIdentity(
            jobID: DatabaseUUID(high: 0x1111, low: 0x2222),
            operation: try CapabilitiesSnapshotJob.jobOperationIdentifier()
        )
        let statusPayload = try encodeWire(
            try JobStatusOperation.Response(
                state: .running,
                job: job,
                completedWorkUnits: 3,
                totalWorkUnits: 9,
                executionCount: 1,
                currentSliceAttempt: 1,
                updatedAt: DatabaseTimestamp(
                    secondsSinceUnixEpoch: 1_700_000_000
                )
            )
        )
        let cancellationPayload = try encodeWire(
            try JobCancelOperation.Response(
                job: job,
                state: .committingUnsuccessfulOutcome,
                accepted: true
            )
        )
        let observedOperations = Mutex<[DatabaseOperationIdentifier]>([])
        let transport = ScriptedDatabaseTransport {
            requestBytes throws(DatabaseTransportError) in
            let envelope = try decodeRequest(requestBytes)
            observedOperations.withLock { $0.append(envelope.operation) }
            let responsePayload: DatabaseBytes
            switch envelope.operation {
            case .jobStart:
                let request = try decodeWire(
                    DatabaseTypedJobStartRequest<CapabilitiesSnapshotJob>.self,
                    from: envelope.payload
                )
                #expect(request.maximumSliceWorkUnits == 17)
                responsePayload = try encodeWire(
                    JobStartOperation.Response(job: job)
                )
            case .jobStatus:
                let request = try decodeWire(
                    JobStatusOperation.Request.self,
                    from: envelope.payload
                )
                #expect(request.job == job)
                responsePayload = statusPayload
            case .jobCancel:
                let request = try decodeWire(
                    JobCancelOperation.Request.self,
                    from: envelope.payload
                )
                #expect(request.job == job)
                responsePayload = cancellationPayload
            default:
                throw .invalidResponse("Unexpected job lifecycle operation")
            }
            return try encodeWire(
                response: DatabaseWireResponseEnvelope(
                    requestID: envelope.requestID,
                    operation: envelope.operation,
                    payload: .success(responsePayload)
                )
            )
        }
        let client = DatabaseClient(transport: transport)

        let started = try await client.startJob(
            CapabilitiesSnapshotJob.self,
            request: DatabaseEmpty(),
            maximumSliceWorkUnits: 17
        )
        let status = try await client.jobStatus(for: started)
        let cancelled = try await client.cancelJob(started)

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

    @Test("response correlation rejects a mismatched request ID")
    func responseCorrelationRejectsMismatch() throws {
        let call = DatabaseCall<CapabilitiesDescribeOperation>(
            requestID: 8,
            request: DatabaseEmpty()
        )
        let responsePayload = try DatabaseEnvelopeCodec.encode(
            CapabilitiesDescribeOperation.Response(
                runtimeVersion: "1",
                features: [],
                jobOperations: []
            )
        )
        let response = try DatabaseEnvelopeCodec.encode(
            response: DatabaseWireResponseEnvelope(
                requestID: 9,
                operation: .capabilitiesDescribe,
                payload: .success(responsePayload)
            )
        )

        #expect(throws: DatabaseCallError.mismatchedRequestID(expected: 8, actual: 9)) {
            _ = try call.decodeResponse(response)
        }
    }

    @Test("paged job results verify integrity and decode the original response")
    func pagedJobResultDecodesOriginalResponse() async throws {
        let job = DatabaseJobIdentity(
            jobID: DatabaseUUID(high: 0x1020, low: 0x3040),
            operation: try CapabilitiesSnapshotJob.jobOperationIdentifier()
        )
        let originalResponse = CapabilitiesDescribeOperation.Response(
            runtimeVersion: "1.0.0",
            features: [
                .init(identifier: "graph.sparql", version: 1),
                .init(identifier: "graph.shacl", version: 1),
            ],
            jobOperations: []
        )
        let payload = try DatabaseEnvelopeCodec.encode(originalResponse)
        let boundaries = [0, 3, payload.count / 2, payload.count]
        let pages = (0..<(boundaries.count - 1)).map { index in
            payload.slice(boundaries[index]..<boundaries[index + 1])
        }
        var accumulator = DatabaseJobResultDigestAccumulator(
            operation: job.operation
        )
        accumulator.update(payload)
        let digest = accumulator.finalize()
        let capturedRequestIDs = Mutex<[UInt64]>([])
        let transport = ScriptedDatabaseTransport {
            requestBytes throws(DatabaseTransportError) in
            let envelope = try decodeRequest(requestBytes)
            capturedRequestIDs.withLock { $0.append(envelope.requestID) }
            guard envelope.operation == .jobResult else {
                throw DatabaseTransportError.invalidResponse("Expected job.result")
            }
            let request: JobResultOperation.Request = try decodeWire(
                JobResultOperation.Request.self,
                from: envelope.payload
            )
            guard request.job == job else {
                throw DatabaseTransportError.invalidResponse(
                    "Unexpected job identifier"
                )
            }
            let pageIndex = Int(request.continuation?.nextChunkIndex ?? 0)
            guard pageIndex < pages.count else {
                throw DatabaseTransportError.invalidResponse(
                    "Unexpected result page"
                )
            }
            let continuation: JobResultOperation.Continuation?
            if pageIndex + 1 < pages.count {
                do {
                    continuation = try JobResultOperation.Continuation(
                        job: job,
                        responseDigest: digest,
                        nextChunkIndex: UInt32(pageIndex + 1)
                    )
                } catch {
                    throw DatabaseTransportError.invalidResponse(
                        String(describing: error)
                    )
                }
            } else {
                continuation = nil
            }
            return try encodeJobResultResponse(
                request: envelope,
                response: .succeeded(
                    job: job,
                    responsePayloadPage: pages[pageIndex],
                    totalResponseBytes: UInt64(payload.count),
                    responseDigest: digest,
                    continuation: continuation
                )
            )
        }
        let client = DatabaseClient(
            transport: transport,
            firstRequestID: 0
        )

        let decoded = try await client.jobResult(
            for: job,
            as: CapabilitiesSnapshotJob.self
        )

        #expect(decoded == originalResponse)
        #expect(capturedRequestIDs.withLock { $0 } == [0, 1, 2])
    }

    @Test("paged job results reject a payload with a mismatched digest")
    func pagedJobResultRejectsDigestMismatch() async throws {
        let job = DatabaseJobIdentity(
            jobID: DatabaseUUID(high: 0x5060, low: 0x7080),
            operation: try CapabilitiesSnapshotJob.jobOperationIdentifier()
        )
        let payload = try DatabaseEnvelopeCodec.encode(
            CapabilitiesDescribeOperation.Response(
                runtimeVersion: "1.0.0",
                features: [],
                jobOperations: []
            )
        )
        let incorrectDigest = try DatabaseJobResultDigest(
            [UInt8](repeating: 0, count: DatabaseJobResultDigest.byteCount)
        )
        let transport = ScriptedDatabaseTransport {
            requestBytes throws(DatabaseTransportError) in
            let envelope = try decodeRequest(requestBytes)
            return try encodeJobResultResponse(
                request: envelope,
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
        var actualDigestAccumulator = DatabaseJobResultDigestAccumulator(
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
            _ = try await client.jobResult(
                for: job,
                as: CapabilitiesSnapshotJob.self
            )
        }
    }
}

private struct CapabilitiesSnapshotJob: DatabaseJobDescriptor {
    typealias Request = DatabaseEmpty
    typealias Response = CapabilitiesDescribeOperation.Response

    static func jobOperationIdentifier()
        throws(DatabaseWireError) -> DatabaseJobOperationIdentifier {
        try DatabaseJobOperationIdentifier(
            family: .commandRead,
            kind: "capabilities.snapshot"
        )
    }
}

private struct ScriptedDatabaseTransport: DatabaseTransport {
    let responseProvider: @Sendable (DatabaseBytes) async throws(DatabaseTransportError) -> DatabaseBytes

    init(
        responseProvider: @escaping @Sendable (DatabaseBytes) async throws(DatabaseTransportError) -> DatabaseBytes
    ) {
        self.responseProvider = responseProvider
    }

    func send(_ request: DatabaseBytes) async throws(DatabaseTransportError) -> DatabaseBytes {
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

private func decodeRequest(
    _ bytes: DatabaseBytes
) throws(DatabaseTransportError) -> DatabaseWireRequestEnvelope {
    do {
        return try DatabaseEnvelopeCodec.decodeRequest(bytes)
    } catch {
        throw .invalidResponse(String(describing: error))
    }
}

private func encodeWire<Value: DatabaseWireValue>(
    _ value: Value
) throws(DatabaseTransportError) -> DatabaseBytes {
    do {
        return try DatabaseEnvelopeCodec.encode(value)
    } catch {
        throw .invalidResponse(String(describing: error))
    }
}

private func encodeWire(
    response: DatabaseWireResponseEnvelope
) throws(DatabaseTransportError) -> DatabaseBytes {
    do {
        return try DatabaseEnvelopeCodec.encode(response: response)
    } catch {
        throw .invalidResponse(String(describing: error))
    }
}

private func decodeWire<Value: DatabaseWireValue>(
    _ type: Value.Type,
    from bytes: DatabaseBytes
) throws(DatabaseTransportError) -> Value {
    switch DatabaseEnvelopeCodec.decodeResult(type, from: bytes) {
    case .success(let value):
        return value
    case .failure(let error):
        throw .invalidResponse(String(describing: error))
    }
}

private func encodeJobResultResponse(
    request: DatabaseWireRequestEnvelope,
    response: JobResultOperation.Response
) throws(DatabaseTransportError) -> DatabaseBytes {
    let payload = try encodeWire(response)
    return try encodeWire(
        response: DatabaseWireResponseEnvelope(
            requestID: request.requestID,
            operation: .jobResult,
            payload: .success(payload)
        )
    )
}
