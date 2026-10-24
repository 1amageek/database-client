import DatabaseAccess
import DatabaseWire

/// Claims one acquisition and transfers only fully initialized logical access.
actor RemoteOpening<Transport: DatabaseTransport>: DatabaseOpening {
    enum Source: Sendable {
        case borrowed(DatabaseSessionClient<Transport>)
        case owned(make: @Sendable () async throws -> Transport,
            session: @Sendable (DatabaseClient<Transport>) throws -> DatabaseSessionClient<Transport>,
            shutdown: @Sendable (Transport) async -> Void, limits: DatabaseWireLimits)
    }
    private let source: Source
    private var opened = false

    init(source: Source) { self.source = source }

    func open(maximumConcurrentExecutions: Int) async throws -> any DatabaseExecuting {
        if Task.isCancelled { throw CancellationError() }
        guard maximumConcurrentExecutions > 0 else { throw AccessConfigurationError.invalidConcurrencyLimit(maximumConcurrentExecutions) }
        guard !opened else { throw AccessConfigurationError.openingAlreadyUsed }
        opened = true
        switch source {
        case .borrowed(let session):
            let connection = try await session.openConnection(maximumConcurrentExecutions: maximumConcurrentExecutions)
            if Task.isCancelled {
                await Task { await connection.close() }.value
                throw CancellationError()
            }
            return RemoteExecution(connection: connection, shutdown: nil)
        case .owned(let make, let session, let shutdown, let limits):
            let transport = try await make()
            do {
                let selected = try session(DatabaseClient(transport: transport, limits: limits))
                let connection = try await selected.openConnection(maximumConcurrentExecutions: maximumConcurrentExecutions)
                if Task.isCancelled {
                    await Task { await connection.close() }.value
                    throw CancellationError()
                }
                return RemoteExecution(connection: connection, shutdown: { await shutdown(transport) })
            } catch {
                // Cleanup cannot be abandoned by a cancelled acquisition task.
                await Task { await shutdown(transport) }.value
                throw error
            }
        }
    }
}

public extension DatabaseConfiguration {
    static func borrowingRemote<Transport: DatabaseTransport>(
        session: DatabaseSessionClient<Transport>, maximumConcurrentExecutions: Int
    ) throws(AccessConfigurationError) -> Self {
        try Self(opening: RemoteOpening(source: .borrowed(session)), maximumConcurrentExecutions: maximumConcurrentExecutions)
    }

    static func owningRemote<Transport: DatabaseTransport>(
        maximumConcurrentExecutions: Int,
        makeTransport: @escaping @Sendable () async throws -> Transport,
        session: @escaping @Sendable (DatabaseClient<Transport>) throws -> DatabaseSessionClient<Transport> = { $0.database },
        shutdown: @escaping @Sendable (Transport) async -> Void,
        limits: DatabaseWireLimits = .default
    ) throws(AccessConfigurationError) -> Self {
        try Self(opening: RemoteOpening(source: .owned(make: makeTransport, session: session, shutdown: shutdown, limits: limits)),
            maximumConcurrentExecutions: maximumConcurrentExecutions)
    }
}
