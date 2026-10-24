import DatabaseTypes

/// An iterator-owned cycle checkpoint with constant retained storage.
struct QueryContinuationProgress: Sendable {
    private var checkpoint: ByteString?
    private var distance: UInt64 = 0
    private var window: UInt64 = 1

    init(continuation: ByteString?) { checkpoint = continuation }

    mutating func advance(to next: ByteString?, after previous: ByteString) throws(QueryStreamError) {
        guard let next else { checkpoint = nil; return }
        guard next != previous, next != checkpoint else { throw .continuationDidNotAdvance }
        // Doubling checkpoints detect any eventual cycle without retaining token history.
        if distance == window {
            checkpoint = previous
            let doubled = window.multipliedReportingOverflow(by: 2)
            window = doubled.overflow ? .max : doubled.partialValue
            distance = 0
        }
        distance += 1
    }
}
