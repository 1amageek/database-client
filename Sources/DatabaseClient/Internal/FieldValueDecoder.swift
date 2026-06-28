#if !os(WASI)
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

    /// Decode a [String: FieldValue] dictionary into a runtime Persistable type.
    static func decodeAny(
        _ dict: [String: FieldValue],
        as type: any Persistable.Type
    ) throws -> any Persistable {
        let raw = dict.mapValues { fieldValueToJSON($0) }
        let jsonData = try JSONSerialization.data(withJSONObject: raw)
        return try decoder.decode(type, from: jsonData)
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
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let type = String(cString: number.objCType)
            switch type {
            case "c", "s", "i", "l", "q", "C", "S", "I", "L", "Q":
                return .int64(number.int64Value)
            case "f", "d":
                let double = number.doubleValue
                if !double.isNaN && !double.isInfinite
                    && double >= Double(Int64.min) && double <= Double(Int64.max)
                    && double == Double(Int64(double)) {
                    return .int64(Int64(double))
                }
                return .double(double)
            default:
                return .double(number.doubleValue)
            }
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

#endif
