import DatabaseTypes
import DatabaseWire

public extension TargetedDatabaseClient {
    /// Reads every immutable result page, verifies its canonical digest, and
    /// decodes the response associated with the exact job descriptor.
    func jobResult<Request: Sendable, Response: Sendable>(
        for job: JobIdentity,
        using operation: JobOperation<Request, Response>,
        metadata: OperationRequestMetadata = OperationRequestMetadata()
    ) async throws(DatabaseClientError) -> Response {
        guard job.operation == operation.identifier,
              job.target == target else {
            throw .jobResult(
                .mismatchedJob(
                    expected: JobIdentity(
                        jobID: job.jobID,
                        operation: operation.identifier,
                        target: target
                    ),
                    actual: job
                )
            )
        }
        var continuation: JobResultOperation.Continuation?
        var expectedTotalByteCount: UInt64?
        var expectedDigest: JobResultDigest?
        var expectedContinuationIndex: UInt32 = 1
        var receivedByteCount: UInt64 = 0
        var responseBytes: [UInt8] = []
        var digestAccumulator = JobResultDigestAccumulator(
            operation: job.operation,
            target: job.target
        )

        repeat {
            let result = try await execute(
                DatabaseOperationCatalog.jobResult,
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

        do {
            // ByteString retains the Array's copy-on-write storage. This moves
            // the completed payload across the decoding boundary without a
            // second materialization of the response bytes.
            let completedResponse = ByteString(responseBytes)
            return try operation.decodeCompletedResponse(
                completedResponse,
                limits: limits
            )
        } catch let error {
            throw .jobResult(.responseDecode(error))
        }
    }

    private func validateJobResultIdentity(
        _ actual: JobIdentity,
        expected: JobIdentity
    ) throws(DatabaseClientError) {
        guard actual == expected else {
            throw .jobResult(
                .mismatchedJob(expected: expected, actual: actual)
            )
        }
    }
}
