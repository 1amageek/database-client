import Foundation
import Core
import DatabaseClientProtocol

/// Converts between Persistable instances and [String: FieldValue] dictionaries
///
/// Uses JSON roundtrip via Codable for reliable encoding/decoding.
enum FieldValueDecoder {

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Decode a [String: FieldValue] dictionary into a Persistable instance
    ///
    /// Strategy: Convert [String: FieldValue] → JSON → T (via Codable)
    static func decode<T: Persistable>(_ dict: [String: FieldValue]) throws -> T {
        let jsonData = try encoder.encode(dict)
        return try decoder.decode(T.self, from: jsonData)
    }

    /// Encode a Persistable instance to [String: FieldValue]
    ///
    /// Strategy: T → JSON → [String: FieldValue]
    static func encode<T: Persistable>(_ item: T) throws -> [String: FieldValue] {
        let jsonData = try encoder.encode(item)
        return try decoder.decode([String: FieldValue].self, from: jsonData)
    }

    /// Extract the ID as a string from a Persistable instance
    static func idString<T: Persistable>(_ item: T) -> String {
        // ID conforms to Codable, encode to JSON and extract
        if let stringID = item.id as? String {
            return stringID
        }
        if let data = try? encoder.encode(item.id),
           let str = String(data: data, encoding: .utf8) {
            // Remove quotes if JSON string
            return str.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return "\(item.id)"
    }
}
