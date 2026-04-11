import Foundation
import Core

public final class ClientQueryCursor<T: Persistable>: @unchecked Sendable {
    private var builder: QueryBuilder<T>
    private var exhausted = false

    init(builder: QueryBuilder<T>) {
        self.builder = builder
    }

    public func next() async throws -> QueryResult<T> {
        if exhausted {
            return QueryResult(items: [])
        }

        let result = try await builder.execute()
        if let continuation = result.continuation {
            builder = builder.continuation(continuation)
        } else {
            exhausted = true
        }
        return result
    }

    public func stream() -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    while true {
                        let page = try await self.next()
                        for item in page.items {
                            continuation.yield(item)
                        }
                        if !page.hasMore {
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
