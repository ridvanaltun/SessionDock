import Foundation

/// A lossless JSON tree. Used wherever source-specific fields must be preserved
/// without a dedicated Swift type (metadata, unknown content parts, raw records).
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// Compact single-line JSON text, sorted keys for stable output.
    public var compactText: String {
        guard let data = try? JSONEncoder.sessionDock(sortedKeys: true, pretty: false).encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    public var prettyText: String {
        guard let data = try? JSONEncoder.sessionDock(sortedKeys: true, pretty: true).encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }
}

extension JSONEncoder {
    static func sessionDock(sortedKeys: Bool, pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = []
        if sortedKeys { formatting.insert(.sortedKeys) }
        if pretty { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        return encoder
    }
}
