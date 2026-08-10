import DatabaseWire

public extension TargetedDatabaseClient {
    func startJob<Request: Sendable, Response: Sendable>(
        _ job: JobOperation<Request, Response>,
        request: Request,
        maximumSliceWorkUnits: UInt64 = 100_000,
        retryPolicy: JobStartOperation.RetryPolicy = .init(),
        metadata: OperationRequestMetadata = OperationRequestMetadata()
    ) async throws(DatabaseClientError) -> JobIdentity {
        let startRequest: JobStartOperation.Request
        do {
            startRequest = try job.makeStartRequest(
                request,
                target: target,
                maximumSliceWorkUnits: maximumSliceWorkUnits,
                retryPolicy: retryPolicy,
                limits: limits
            )
        } catch let error {
            throw .call(.wire(error))
        }
        let response = try await execute(
            DatabaseOperations.jobStart,
            request: startRequest,
            metadata: metadata
        )
        let expectedJob = JobIdentity(
            jobID: response.job.jobID,
            operation: job.identifier,
            target: target
        )
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
            DatabaseOperations.jobStatus,
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
            DatabaseOperations.jobCancel,
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
    }
}
