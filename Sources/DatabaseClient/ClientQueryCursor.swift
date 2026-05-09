import Foundation
import Core

public final class ClientQueryCursor<T: Persistable>: Sendable {
    private let state: ClientQueryCursorState<T>

    init(builder: QueryBuilder<T>) {
        self.state = ClientQueryCursorState(builder: builder)
    }

    public func next() async throws -> QueryResult<T> {
        try await state.next()
    }

    public func stream() -> AsyncThrowingStream<T, Error> {
        let iterator = ClientQueryCursorStreamIterator(cursor: self)
        return AsyncThrowingStream {
            try await iterator.next()
        }
    }
}

private actor ClientQueryCursorStreamIterator<T: Persistable> {
    private let cursor: ClientQueryCursor<T>
    private var bufferedItems: [T] = []
    private var reachedEnd = false

    init(cursor: ClientQueryCursor<T>) {
        self.cursor = cursor
    }

    func next() async throws -> T? {
        try Task.checkCancellation()

        while bufferedItems.isEmpty {
            if reachedEnd {
                return nil
            }

            let page = try await cursor.next()
            try Task.checkCancellation()
            bufferedItems = page.items
            reachedEnd = !page.hasMore
        }

        return bufferedItems.removeFirst()
    }
}

private actor ClientQueryCursorState<T: Persistable> {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var builder: QueryBuilder<T>
    private var exhausted = false
    private var isAdvancing = false
    private var waiters: [Waiter] = []
    private var pendingWaiterIDs: Set<UUID> = []
    private var canceledWaiterIDs: Set<UUID> = []

    init(builder: QueryBuilder<T>) {
        self.builder = builder
    }

    func next() async throws -> QueryResult<T> {
        try await enter()
        defer { leave() }

        try Task.checkCancellation()

        if exhausted {
            return QueryResult(items: [])
        }

        let result = try await builder.execute()
        try Task.checkCancellation()

        if let continuation = result.continuation {
            builder = builder.continuation(continuation)
        } else {
            exhausted = true
        }
        return result
    }

    private func enter() async throws {
        try Task.checkCancellation()
        if !isAdvancing {
            isAdvancing = true
            return
        }

        let waiterID = UUID()
        pendingWaiterIDs.insert(waiterID)
        do {
            try await withTaskCancellationHandler {
                try await waitForTurn(id: waiterID)
            } onCancel: {
                Task { await self.cancelWaiter(id: waiterID) }
            }
        } catch {
            pendingWaiterIDs.remove(waiterID)
            canceledWaiterIDs.remove(waiterID)
            throw error
        }
        pendingWaiterIDs.remove(waiterID)
        canceledWaiterIDs.remove(waiterID)
    }

    private func waitForTurn(id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            pendingWaiterIDs.remove(id)
            if canceledWaiterIDs.remove(id) != nil {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        } else if pendingWaiterIDs.contains(id) {
            canceledWaiterIDs.insert(id)
        }
    }

    private func leave() {
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            if canceledWaiterIDs.remove(next.id) != nil {
                next.continuation.resume(throwing: CancellationError())
                continue
            }
            next.continuation.resume()
            return
        }

        isAdvancing = false
    }
}
