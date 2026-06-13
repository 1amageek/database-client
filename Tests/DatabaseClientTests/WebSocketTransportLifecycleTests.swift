import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing
import Core
import DatabaseClientProtocol
@testable import DatabaseClient

@Suite("WebSocketTransport lifecycle")
struct WebSocketTransportLifecycleTests {
    @Test("in-flight cancellation returns before delayed server response")
    func inFlightCancellationReturnsBeforeDelayedServerResponse() async throws {
        let service = DelayedWebSocketQueryService(queryResponseDelays: [300_000_000])
        let server = try TestWebSocketServer(service: service)
        try server.start()
        defer { server.stop() }

        let context = try await DatabaseContext(
            configuration: ClientConfiguration(
                url: server.url,
                retryPolicy: .none,
                timeout: 5
            )
        )

        let queryTask = Task {
            try await context.find(TestUser.self).execute()
        }
        await service.waitForOperation("query")

        let start = Date()
        queryTask.cancel()

        do {
            _ = try await queryTask.value
            Issue.record("Expected in-flight WebSocket query to be cancelled")
        } catch is CancellationError {
            #expect(Date().timeIntervalSince(start) < 0.1)
        }
    }

    @Test("request timeout fails before delayed server response")
    func requestTimeoutFailsBeforeDelayedServerResponse() async throws {
        let service = DelayedWebSocketQueryService(queryResponseDelays: [300_000_000])
        let server = try TestWebSocketServer(service: service)
        try server.start()
        defer { server.stop() }

        let context = try await DatabaseContext(
            configuration: ClientConfiguration(
                url: server.url,
                retryPolicy: .none,
                timeout: 0.05
            )
        )

        let start = Date()
        do {
            _ = try await context.find(TestUser.self).execute()
            Issue.record("Expected WebSocket query to time out")
        } catch let error as ServiceError {
            #expect(error.code == "TIMEOUT")
            #expect(Date().timeIntervalSince(start) < 0.2)
        }
    }

    @Test("save timeout is not retried by transport")
    func saveTimeoutIsNotRetriedByTransport() async throws {
        let service = DelayedWebSocketQueryService(
            queryResponseDelays: [],
            saveResponseDelays: [150_000_000]
        )
        let server = try TestWebSocketServer(service: service)
        try server.start()
        defer { server.stop() }

        let context = try await DatabaseContext(
            configuration: ClientConfiguration(
                url: server.url,
                retryPolicy: ClientConfiguration.RetryPolicy(maxRetries: 2, backoffBase: 0),
                timeout: 0.05
            )
        )

        try context.insert(TestUser(id: "save-timeout-user", name: "Timeout", age: 1))

        let saveTask = Task {
            try await context.save()
        }
        await service.waitForOperation("save")

        do {
            try await saveTask.value
            Issue.record("Expected save to time out")
        } catch let error as ServiceError {
            #expect(error.code == "TIMEOUT")
        }

        #expect(await service.operationCount("save") == 1)
    }
}

private actor DelayedWebSocketQueryService {
    private var queryResponseDelays: [UInt64]
    private var saveResponseDelays: [UInt64]
    private var observedOperations: [String] = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(
        queryResponseDelays: [UInt64],
        saveResponseDelays: [UInt64] = []
    ) {
        self.queryResponseDelays = queryResponseDelays
        self.saveResponseDelays = saveResponseDelays
    }

    func handle(_ envelope: ServiceEnvelope) async throws -> ServiceEnvelope {
        observedOperations.append(envelope.operationID)
        let matchingWaiters = waiters.removeValue(forKey: envelope.operationID) ?? []
        for waiter in matchingWaiters {
            waiter.resume()
        }

        switch envelope.operationID {
        case "query":
            try await Task.sleep(nanoseconds: nextQueryResponseDelay())
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: envelope.operationID,
                payload: try JSONEncoder().encode(QueryResponse(rows: []))
            )
        case "save":
            try await Task.sleep(nanoseconds: nextSaveResponseDelay())
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: envelope.operationID
            )
        default:
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: envelope.operationID,
                errorCode: "UNKNOWN_OPERATION",
                errorMessage: envelope.operationID
            )
        }
    }

    func operationCount(_ operationID: String) -> Int {
        observedOperations.filter { $0 == operationID }.count
    }

    func waitForOperation(_ operationID: String) async {
        if observedOperations.contains(operationID) {
            return
        }
        await withCheckedContinuation { continuation in
            waiters[operationID, default: []].append(continuation)
        }
    }

    private func nextQueryResponseDelay() -> UInt64 {
        guard !queryResponseDelays.isEmpty else {
            return 0
        }
        return queryResponseDelays.removeFirst()
    }

    private func nextSaveResponseDelay() -> UInt64 {
        guard !saveResponseDelays.isEmpty else {
            return 0
        }
        return saveResponseDelays.removeFirst()
    }
}

private struct TestWebSocketServerState: Sendable {
    var listenFD: Int32 = -1
    var clientFD: Int32 = -1
    var port: UInt16 = 0
}

private final class TestWebSocketServer: Sendable {
    private let service: DelayedWebSocketQueryService
    private let state = Mutex(TestWebSocketServerState())

    var url: URL {
        let port = state.withLock { $0.port }
        return URL(string: "ws://127.0.0.1:\(port)/database-client-lifecycle")!
    }

    init(service: DelayedWebSocketQueryService) throws {
        self.service = service
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &boundAddressLength)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw POSIXError(.EIO)
        }

        state.withLock {
            $0.port = UInt16(bigEndian: boundAddress.sin_port)
            $0.listenFD = fd
        }
        Task.detached { [self] in
            await acceptLoop()
        }
    }

    func stop() {
        let descriptors = state.withLock { state in
            let current = (listenFD: state.listenFD, clientFD: state.clientFD)
            state.listenFD = -1
            state.clientFD = -1
            return current
        }

        if descriptors.clientFD >= 0 {
            close(descriptors.clientFD)
        }
        if descriptors.listenFD >= 0 {
            close(descriptors.listenFD)
        }
    }

    private func acceptLoop() async {
        while true {
            let listenFD = state.withLock { $0.listenFD }
            guard listenFD >= 0 else {
                return
            }

            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else {
                return
            }

            let shouldClose = state.withLock { state in
                guard state.listenFD >= 0 else {
                    return true
                }
                state.clientFD = fd
                return false
            }
            guard !shouldClose else {
                close(fd)
                return
            }

            do {
                var bufferedBytes = try performHandshake(fd: fd)
                try await frameLoop(fd: fd, bufferedBytes: &bufferedBytes)
            } catch {
            }

            let shouldCloseAcceptedDescriptor = state.withLock {
                if $0.clientFD == fd {
                    $0.clientFD = -1
                    return true
                }
                return false
            }
            if shouldCloseAcceptedDescriptor {
                close(fd)
            }
        }
    }

    private func performHandshake(fd: Int32) throws -> [UInt8] {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        let marker = Data("\r\n\r\n".utf8)
        while !data.contains(marker) {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else {
                throw POSIXError(.ECONNRESET)
            }
            data.append(buffer, count: count)
        }

        guard let request = String(data: data, encoding: .utf8),
              let keyLine = request
                .split(separator: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }),
              let key = keyLine.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) else {
            throw POSIXError(.EINVAL)
        }

        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(websocketAcceptValue(for: key))",
            "",
            "",
        ].joined(separator: "\r\n")
        _ = response.withCString {
            send(fd, $0, strlen($0), 0)
        }

        guard let markerRange = data.range(of: marker) else {
            return []
        }
        return Array(data[markerRange.upperBound...])
    }

    private func frameLoop(fd: Int32, bufferedBytes: inout [UInt8]) async throws {
        while true {
            let frame = try readFrame(fd: fd, bufferedBytes: &bufferedBytes)
            if frame.opcode == 0x8 {
                return
            }
            let request = try JSONDecoder().decode(ServiceEnvelope.self, from: frame.payload)
            let response = try await service.handle(request)
            let payload = try JSONEncoder().encode(response)
            try sendFrame(fd: fd, opcode: 0x2, payload: payload)
        }
    }

    private func websocketAcceptValue(for key: String) -> String {
        let combined = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        let digest = Insecure.SHA1.hash(data: combined)
        return Data(digest).base64EncodedString()
    }

    private func readFrame(fd: Int32, bufferedBytes: inout [UInt8]) throws -> (opcode: UInt8, payload: Data) {
        let header = try readExact(fd: fd, count: 2, bufferedBytes: &bufferedBytes)
        let first = header[0]
        let second = header[1]
        let opcode = first & 0x0f
        let masked = (second & 0x80) != 0
        var length = UInt64(second & 0x7f)

        if length == 126 {
            let extended = try readExact(fd: fd, count: 2, bufferedBytes: &bufferedBytes)
            length = UInt64(UInt16(extended[0]) << 8 | UInt16(extended[1]))
        } else if length == 127 {
            let extended = try readExact(fd: fd, count: 8, bufferedBytes: &bufferedBytes)
            length = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }

        let mask = masked ? try readExact(fd: fd, count: 4, bufferedBytes: &bufferedBytes) : []
        var payload = try readExact(fd: fd, count: Int(length), bufferedBytes: &bufferedBytes)
        if masked {
            for index in payload.indices {
                payload[index] ^= mask[index % 4]
            }
        }
        return (opcode, Data(payload))
    }

    private func sendFrame(fd: Int32, opcode: UInt8, payload: Data) throws {
        var header: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            header.append(UInt8(payload.count))
        } else if payload.count <= UInt16.max {
            header.append(126)
            header.append(UInt8((payload.count >> 8) & 0xff))
            header.append(UInt8(payload.count & 0xff))
        } else {
            header.append(127)
            let count = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                header.append(UInt8((count >> UInt64(shift)) & 0xff))
            }
        }

        try header.withUnsafeBytes { rawBuffer in
            guard send(fd, rawBuffer.baseAddress, rawBuffer.count, 0) == rawBuffer.count else {
                throw POSIXError(.EPIPE)
            }
        }
        try payload.withUnsafeBytes { rawBuffer in
            guard send(fd, rawBuffer.baseAddress, rawBuffer.count, 0) == rawBuffer.count else {
                throw POSIXError(.EPIPE)
            }
        }
    }

    private func readExact(fd: Int32, count: Int, bufferedBytes: inout [UInt8]) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(count)

        if !bufferedBytes.isEmpty {
            let prefixCount = min(count, bufferedBytes.count)
            output.append(contentsOf: bufferedBytes.prefix(prefixCount))
            bufferedBytes.removeFirst(prefixCount)
        }

        var buffer = [UInt8](repeating: 0, count: count)
        while output.count < count {
            let remaining = count - output.count
            let readCount = recv(fd, &buffer, remaining, 0)
            guard readCount > 0 else {
                throw POSIXError(.ECONNRESET)
            }
            output.append(contentsOf: buffer.prefix(readCount))
        }
        return output
    }
}
