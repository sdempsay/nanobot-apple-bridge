import Foundation

// Newline-delimited JSON over a Unix domain socket. One BridgeRequest per line,
// one BridgeResponse per line. A list is addressed by EventKit calendarIdentifier.
// A title is accepted only when exactly one visible list has that name — iCloud
// and On My Mac both ship a list named "Reminders".

public enum BridgeCommand: String, Codable, CaseIterable {
    case lists
    case reminders
    case create
    case update
    case delete
    case calendars
    case events
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
    /// List name or calendarIdentifier. The helper resolves an id before a title.
    public var list: String?
    public var status: String?
    public var search: String?
    public var dueAfter: String?
    public var dueBefore: String?
    public var priority: String?
    public var limit: Int?
    public var clearDue: Bool?
    public var flagged: Bool?

    public init(
        command: BridgeCommand,
        listId: String? = nil,
        reminderId: String? = nil,
        title: String? = nil,
        notes: String? = nil,
        due: String? = nil,
        completed: Bool? = nil,
        list: String? = nil,
        status: String? = nil,
        search: String? = nil,
        dueAfter: String? = nil,
        dueBefore: String? = nil,
        priority: String? = nil,
        limit: Int? = nil,
        clearDue: Bool? = nil,
        flagged: Bool? = nil
    ) {
        self.command = command
        self.listId = listId
        self.reminderId = reminderId
        self.title = title
        self.notes = notes
        self.due = due
        self.completed = completed
        self.list = list
        self.status = status
        self.search = search
        self.dueAfter = dueAfter
        self.dueBefore = dueBefore
        self.priority = priority
        self.limit = limit
        self.clearDue = clearDue
        self.flagged = flagged
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

// MARK: - Calendar (prototype)

public struct CalendarInfo: Codable, Equatable {
    public var id: String
    public var name: String
    public var isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

public struct EventRecord: Codable, Equatable {
    public var id: String
    public var title: String
    public var notes: String
    public var calendar: String
    public var calendarId: String
    public var start: String?
    public var end: String?
    public var allDay: Bool
    public var location: String
    public var url: String?

    enum CodingKeys: String, CodingKey {
        case id, title, notes, calendar, start, end, location, url
        case calendarId = "calendar_id"
        case allDay = "all_day"
    }

    public init(
        id: String,
        title: String,
        notes: String,
        calendar: String,
        calendarId: String,
        start: String?,
        end: String?,
        allDay: Bool,
        location: String,
        url: String?
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.calendar = calendar
        self.calendarId = calendarId
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.url = url
    }
}

public struct EventPage: Codable, Equatable {
    public var events: [EventRecord]
    public var matched: Int
    public var truncated: Bool
    public var scope: String?

    public init(
        events: [EventRecord],
        matched: Int,
        truncated: Bool,
        scope: String? = nil
    ) {
        self.events = events
        self.matched = matched
        self.truncated = truncated
        self.scope = scope
    }
}
