#if !os(WASI)
import DatabaseClientProtocol
import Foundation

public struct TypedCommand<Payload: Encodable & Sendable, Response: Decodable & Sendable>: Sendable {
    public let commandID: String
    public let payload: Payload
    public let idempotencyKey: IdempotencyKey?
    public let preconditions: [WritePreconditionEntry]
    public let metadata: [String: String]
    public let envelopeMetadata: [String: String]
    public let responseType: Response.Type

    public init(
        _ commandID: String,
        payload: Payload,
        responseType: Response.Type = Response.self,
        idempotencyKey: IdempotencyKey? = nil,
        preconditions: [WritePreconditionEntry] = [],
        metadata: [String: String] = [:],
        envelopeMetadata: [String: String] = [:]
    ) {
        self.commandID = commandID
        self.payload = payload
        self.responseType = responseType
        self.idempotencyKey = idempotencyKey
        self.preconditions = preconditions
        self.metadata = metadata
        self.envelopeMetadata = envelopeMetadata
    }
}

#endif
