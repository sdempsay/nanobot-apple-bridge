import Foundation

// Newline-delimited JSON over a Unix domain socket. One BridgeRequest per line,
// one BridgeResponse per line. Lists are addressed by EventKit calendarIdentifier
// (`listId`) — never by title, which collides across sources (iCloud and On My
// Mac both ship a "Reminders" list).

public enum BridgeCommand: String, Codable, CaseIterable {
    case lists
    case reminders
    case create
    case update
    case delete
}

public struct BridgeRequest: Codable {
    public var command: BridgeCommand
    public var listId: String?
    public var reminderId: String?
    public var title: String?
    public var notes: String?
    /// ISO 8601 date or datetime, interpreted in the helper's local zone.
    public var due: String?
    public var completed: Bool?

    public init(
        command: BridgeCommand,
        listId: String? = nil,
        reminderId: String? = nil,
        title: String? = nil,
        notes: String? = nil,
        due: String? = nil,
        completed: Bool? = nil
    ) {
        self.command = command
        self.listId = listId
        self.reminderId = reminderId
        self.title = title
        self.notes = notes
        self.due = due
        self.completed = completed
    }
}

public struct BridgeResponse: Codable {
    public var ok: Bool
    public var error: String?
    public var result: JSONValue?

    public init(ok: Bool, error: String? = nil, result: JSONValue? = nil) {
        self.ok = ok
        self.error = error
        self.result = result
    }
}

public struct ListInfo: Codable {
    /// EventKit calendarIdentifier — the stable wire address for a list.
    public var id: String
    public var name: String
    public var isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// Minimal recursive JSON value so the protocol module can carry any command's
/// payload without the helper and MCP targets sharing concrete EventKit types.
public enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
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
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "value is not valid JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public func jsonValue<T: Encodable>(from value: T) -> JSONValue? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
}

public let bridgeSocketPath: String =
    FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/apple-bridge/helper.sock")
    .path
