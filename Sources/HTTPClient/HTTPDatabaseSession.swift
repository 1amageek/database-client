#if !os(WASI)
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DatabaseClient
import DatabaseTypes
import Foundation

final class HTTPDatabaseSession: Sendable {
    private let responseCoordinator: HTTPDatabaseResponseCoordinator
    private let urlSession: URLSession

    init(
        maximumResponseBytes: Int,
        configuration: URLSessionConfiguration
    ) {
        let responseCoordinator = HTTPDatabaseResponseCoordinator(
            maximumResponseBytes: maximumResponseBytes
        )
        self.responseCoordinator = responseCoordinator
        self.urlSession = URLSession(
            configuration: configuration,
            delegate: responseCoordinator,
            delegateQueue: nil
        )
    }

    func data(
        for request: URLRequest
    ) async throws -> (ByteString, URLResponse) {
        let requestID = try responseCoordinator.reserveRequest()
        return try await withTaskCancellationHandler {
            try await responseCoordinator.response(
                for: request,
                requestID: requestID,
                session: urlSession
            )
        } onCancel: {
            responseCoordinator.cancelRequest(requestID)
        }
    }

    func invalidate() {
        responseCoordinator.invalidate()
        urlSession.invalidateAndCancel()
    }

    deinit {
        invalidate()
    }
}
#endif
