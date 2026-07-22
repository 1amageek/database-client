import DatabaseWire

public extension DatabaseClient {
    func startJob<Job: DatabaseJobDescriptor>(
        _ job: Job.Type = Job.self,
        request: Job.Request,
        maximumSliceWorkUnits: UInt64 = 100_000,
        retryPolicy: JobStartOperation.RetryPolicy = .init(),
        metadata: DatabaseRequestMetadata = DatabaseRequestMetadata()
    ) async throws(DatabaseClientError) -> DatabaseJobIdentity {
        _ = job
        let expectedOperation = try expectedJobOperation(Job.self)
        let response = try await execute(
            DatabaseTypedJobStartOperation<Job>.self,
            request: DatabaseTypedJobStartRequest(
                request: request,
                maximumSliceWorkUnits: maximumSliceWorkUnits,
                retryPolicy: retryPolicy
            ),
            metadata: metadata
        )
        guard response.operation == expectedOperation else {
            throw .jobLifecycle(
                .mismatchedOperation(
                    expected: expectedOperation,
                    actual: response.operation
                )
            )
        }
        return response.job
    }

    func jobStatus(
        for job: DatabaseJobIdentity,
        metadata: DatabaseRequestMetadata = DatabaseRequestMetadata()
    ) async throws(DatabaseClientError) -> JobStatusOperation.Response {
        let response = try await execute(
            JobStatusOperation.self,
            request: JobStatusOperation.Request(job: job),
            metadata: metadata
        )
        try validateJobIdentity(response.job, expected: job)
        return response
    }

    func cancelJob(
        _ job: DatabaseJobIdentity,
        metadata: DatabaseRequestMetadata = DatabaseRequestMetadata()
    ) async throws(DatabaseClientError) -> JobCancelOperation.Response {
        let response = try await execute(
            JobCancelOperation.self,
            request: JobCancelOperation.Request(job: job),
            metadata: metadata
        )
        try validateJobIdentity(response.job, expected: job)
        return response
    }

    private func expectedJobOperation<Job: DatabaseJobDescriptor>(
        _ job: Job.Type
    ) throws(DatabaseClientError) -> DatabaseJobOperationIdentifier {
        _ = job
        do {
            return try Job.jobOperationIdentifier()
        } catch let error {
            throw .call(.wire(error))
        }
    }

    private func validateJobIdentity(
        _ actual: DatabaseJobIdentity,
        expected: DatabaseJobIdentity
    ) throws(DatabaseClientError) {
        guard actual == expected else {
            throw .jobLifecycle(
                .mismatchedJob(expected: expected, actual: actual)
            )
        }
    }
}
