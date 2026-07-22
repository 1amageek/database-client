#if !os(WASI)
import DatabaseClient
import DatabaseValue
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor HTTPDatabaseTransport: DatabaseTransport {
    private let configuration: HTTPDatabaseConfiguration
    private let sessionConfiguration: URLSessionConfiguration

    public init(
        configuration: HTTPDatabaseConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.sessionConfiguration = session.configuration
    }

    public func send(
        _ request: DatabaseBytes
    ) async throws(DatabaseTransportError) -> DatabaseBytes {
        guard request.count <= configuration.maximumRequestBytes else {
            throw .rejected(
                code: "request_too_large",
                message: "Database request exceeds the configured byte limit"
            )
        }
        var urlRequest = URLRequest(
            url: configuration.endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: configuration.requestTimeout
        )
        urlRequest.httpMethod = "POST"
        // URLRequest owns Data and cannot retain a DatabaseBytes synchronous borrow.
        // This is the single ownership copy at the Foundation request boundary.
        urlRequest.httpBody = request.withUnsafeBytes { bytes in
            Data(bytes)
        }
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(configuration.databaseID, forHTTPHeaderField: "x-database-id")
        if let tenantID = configuration.tenantID {
            urlRequest.setValue(tenantID, forHTTPHeaderField: "x-tenant-id")
        }
        if let workspaceID = configuration.workspaceID {
            urlRequest.setValue(workspaceID, forHTTPHeaderField: "x-workspace-id")
        }

        let responseBytes: DatabaseBytes
        let urlResponse: URLResponse
        do {
            let requestSession = HTTPDatabaseRequestSession(
                maximumResponseBytes: configuration.maximumResponseBytes,
                configuration: sessionConfiguration
            )
            (responseBytes, urlResponse) = try await requestSession.data(
                for: urlRequest
            )
        } catch is CancellationError {
            throw .cancelled
        } catch let error as URLError where error.code == .timedOut {
            throw .timeout
        } catch let error as DatabaseTransportError {
            throw error
        } catch {
            throw .unavailable(String(describing: error))
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw .invalidResponse("HTTP transport received a non-HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(
                decoding: responseBytes.prefix(4_096),
                as: UTF8.self
            )
            throw .rejected(code: "http_status_\(httpResponse.statusCode)", message: message)
        }
        return responseBytes
    }
}
#endif
