import Foundation

/// A JSON value for command payloads: `null` stays distinct from an absent key ("clear" vs "unchanged").
nonisolated enum JSONPayload: Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONPayload])
    case object([String: JSONPayload])

    /// Compact JSON with sorted keys, as stored in the local queue.
    func encodedText() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    static func decode(_ text: String) throws -> JSONPayload {
        try JSONDecoder().decode(JSONPayload.self, from: Data(text.utf8))
    }
}

nonisolated extension JSONPayload: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONPayload].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONPayload].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

nonisolated extension JSONPayload: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONPayload...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONPayload)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
