import DatabaseValue
import DatabaseWire

public extension DatabaseClient {
    /// Reads every immutable result page, verifies its canonical digest, and
    /// decodes the response associated with the exact job descriptor.
    func jobResult<Job: DatabaseJobDescriptor>(
        for job: DatabaseJobIdentity,
        as descriptor: Job.Type = Job.self,
        metadata: DatabaseRequestMetadata = DatabaseRequestMetadata()
    ) async throws(DatabaseClientError) -> Job.Response {
        _ = descriptor
        let descriptorOperation: DatabaseJobOperationIdentifier
        do {
            descriptorOperation = try Job.jobOperationIdentifier()
        } catch let error {
            throw .call(.wire(error))
        }
        guard job.operation == descriptorOperation else {
            throw .jobResult(
                .mismatchedJob(
                    expected: DatabaseJobIdentity(
                        jobID: job.jobID,
                        operation: descriptorOperation
                    ),
                    actual: job
                )
            )
        }
        var continuation: JobResultOperation.Continuation?
        var expectedTotalByteCount: UInt64?
        var expectedDigest: DatabaseJobResultDigest?
        var expectedContinuationIndex: UInt32 = 1
        var receivedByteCount: UInt64 = 0
        var responseBytes: [UInt8] = []
        var digestAccumulator = DatabaseJobResultDigestAccumulator(
            operation: job.operation
        )

        repeat {
            let result = try await execute(
                JobResultOperation.self,
                request: JobResultOperation.Request(
                    job: job,
                    continuation: continuation
                ),
                metadata: metadata
            )
            switch result {
            case .failed(let actualJob, let error):
                try validateJobResultIdentity(
                    actualJob,
                    expected: job
                )
                throw .jobResult(.failed(error))
            case .cancelled(let actualJob):
                try validateJobResultIdentity(
                    actualJob,
                    expected: job
                )
                throw .jobResult(.cancelled(actualJob))
            case .succeeded(
                let actualJob,
                let page,
                let totalByteCount,
                let responseDigest,
                let nextContinuation
            ):
                try validateJobResultIdentity(
                    actualJob,
                    expected: job
                )
                if let expectedTotalByteCount {
                    guard totalByteCount == expectedTotalByteCount else {
                        throw .jobResult(
                            .totalByteCountChanged(
                                expected: expectedTotalByteCount,
                                actual: totalByteCount
                            )
                        )
                    }
                } else {
                    let maximumResponseBytes = min(
                        JobResultOperation.maximumResponseBytes,
                        min(
                            limits.maximumFrameBytes,
                            limits.maximumByteStringBytes
                        )
                    )
                    guard maximumResponseBytes >= 0,
                          totalByteCount <= UInt64(maximumResponseBytes),
                          let exactCount = Int(exactly: totalByteCount) else {
                        throw .jobResult(
                            .responseTooLarge(
                                actual: totalByteCount,
                                maximum: maximumResponseBytes
                            )
                        )
                    }
                    expectedTotalByteCount = totalByteCount
                    expectedDigest = responseDigest.detached()
                    // The completed typed response requires contiguous storage.
                    // Allocate its final owner once, then fill it page by page.
                    responseBytes = [UInt8](repeating: 0, count: exactCount)
                }
                if let expectedDigest,
                   responseDigest != expectedDigest {
                    throw .jobResult(
                        .digestChanged(
                            expected: expectedDigest,
                            actual: responseDigest
                        )
                    )
                }

                let pageByteCount = UInt64(page.count)
                let nextReceivedByteCount = receivedByteCount
                    .addingReportingOverflow(pageByteCount)
                guard !nextReceivedByteCount.overflow,
                      nextReceivedByteCount.partialValue <= totalByteCount else {
                    throw .jobResult(
                        .byteCountExceeded(
                            expected: totalByteCount,
                            actual: nextReceivedByteCount.partialValue
                        )
                    )
                }
                let destinationOffset = Int(receivedByteCount)
                responseBytes.withUnsafeMutableBytes { destination in
                    page.withUnsafeBytes { source in
                        guard source.count > 0 else {
                            return
                        }
                        destination.baseAddress!
                            .advanced(by: destinationOffset)
                            .copyMemory(
                                from: source.baseAddress!,
                                byteCount: source.count
                            )
                    }
                }
                digestAccumulator.update(page)
                receivedByteCount = nextReceivedByteCount.partialValue

                if let nextContinuation {
                    guard !page.isEmpty else {
                        throw .jobResult(.emptyPageWithContinuation)
                    }
                    guard nextContinuation.job == job else {
                        throw .jobResult(
                            .invalidContinuationJob(
                                expected: job,
                                actual: nextContinuation.job
                            )
                        )
                    }
                    guard nextContinuation.responseDigest == responseDigest else {
                        throw .jobResult(.invalidContinuationDigest)
                    }
                    guard nextContinuation.nextChunkIndex
                            == expectedContinuationIndex else {
                        throw .jobResult(
                            .invalidContinuationIndex(
                                expected: expectedContinuationIndex,
                                actual: nextContinuation.nextChunkIndex
                            )
                        )
                    }
                    guard receivedByteCount < totalByteCount else {
                        throw .jobResult(
                            .byteCountExceeded(
                                expected: totalByteCount,
                                actual: receivedByteCount
                            )
                        )
                    }
                    let incremented = expectedContinuationIndex
                        .addingReportingOverflow(1)
                    guard !incremented.overflow else {
                        throw .jobResult(
                            .invalidContinuationIndex(
                                expected: expectedContinuationIndex,
                                actual: nextContinuation.nextChunkIndex
                            )
                        )
                    }
                    expectedContinuationIndex = incremented.partialValue
                } else {
                    guard receivedByteCount == totalByteCount else {
                        throw .jobResult(
                            .incompleteByteCount(
                                expected: totalByteCount,
                                actual: receivedByteCount
                            )
                        )
                    }
                }
                continuation = nextContinuation?.detached()
            }
        } while continuation != nil

        guard let expectedDigest,
              let expectedTotalByteCount else {
            throw .jobResult(
                .incompleteByteCount(expected: 0, actual: 0)
            )
        }
        let actualDigest = digestAccumulator.finalize()
        guard actualDigest == expectedDigest else {
            throw .jobResult(
                .digestMismatch(
                    expected: expectedDigest,
                    actual: actualDigest
                )
            )
        }
        guard UInt64(responseBytes.count) == expectedTotalByteCount else {
            throw .jobResult(
                .incompleteByteCount(
                    expected: expectedTotalByteCount,
                    actual: UInt64(responseBytes.count)
                )
            )
        }

        switch DatabaseEnvelopeCodec.decodeResult(
                Job.Response.self,
                from: DatabaseBytes(responseBytes),
                limits: limits
            ) {
        case .success(let response):
            return response
        case .failure(let error):
            throw .jobResult(.responseDecode(error))
        }
    }

    private func validateJobResultIdentity(
        _ actual: DatabaseJobIdentity,
        expected: DatabaseJobIdentity
    ) throws(DatabaseClientError) {
        guard actual == expected else {
            throw .jobResult(
                .mismatchedJob(expected: expected, actual: actual)
            )
        }
    }
}
