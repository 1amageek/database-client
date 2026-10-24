import Synchronization

/// Owns atomic publication and awaited shutdown of explicitly configured access.
public final class DatabaseDirectory: DatabaseProviding {
    private enum Phase {
        case unconfigured
        case configuring(AccessGeneration, Task<Void, any Error>)
        case ready(AccessGeneration, [String: Database])
        case closing(AccessGeneration, Task<Void, Never>)
        case closed
    }
    private let state = Mutex<Phase>(.unconfigured)

    public init() {}

    public func configure(databases: [String: DatabaseConfiguration]) async throws {
        if Task.isCancelled { throw CancellationError() }
        for name in databases.keys where name.isEmpty { throw AccessError.invalidName(name) }
        let ordered = databases.sorted { $0.key < $1.key }
        let task = try state.withLock { state -> Task<Void, any Error> in
            switch state {
            case .unconfigured, .closed: break
            case .configuring: throw AccessError.configurationInProgress
            case .ready: throw AccessError.alreadyConfigured
            case .closing: throw AccessError.shuttingDown
            }
            let generation = AccessGeneration()
            let task = Task { try await self.open(ordered, generation: generation) }
            state = .configuring(generation, task)
            return task
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    public func database(_ name: String) throws(AccessError) -> Database {
        guard !name.isEmpty else { throw .invalidName(name) }
        return try state.withLock { state throws(AccessError) -> Database in
            switch state {
            case .unconfigured, .closed: throw .notConfigured
            case .configuring: throw .configurationInProgress
            case .closing: throw .shuttingDown
            case .ready(_, let databases):
                guard let database = databases[name] else { throw .nameNotFound(name) }
                return database
            }
        }
    }

    public func shutdown() async {
        let task = state.withLock { state -> Task<Void, Never>? in
            switch state {
            case .unconfigured, .closed:
                state = .closed
                return nil
            case .closing(_, let task): return task
            case .configuring(let generation, let initialization):
                generation.invalidate()
                let task = Task {
                    initialization.cancel()
                    do { try await initialization.value }
                    catch {
                        // Configure retains its failure; shutdown only joins cleanup.
                    }
                    self.finishShutdown(generation)
                }
                state = .closing(generation, task)
                return task
            case .ready(let generation, let databases):
                generation.invalidate()
                let task = Task {
                    for name in databases.keys.sorted().reversed() {
                        if let database = databases[name] { await database.endpoint.close() }
                    }
                    self.finishShutdown(generation)
                }
                state = .closing(generation, task)
                return task
            }
        }
        await task?.value
    }

    private func open(_ configurations: [(key: String, value: DatabaseConfiguration)],
        generation: AccessGeneration) async throws {
        var acquired: [(String, any DatabaseExecuting)] = []
        do {
            for (name, configuration) in configurations {
                if Task.isCancelled { throw CancellationError() }
                do {
                    let endpoint = try await configuration.open()
                    acquired.append((name, endpoint))
                } catch {
                    throw AccessError.initializationFailed(name: name, cause: error)
                }
            }
            var databases: [String: Database] = [:]
            databases.reserveCapacity(acquired.count)
            for (name, endpoint) in acquired {
                databases[name] = Database(name: name, generation: generation, endpoint: endpoint)
            }
            let published = state.withLock { state in
                guard case .configuring(let current, _) = state,
                    current === generation, !Task.isCancelled else { return false }
                state = .ready(generation, databases)
                return true
            }
            guard published else { throw CancellationError() }
        } catch {
            generation.invalidate()
            let endpoints = acquired
            await Task {
                for (_, endpoint) in endpoints.reversed() { await endpoint.close() }
            }.value
            state.withLock { state in
                if case .configuring(let current, _) = state, current === generation {
                    state = .unconfigured
                }
            }
            throw error
        }
    }

    private func finishShutdown(_ generation: AccessGeneration) {
        state.withLock { state in
            if case .closing(let current, _) = state, current === generation { state = .closed }
        }
    }
}
