#if os(WASI)
import DatabaseClient
import DatabaseTypes
import JavaScriptKit

public struct JavaScriptDatabaseTransport: DatabaseTransport {
    public let configuration: JavaScriptDatabaseConfiguration

    public nonisolated init(
        configuration: JavaScriptDatabaseConfiguration = .default
    ) {
        self.configuration = configuration
    }

    public func send(
        _ request: ByteString
    ) async throws(DatabaseTransportError) -> ByteString {
        guard request.count <= configuration.maximumRequestBytes else {
            throw .rejected(
                code: "request_too_large",
                message: "Database request exceeds the configured byte limit"
            )
        }
        guard let requestEntrypoint = JSObject.global[
            configuration.requestEntrypointName
        ].function else {
            throw .unavailable(
                "Database request entrypoint is not installed"
            )
        }

        // JavaScriptKit copies Wasm memory into a JavaScript-owned TypedArray.
        // The Promise can outlive this synchronous borrow.
        let requestPayload = request.withUnsafeBytes { bytes in
            JSUint8Array(buffer: bytes.bindMemory(to: UInt8.self))
        }
        guard let responsePromise = JSPromise(
            from: requestEntrypoint(requestPayload.jsValue)
        ) else {
            throw .invalidResponse(
                "Database request entrypoint did not return a Promise"
            )
        }
        let pendingRequest = PendingJavaScriptRequest(
            timeoutMilliseconds: configuration.requestTimeoutMilliseconds,
            maximumResponseBytes: configuration.maximumResponseBytes
        )
        return try await pendingRequest.wait(for: responsePromise).get()
    }
}
#endif
