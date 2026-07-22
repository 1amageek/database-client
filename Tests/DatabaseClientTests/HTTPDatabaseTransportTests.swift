#if !os(WASI)
import DatabaseClient
import Foundation
import DatabaseClientHTTP
import Synchronization
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("DatabaseWire HTTP transport", .serialized)
struct HTTPDatabaseTransportTests {
    @Test("transport sends wire body authorization and database scope")
    func transportSendsRequiredHeaders() async throws {
        let capture = Mutex<(request: URLRequest, body: Data)?>(nil)
        ScriptedHTTPDatabaseEndpoint.installResponseProvider { request in
            let body = try requestBodyData(from: request)
            capture.withLock { $0 = (request, body) }
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/octet-stream"]
            ))
            return (response, Data([2, 1]))
        }
        defer { ScriptedHTTPDatabaseEndpoint.installResponseProvider(nil) }

        let configuration = try HTTPDatabaseConfiguration(
            endpoint: URL(string: "https://database.example.test")!,
            accessToken: "secret-token",
            databaseID: "calendar",
            tenantID: "tenant-a",
            workspaceID: "production"
        )
        let transport = HTTPDatabaseTransport(
            configuration: configuration,
            session: makeSession()
        )

        let response = try await transport.send([2, 4, 8])
        let captured = try #require(capture.withLock { $0 })
        let request = captured.request

        #expect(response == [2, 1])
        #expect(request.httpMethod == "POST")
        #expect(captured.body == Data([2, 4, 8]))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
        #expect(request.value(forHTTPHeaderField: "x-database-id") == "calendar")
        #expect(request.value(forHTTPHeaderField: "x-tenant-id") == "tenant-a")
        #expect(request.value(forHTTPHeaderField: "x-workspace-id") == "production")
    }

    @Test("transport maps HTTP failures to a typed client error")
    func transportMapsHTTPFailure() async throws {
        ScriptedHTTPDatabaseEndpoint.installResponseProvider { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data("Unauthorized".utf8))
        }
        defer { ScriptedHTTPDatabaseEndpoint.installResponseProvider(nil) }

        let configuration = try HTTPDatabaseConfiguration(
            endpoint: URL(string: "https://database.example.test")!,
            accessToken: "invalid-token"
        )
        let transport = HTTPDatabaseTransport(
            configuration: configuration,
            session: makeSession()
        )

        do {
            _ = try await transport.send([2])
            Issue.record("Expected an HTTP status error")
        } catch {
            #expect(error == .rejected(code: "http_status_401", message: "Unauthorized"))
        }
    }

    @Test("configuration rejects an empty token")
    func configurationRejectsEmptyToken() {
        #expect(throws: HTTPDatabaseConfigurationError.emptyAccessToken) {
            _ = try HTTPDatabaseConfiguration(
                endpoint: URL(string: "https://database.example.test")!,
                accessToken: " "
            )
        }
    }

    @Test("transport rejects oversized requests before starting URL loading")
    func transportRejectsOversizedRequestBeforeLoading() async throws {
        let invoked = Mutex(false)
        ScriptedHTTPDatabaseEndpoint.installResponseProvider { request in
            invoked.withLock { $0 = true }
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data())
        }
        defer { ScriptedHTTPDatabaseEndpoint.installResponseProvider(nil) }

        let configuration = try HTTPDatabaseConfiguration(
            endpoint: URL(string: "https://database.example.test")!,
            accessToken: "token",
            maximumRequestBytes: 2
        )
        let transport = HTTPDatabaseTransport(
            configuration: configuration,
            session: makeSession()
        )

        await #expect(
            throws: DatabaseTransportError.rejected(
                code: "request_too_large",
                message: "Database request exceeds the configured byte limit"
            )
        ) {
            try await transport.send([1, 2, 3])
        }
        #expect(!invoked.withLock { $0 })
    }

    @Test("transport rejects oversized response content length before body delivery")
    func transportRejectsOversizedContentLength() async throws {
        ScriptedHTTPDatabaseEndpoint.installResponseProvider { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "3"]
            ))
            return (response, Data([1, 2, 3]))
        }
        defer { ScriptedHTTPDatabaseEndpoint.installResponseProvider(nil) }

        let configuration = try HTTPDatabaseConfiguration(
            endpoint: URL(string: "https://database.example.test")!,
            accessToken: "token",
            maximumResponseBytes: 2
        )
        let transport = HTTPDatabaseTransport(
            configuration: configuration,
            session: makeSession()
        )

        await #expect(
            throws: DatabaseTransportError.invalidResponse(
                "HTTP response exceeds the configured byte limit"
            )
        ) {
            try await transport.send([1])
        }
    }

    @Test("transport rejects an oversized streamed body without content length")
    func transportRejectsOversizedStreamedBody() async throws {
        ScriptedHTTPDatabaseEndpoint.installResponseProvider { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data([1, 2, 3]))
        }
        defer { ScriptedHTTPDatabaseEndpoint.installResponseProvider(nil) }

        let configuration = try HTTPDatabaseConfiguration(
            endpoint: URL(string: "https://database.example.test")!,
            accessToken: "token",
            maximumResponseBytes: 2
        )
        let transport = HTTPDatabaseTransport(
            configuration: configuration,
            session: makeSession()
        )

        await #expect(
            throws: DatabaseTransportError.invalidResponse(
                "HTTP response exceeds the configured byte limit"
            )
        ) {
            try await transport.send([1])
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedHTTPDatabaseEndpoint.self]
        return URLSession(configuration: configuration)
    }
}

private func requestBodyData(from request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return Data()
    }

    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else {
            throw stream.streamError ?? URLError(.cannotDecodeRawData)
        }
        if count == 0 {
            break
        }
        data.append(buffer, count: count)
    }
    return data
}

fileprivate final class ScriptedHTTPDatabaseEndpoint: URLProtocol {
    typealias ResponseProvider = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let responseProvider = Mutex<ResponseProvider?>(nil)

    static func installResponseProvider(_ value: ResponseProvider?) {
        responseProvider.withLock { $0 = value }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let responseProvider = Self.responseProvider.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try responseProvider(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

#endif
