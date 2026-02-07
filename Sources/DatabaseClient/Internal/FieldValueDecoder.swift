import Foundation
import Core
import DatabaseClientProtocol

/// Converts between Persistable instances and [String: FieldValue] dictionaries
///
/// Uses JSON roundtrip via JSONSerialization to bridge between T's Codable
/// representation (raw values) and FieldValue's tagged representation.
enum FieldValueDecoder {

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Decode a [String: FieldValue] dictionary into a Persistable instance
    ///
    /// Strategy: [String: FieldValue] → raw dictionary → JSON → T
    static func decode<T: Persistable>(_ dict: [String: FieldValue]) throws -> T {
        let raw = dict.mapValues { fieldValueToJSON($0) }
        let jsonData = try JSONSerialization.data(withJSONObject: raw)
        return try decoder.decode(T.self, from: jsonData)
    }

    /// Encode a Persistable instance to [String: FieldValue]
    ///
    /// Strategy: T → JSON → raw dictionary → [String: FieldValue]
    static func encode<T: Persistable>(_ item: T) throws -> [String: FieldValue] {
        let jsonData = try encoder.encode(item)
        guard let raw = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected JSON object for \(T.self)"))
        }
        return raw.compactMapValues { jsonToFieldValue($0) }
    }

    /// Extract the ID as a string from a Persistable instance
    static func idString<T: Persistable>(_ item: T) -> String {
        if let stringID = item.id as? String {
            return stringID
        }
        if let data = try? encoder.encode(item.id),
           let str = String(data: data, encoding: .utf8) {
            return str.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return "\(item.id)"
    }

    // MARK: - Private helpers

    /// Convert a raw JSON value to FieldValue
    private static func jsonToFieldValue(_ value: Any) -> FieldValue? {
        // JSONSerialization returns NSNumber for booleans and numbers.
        // Check Bool first (NSNumber bridging: Bool check via CFBoolean)
        if let bool = value as? Bool {
            return .bool(bool)
        }
        if let int = value as? Int64 {
            return .int64(int)
        }
        if let int = value as? Int {
            return .int64(Int64(int))
        }
        if let double = value as? Double {
            // If the double is representable as Int64 without loss, prefer int64
            if double == Double(Int64(double)) && !double.isNaN && !double.isInfinite {
                return .int64(Int64(double))
            }
            return .double(double)
        }
        if let string = value as? String {
            return .string(string)
        }
        if let array = value as? [Any] {
            return .array(array.compactMap { jsonToFieldValue($0) })
        }
        if value is NSNull {
            return .null
        }
        return nil
    }

    /// Convert a FieldValue to a JSON-compatible value
    private static func fieldValueToJSON(_ fv: FieldValue) -> Any {
        switch fv {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int64(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .data(let d): return d.base64EncodedString()
        case .array(let arr): return arr.map { fieldValueToJSON($0) }
        }
    }
}
