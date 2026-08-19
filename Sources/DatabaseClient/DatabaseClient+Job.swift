import DatabaseWire

public extension DatabaseSessionClient {
    func startJob<Request: Sendable, Response: Sendable>(
        _ job: JobOperation<Request, Response>,
        request: Request,
        maximumSliceWorkUnits: UInt64 = 100_000,
        retryPolicy: JobStartOperation.RetryPolicy = .init(),
        metadata: OperationRequestMetadata = OperationRequestMetadata()
    ) async throws(DatabaseClientError) -> JobIdentity {
        let startRequest: JobStartOperation.Request
        do {
            #if DATABASE_CLIENT_MULTI_BASE
            startRequest = try job.makeStartRequest(
                request,
                target: target,
                maximumSliceWorkUnits: maximumSliceWorkUnits,
                retryPolicy: retryPolicy,
                limits: limits
            )
            #else
            startRequest = try job.makeStartRequest(
                request,
                maximumSliceWorkUnits: maximumSliceWorkUnits,
                retryPolicy: retryPolicy,
                limits: limits
            )
            #endif
        } catch let error {
            throw .call(.wire(error))
        }
        let response = try await execute(
            DatabaseOperationCatalog.jobStart,
            request: startRequest,
            metadata: metadata
        )
        #if DATABASE_CLIENT_MULTI_BASE
        let expectedJob = JobIdentity(
            jobID: response.job.jobID,
            operation: job.identifier,
            target: target
        )
        #else
        let expectedJob = JobIdentity(
            jobID: response.job.jobID,
            operation: job.identifier
        )
        #endif
        guard response.job == expectedJob else {
            throw .jobLifecycle(
                .mismatchedJob(expected: expectedJob, actual: response.job)
            )
        }
        return response.job
    }

    func jobStatus(
        for job: JobIdentity,
        metadata: OperationRequestMetadata = OperationRequestMetadata()
    ) async throws(DatabaseClientError) -> JobStatusOperation.Response {
        try validateBoundJobTarget(job)
        let response = try await execute(
            DatabaseOperationCatalog.jobStatus,
            request: JobStatusOperation.Request(job: job),
            metadata: metadata
        )
        try validateJobIdentity(response.job, expected: job)
        return response
    }

    func cancelJob(
        _ job: JobIdentity,
        metadata: OperationRequestMetadata = OperationRequestMetadata()
    ) async throws(DatabaseClientError) -> JobCancelOperation.Response {
        try validateBoundJobTarget(job)
        let response = try await execute(
            DatabaseOperationCatalog.jobCancel,
            request: JobCancelOperation.Request(job: job),
            metadata: metadata
        )
        try validateJobIdentity(response.job, expected: job)
        return response
    }

    private func validateJobIdentity(
        _ actual: JobIdentity,
        expected: JobIdentity
    ) throws(DatabaseClientError) {
        guard actual == expected else {
            throw .jobLifecycle(
                .mismatchedJob(expected: expected, actual: actual)
            )
        }
    }

    private func validateBoundJobTarget(
        _ job: JobIdentity
    ) throws(DatabaseClientError) {
        #if DATABASE_CLIENT_MULTI_BASE
        guard job.target == target else {
            throw .jobLifecycle(
                .mismatchedJob(
                    expected: JobIdentity(
                        jobID: job.jobID,
                        operation: job.operation,
                        target: target
                    ),
                    actual: job
                )
            )
        }
        #else
        _ = job
        #endif
    }
}
