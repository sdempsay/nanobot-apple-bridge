import Foundation

/// User-facing failure from the Reminders rules. The message is the whole tool error.
public struct ReminderFailure: Error, CustomStringConvertible, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}

public enum ReminderText {
    public static let emptyTitle = "Title must not be empty."
    public static let invertedWindow = "due_after is later than due_before."
    public static let badLimit = "Limit must be an integer from 1 to 100."
    public static let badPriority = "Priority must be none, low, medium, or high."
    public static let badStatus = "Status must be open, completed, or any."
    public static let dueAndClear = "Pass either due or clear_due, not both."
    public static let emptyUpdate = "Update needs at least one field to change."
    public static let blankSearch = "Search must not be empty."
    public static let flagUnavailable = "The flag is not available through EventKit."
    public static let defaultPageSize = 50
}

/// A local calendar minute. All-day values use 00:00 as the sort point.
public struct DueMinute: Comparable, Equatable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int
    public var minute: Int

    public static func < (lhs: DueMinute, rhs: DueMinute) -> Bool {
        (lhs.year, lhs.month, lhs.day, lhs.hour, lhs.minute)
            < (rhs.year, rhs.month, rhs.day, rhs.hour, rhs.minute)
    }
}

/// A due value after parsing. Timed values are in the zone passed to `parseDue`.
public struct DueInstant: Equatable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int
    public var minute: Int
    public var allDay: Bool

    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, allDay: Bool) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.allDay = allDay
    }

    public func format() -> String {
        if allDay {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        return String(format: "%04d-%02d-%02dT%02d:%02d", year, month, day, hour, minute)
    }

    public func point() -> DueMinute {
        DueMinute(year: year, month: month, day: day, hour: allDay ? 0 : hour, minute: allDay ? 0 : minute)
    }

    /// Inclusive window. An all-day value covers that whole local day.
    public func span() -> (start: DueMinute, end: DueMinute) {
        if allDay {
            let start = DueMinute(year: year, month: month, day: day, hour: 0, minute: 0)
            let end = DueMinute(year: year, month: month, day: day, hour: 23, minute: 59)
            return (start, end)
        }
        let point = point()
        return (point, point)
    }
}

public struct ListRef: Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ReminderRecord: Codable, Equatable {
    public var id: String
    public var title: String
    public var notes: String
    public var list: String
    public var listId: String
    public var due: String?
    public var allDay: Bool
    public var priority: String
    public var flagged: Bool
    public var completed: Bool
    public var completionTime: String?

    enum CodingKeys: String, CodingKey {
        case id, title, notes, list, due, priority, flagged, completed
        case listId = "list_id"
        case allDay = "all_day"
        case completionTime = "completion_time"
    }

    public init(
        id: String,
        title: String,
        notes: String,
        list: String,
        listId: String,
        due: String?,
        allDay: Bool,
        priority: String,
        flagged: Bool,
        completed: Bool,
        completionTime: String?
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.list = list
        self.listId = listId
        self.due = due
        self.allDay = allDay
        self.priority = priority
        self.flagged = flagged
        self.completed = completed
        self.completionTime = completionTime
    }
}

public struct ReminderPage: Codable, Equatable {
    public var reminders: [ReminderRecord]
    public var matched: Int
    public var truncated: Bool
}

public struct ReminderQuery {
    public var status: String?
    public var search: String?
    public var dueAfter: String?
    public var dueBefore: String?
    public var flagged: Bool?
    public var priority: String?
    public var limit: Int?

    public init(
        status: String? = nil,
        search: String? = nil,
        dueAfter: String? = nil,
        dueBefore: String? = nil,
        flagged: Bool? = nil,
        priority: String? = nil,
        limit: Int? = nil
    ) {
        self.status = status
        self.search = search
        self.dueAfter = dueAfter
        self.dueBefore = dueBefore
        self.flagged = flagged
        self.priority = priority
        self.limit = limit
    }
}

public struct DeletedReminder: Codable, Equatable {
    public var id: String
    public var title: String
    public var list: String

    public init(id: String, title: String, list: String) {
        self.id = id
        self.title = title
        self.list = list
    }
}

public func parseDue(_ value: String, zone: TimeZone = .current) throws -> DueInstant {
    if value.contains(".") {
        throw ReminderFailure(badDue(value))
    }
    if let dated = match("^(\\d{4})-(\\d{2})-(\\d{2})$", value) {
        let year = int(dated[0])
        let month = int(dated[1])
        let day = int(dated[2])
        try checkDate(year: year, month: month, day: day, hour: 0, minute: 0, second: 0, original: value)
        return DueInstant(year: year, month: month, day: day, hour: 0, minute: 0, allDay: true)
    }
    if let zoned = match(
        "^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2})(?::(\\d{2}))?(Z|[+-]\\d{2}:?\\d{2})$",
        value
    ) {
        return try parseZoned(value, parts: zoned, zone: zone)
    }
    guard let local = match("^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2})(?::(\\d{2}))?$", value) else {
        throw ReminderFailure(badDue(value))
    }
    let year = int(local[0])
    let month = int(local[1])
    let day = int(local[2])
    let hour = int(local[3])
    let minute = int(local[4])
    let second = local.count > 5 ? int(local[5]) : 0
    try checkDate(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second, original: value)
    return DueInstant(year: year, month: month, day: day, hour: hour, minute: minute, allDay: false)
}

public func normalizeTitle(_ title: String) throws -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        throw ReminderFailure(ReminderText.emptyTitle)
    }
    return trimmed
}

public func priorityInt(_ name: String) throws -> Int {
    switch name {
    case "none":
        return 0
    case "low":
        return 9
    case "medium":
        return 5
    case "high":
        return 1
    default:
        throw ReminderFailure(ReminderText.badPriority)
    }
}

public func priorityName(_ raw: Int, reminderId: String) throws -> String {
    switch raw {
    case 0:
        return "none"
    case 1...4:
        return "high"
    case 5:
        return "medium"
    case 6...9:
        return "low"
    default:
        throw ReminderFailure(
            "Reminder \"\(reminderId)\" has priority \(raw), which is outside 0–9.")
    }
}

/// EventKit has no flag. Omitting it, or creating with `false`, is a no-op.
public func rejectFlag(flagged: Bool?, updating: Bool) throws {
    guard let flagged else {
        return
    }
    if !updating && !flagged {
        return
    }
    throw ReminderFailure(ReminderText.flagUnavailable)
}

public func validateUpdate(changing: Bool, due: String?, clearDue: Bool) throws {
    if clearDue && due != nil {
        throw ReminderFailure(ReminderText.dueAndClear)
    }
    if !changing && !clearDue {
        throw ReminderFailure(ReminderText.emptyUpdate)
    }
}

public func resolveList(_ lists: [ListRef], query: String) throws -> ListRef {
    let idHits = lists.filter { $0.id == query }
    if idHits.count == 1 {
        return idHits[0]
    }
    if idHits.count > 1 {
        throw ReminderFailure(ambiguousList(query, idHits))
    }
    let nameHits = lists.filter { $0.name == query }
    if nameHits.count == 1 {
        return nameHits[0]
    }
    if nameHits.isEmpty {
        let available = lists.map(\.name).joined(separator: ", ")
        let shown = available.isEmpty ? "(none)" : available
        throw ReminderFailure("No list named \"\(query)\". Available lists: \(shown).")
    }
    throw ReminderFailure(ambiguousList(query, nameHits))
}

public func reminderPage(
    records: [ReminderRecord],
    query: ReminderQuery,
    pageSize: Int = ReminderText.defaultPageSize,
    zone: TimeZone = .current
) throws -> ReminderPage {
    let status = query.status ?? "open"
    if status != "open" && status != "completed" && status != "any" {
        throw ReminderFailure(ReminderText.badStatus)
    }
    if let search = query.search, search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw ReminderFailure(ReminderText.blankSearch)
    }
    if query.priority != nil {
        _ = try priorityInt(query.priority ?? "")
    }
    let limit = try pageLimit(query.limit, pageSize: pageSize)
    let after = try query.dueAfter.map { try parseDue($0, zone: zone) }
    let before = try query.dueBefore.map { try parseDue($0, zone: zone) }
    if let after, let before, after.span().start > before.span().end {
        throw ReminderFailure(ReminderText.invertedWindow)
    }
    let matched = records.filter { record in
        matches(record, status: status, query: query, after: after, before: before)
    }.sorted { sortKey($0) < sortKey($1) }
    return ReminderPage(
        reminders: Array(matched.prefix(limit)),
        matched: matched.count,
        truncated: matched.count > limit)
}

private func matches(
    _ record: ReminderRecord,
    status: String,
    query: ReminderQuery,
    after: DueInstant?,
    before: DueInstant?
) -> Bool {
    if status == "open" && record.completed {
        return false
    }
    if status == "completed" && !record.completed {
        return false
    }
    if let search = query.search {
        let needle = fold(search)
        if !fold(record.title).contains(needle) && !fold(record.notes).contains(needle) {
            return false
        }
    }
    if after != nil || before != nil {
        guard let minute = minute(of: record) else {
            return false
        }
        if let after, minute < after.span().start {
            return false
        }
        if let before, minute > before.span().end {
            return false
        }
    }
    if query.flagged == true && !record.flagged {
        return false
    }
    if let priority = query.priority, record.priority != priority {
        return false
    }
    return true
}

private func sortKey(_ record: ReminderRecord) -> (Int, DueMinute, String, String) {
    let minute = minute(of: record)
    return (
        minute == nil ? 1 : 0,
        minute ?? DueMinute(year: 0, month: 0, day: 0, hour: 0, minute: 0),
        fold(record.title),
        record.id
    )
}

private func minute(of record: ReminderRecord) -> DueMinute? {
    guard let due = record.due else {
        return nil
    }
    if record.allDay {
        guard let parts = match("^(\\d{4})-(\\d{2})-(\\d{2})$", due) else {
            return nil
        }
        return DueMinute(year: int(parts[0]), month: int(parts[1]), day: int(parts[2]), hour: 0, minute: 0)
    }
    guard let parts = match("^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2})", due) else {
        return nil
    }
    return DueMinute(
        year: int(parts[0]), month: int(parts[1]), day: int(parts[2]),
        hour: int(parts[3]), minute: int(parts[4]))
}

private func pageLimit(_ limit: Int?, pageSize: Int) throws -> Int {
    guard let limit else {
        return pageSize
    }
    if !(1...100).contains(limit) {
        throw ReminderFailure(ReminderText.badLimit)
    }
    return limit
}

private func ambiguousList(_ query: String, _ hits: [ListRef]) -> String {
    let rendered = hits.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
    return "More than one list is named \"\(query)\": \(rendered)."
}

private func badDue(_ value: String) -> String {
    "Due value \"\(value)\" is not a calendar date or a local time."
}

private func parseZoned(_ value: String, parts: [String], zone: TimeZone) throws -> DueInstant {
    let year = int(parts[0])
    let month = int(parts[1])
    let day = int(parts[2])
    let hour = int(parts[3])
    let minute = int(parts[4])
    let second = parts.count > 5 && parts[5].allSatisfy(\.isNumber) ? int(parts[5]) : 0
    let offset = parts.last ?? "Z"
    try checkDate(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second, original: value)
    guard let source = TimeZone(secondsFromGMT: offsetSeconds(offset)) else {
        throw ReminderFailure(badDue(value))
    }
    var components = DateComponents()
    components.calendar = gregorian(source)
    components.timeZone = source
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    guard let date = gregorian(source).date(from: components) else {
        throw ReminderFailure(badDue(value))
    }
    let local = gregorian(zone).dateComponents([.year, .month, .day, .hour, .minute], from: date)
    guard let localYear = local.year, let localMonth = local.month, let localDay = local.day,
          let localHour = local.hour, let localMinute = local.minute else {
        throw ReminderFailure(badDue(value))
    }
    return DueInstant(
        year: localYear, month: localMonth, day: localDay,
        hour: localHour, minute: localMinute, allDay: false)
}

private func offsetSeconds(_ offset: String) -> Int {
    if offset == "Z" {
        return 0
    }
    let sign = offset.hasPrefix("-") ? -1 : 1
    let digits = offset.dropFirst().replacingOccurrences(of: ":", with: "")
    let hours = Int(digits.prefix(2)) ?? 0
    let minutes = Int(digits.dropFirst(2).prefix(2)) ?? 0
    return sign * ((hours * 3600) + (minutes * 60))
}

private func checkDate(
    year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, original: String
) throws {
    if !(0...23).contains(hour) || !(0...59).contains(minute) || !(0...59).contains(second) {
        throw ReminderFailure(badDue(original))
    }
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    let calendar = gregorian(TimeZone(secondsFromGMT: 0) ?? .gmt)
    guard let date = calendar.date(from: components) else {
        throw ReminderFailure(badDue(original))
    }
    let back = calendar.dateComponents([.year, .month, .day], from: date)
    if back.year != year || back.month != month || back.day != day {
        throw ReminderFailure(badDue(original))
    }
}

private func gregorian(_ zone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
}

private func fold(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
}

private func int(_ value: String) -> Int {
    Int(value) ?? 0
}

private func match(_ pattern: String, _ value: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }
    let range = NSRange(value.startIndex..., in: value)
    guard let found = regex.firstMatch(in: value, range: range), found.range == range else {
        return nil
    }
    var parts: [String] = []
    for index in 1..<found.numberOfRanges {
        let part = found.range(at: index)
        if part.location == NSNotFound {
            continue
        }
        guard let swiftRange = Range(part, in: value) else {
            continue
        }
        parts.append(String(value[swiftRange]))
    }
    return parts
}
