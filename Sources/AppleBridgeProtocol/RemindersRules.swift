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
    public static let flagUnavailable =
        "The flag is not available through EventKit — omit the flagged field and retry."
    public static let defaultPageSize = 50
    public static let invertedEventWindow = "start_after is later than start_before."
    public static let eventWindowTooWide =
        "The event window is wider than \(maxEventWindowDays) days. Read a shorter range — "
        + "start_after and start_before can each be omitted, and the window never starts in the past."
    public static let recurringRefused =
        "\"\(recurringSubject)\" is a recurring event, and recurring events are read-only. "
        + "apple-bridge will not guess whether you meant this occurrence or the whole series, "
        + "because getting that wrong edits every future event. Change it in Calendar."
    public static let recurrenceUnsupported =
        "Recurrence is not supported — apple-bridge will not create a repeating event, because it "
        + "cannot read one back correctly. Create a single event instead."
    public static let recurringSubject = "That event"
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
    /// What the read actually covered, e.g. `all 4 lists`, `list "Work"`, or
    /// `default list "Reminders"`. A caller that asked for "everything" and got a
    /// default-list-only read needs to see this.
    public var scope: String?
    /// Only the filters that really narrowed the read. Empty means unfiltered.
    /// Weak callers stuff `due_after`/`priority`/`search` with permissive-looking
    /// values that are in fact filters; echoing them makes a `matched: 0` explainable.
    public var filters: [String: String]?
    /// One line of guidance, present only when the result is likely to surprise the
    /// caller (nothing matched, or a due window silently dropped undated reminders).
    public var note: String?

    public init(
        reminders: [ReminderRecord],
        matched: Int,
        truncated: Bool,
        scope: String? = nil,
        filters: [String: String]? = nil,
        note: String? = nil
    ) {
        self.reminders = reminders
        self.matched = matched
        self.truncated = truncated
        self.scope = scope
        self.filters = filters
        self.note = note
    }
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

/// EventKit cannot read or write the flag, so `true` is impossible and fails.
/// `false` (or omitted) is a truthful no-op on create *and* update: every record
/// already reports `flagged: false`, so that end state holds. Update used to
/// reject `false`, which broke the common read → echo → update loop, because a
/// record read back carries `flagged: false`.
public func rejectFlag(flagged: Bool?) throws {
    guard flagged == true else {
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

/// `list: "all"` reads every visible list in one call. Weak callers otherwise have
/// to loop lists and merge pages themselves, which is where reminders get dropped.
/// Reserved word: a list literally named "all" is still reachable by its
/// calendarIdentifier, and an identifier always wins over a title.
public let allListsSentinel = "all"

public func isAllLists(_ query: String) -> Bool {
    query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == allListsSentinel
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
    zone: TimeZone = .current,
    scope: String? = nil
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
    let hasWindow = after != nil || before != nil
    let undatedExcluded = hasWindow ? records.filter { $0.due == nil }.count : 0
    return ReminderPage(
        reminders: Array(matched.prefix(limit)),
        matched: matched.count,
        truncated: matched.count > limit,
        scope: scope,
        filters: effectiveFilters(
            status: status, query: query, after: query.dueAfter, before: query.dueBefore),
        note: pageNote(
            matched: matched.count, fetched: records.count, scope: scope,
            undatedExcluded: undatedExcluded, hasWindow: hasWindow))
}

/// The filters that actually narrowed this read. `status` is always a filter unless it
/// is `any` — omitting it means open-only, which is the single most common surprise.
/// `flagged: false` and blank strings are no-ops, so they are not echoed.
private func effectiveFilters(
    status: String,
    query: ReminderQuery,
    after: String?,
    before: String?
) -> [String: String]? {
    var applied: [String: String] = [:]
    if status != "any" {
        applied["status"] = status
    }
    if let search = query.search {
        applied["search"] = search
    }
    if let priority = query.priority {
        applied["priority"] = priority
    }
    if query.flagged == true {
        applied["flagged"] = "true"
    }
    if let after, let before {
        applied["due"] = "\(after)..\(before)"
    } else if let after {
        applied["due_after"] = after
    } else if let before {
        applied["due_before"] = before
    }
    return applied.isEmpty ? nil : applied
}

/// Only says something when the caller is likely to misread an empty or narrowed page.
/// This text lands in the model's context on the next turn, so it stays to one line.
private func pageNote(
    matched: Int,
    fetched: Int,
    scope: String?,
    undatedExcluded: Int,
    hasWindow: Bool
) -> String? {
    var parts: [String] = []
    if matched == 0 && fetched > 0 {
        parts.append("nothing matched these filters; \(fetched) reminder(s) exist in this scope")
    } else if matched == 0, let scope, scope.hasPrefix("default list") {
        parts.append("this read covered only \(scope); call reminders_all to read every list")
    }
    if hasWindow && undatedExcluded > 0 {
        parts.append("\(undatedExcluded) reminder(s) with no due date were excluded by the due window — omit due_after/due_before to include them")
    }
    return parts.isEmpty ? nil : parts.joined(separator: "; ")
}

// MARK: - Event read rules
//
// EventKit filters events with a predicate, not by fetching everything and
// filtering afterwards, so unlike Reminders the `records` handed to `eventPage`
// are already the matched set. The rules here are about the one thing EventKit
// *cannot* express to the caller: the window it actually searched, and the fact
// that a defaulted window is a real narrowing rather than a neutral default.

public let maxEventWindowDays = 62
public let defaultEventWindowDays = 7

/// A local calendar minute turned into an absolute instant. Used for the event
/// window, where EventKit needs real `Date`s rather than the minute pairs the
/// reminder rules compare.
public func date(for minute: DueMinute, zone: TimeZone = .current) -> Date? {
    var components = DateComponents()
    components.year = minute.year
    components.month = minute.month
    components.day = minute.day
    components.hour = minute.hour
    components.minute = minute.minute
    return gregorian(zone).date(from: components)
}

public struct EventQuery {
    public var calendar: String?
    public var startAfter: String?
    public var startBefore: String?
    public var limit: Int?

    public init(calendar: String? = nil, startAfter: String? = nil, startBefore: String? = nil, limit: Int? = nil) {
        self.calendar = calendar
        self.startAfter = startAfter
        self.startBefore = startBefore
        self.limit = limit
    }
}

/// The range that was actually searched, and what the caller did to get there.
public struct EventWindow: Equatable {
    /// Inclusive lower bound, in the helper's local zone.
    public var start: Date
    /// Exclusive upper bound for the EventKit predicate. `end` is the last searched
    /// *minute*, so it carries one extra minute; see `resolveEventWindow`.
    public var end: Date
    /// The same range as the caller would write it, for the result to quote back.
    public var display: String
    /// True when the caller named neither bound, so the window is a narrowing choice
    /// this code made on their behalf and the result has to say so.
    public var isDefaulted: Bool
    /// The caller's own bounds, for `filters`. Empty when both were omitted.
    public var filters: [String: String]?
}

/// Resolve the event window. An omitted bound is never widened: no lower bound
/// means "from now", not "from the beginning of time", and no upper bound means
/// a bounded lookahead rather than an unbounded fetch. The width is capped
/// because the fetch is synchronous on the main queue — an unbounded window is
/// a UI stall, so it is refused rather than silently truncated.
public func resolveEventWindow(
    _ query: EventQuery,
    now: Date = Date(),
    zone: TimeZone = .current
) throws -> EventWindow {
    let after = try query.startAfter.map { try parseDue($0, zone: zone) }
    let before = try query.startBefore.map { try parseDue($0, zone: zone) }
    if let after, let before, after.span().start > before.span().end {
        throw ReminderFailure(ReminderText.invertedEventWindow)
    }
    let start = after.flatMap { date(for: $0.span().start, zone: zone) } ?? now
    let lastMinute = before.flatMap { date(for: $0.span().end, zone: zone) }
        ?? now.addingTimeInterval(Double(defaultEventWindowDays) * 86400)
    if lastMinute.timeIntervalSince(start) > Double(maxEventWindowDays) * 86400 {
        throw ReminderFailure(ReminderText.eventWindowTooWide)
    }
    var applied: [String: String] = [:]
    switch (after, before) {
    case (.some, .some):
        applied["start"] = "\(query.startAfter ?? "")..\(query.startBefore ?? "")"
    case (.some, .none):
        applied["start_after"] = query.startAfter ?? ""
    case (.none, .some):
        applied["start_before"] = query.startBefore ?? ""
    case (.none, .none):
        break
    }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = zone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return EventWindow(
        start: start,
        end: lastMinute.addingTimeInterval(60),
        display: "\(formatter.string(from: start))..\(formatter.string(from: lastMinute))",
        isDefaulted: after == nil && before == nil,
        filters: applied.isEmpty ? nil : applied)
}

public func eventPage(
    records: [EventRecord],
    window: EventWindow,
    scope: String,
    limit: Int?,
    pageSize: Int = ReminderText.defaultPageSize
) throws -> EventPage {
    let capped = try pageLimit(limit, pageSize: pageSize)
    // Undated last, then start, then title — the same key the reminder page uses.
    // Comparing raw start strings would sort a nil "" ahead of every real date.
    let sorted = records.sorted { a, b in
        let left = a.start ?? ""
        let right = b.start ?? ""
        if (left.isEmpty ? 1 : 0, left, a.title) != (right.isEmpty ? 1 : 0, right, b.title) {
            return (left.isEmpty ? 1 : 0, left, a.title) < (right.isEmpty ? 1 : 0, right, b.title)
        }
        return a.id < b.id
    }
    return EventPage(
        events: Array(sorted.prefix(capped)),
        matched: sorted.count,
        truncated: sorted.count > capped,
        scope: scope,
        window: window.display,
        filters: window.filters,
        note: eventPageNote(
            matched: sorted.count, scope: scope, window: window, truncated: sorted.count > capped))
}

/// Only says something when the result is likely to be misread. Unlike the
/// reminder page there is no matched-vs-fetched gap to explain, because
/// EventKit did the filtering — so the two real traps are a defaulted window
/// and a defaulted calendar, both of which turn "not here" into "not at all".
private func eventPageNote(
    matched: Int, scope: String, window: EventWindow, truncated: Bool
) -> String? {
    var parts: [String] = []
    if matched == 0 {
        parts.append(
            "no event starts inside \(window.display); that is a statement about the window, "
            + "not about the calendar")
        if window.isDefaulted {
            parts.append("pass start_after and start_before to search other dates")
        }
        if scope.hasPrefix("default calendar") {
            parts.append("this read covered only \(scope); call events_upcoming for every calendar")
        }
    } else if truncated {
        parts.append("the page was capped; more events match inside \(window.display)")
    }
    return parts.isEmpty ? nil : parts.joined(separator: "; ")
}

// MARK: - Event write rules

/// Default length for a timed event created without an end.
public let defaultEventMinutes = 60

/// The start/end/all-day triple a create or update should apply, with EventKit's
/// own conventions filled in. A date-only `start` means an all-day event, and an
/// all-day event runs to midnight at the start of the next day — EventKit's
/// exclusive end. `end` is ignored for an all-day event, because a caller passing
/// "2026-10-01" for both bounds means one day, not zero.
public func eventTimes(
    start: String?,
    end: String?,
    allDay: Bool?,
    required: Bool,
    zone: TimeZone = .current,
    now: Date = Date()
) throws -> (start: Date, end: Date, allDay: Bool)? {
    guard let start else {
        if required {
            throw ReminderFailure("An event needs a start — pass start as YYYY-MM-DD or YYYY-MM-DDTHH:MM.")
        }
        return nil
    }
    let startAt = try parseDue(start, zone: zone)
    let isAllDay = allDay ?? startAt.allDay
    let startDate = date(for: startAt.span().start, zone: zone) ?? now
    if isAllDay {
        // Add a real day, not day+1: 2026-10-31 + 1 is not the 32nd of anything.
        let nextDay = gregorian(zone).date(byAdding: .day, value: 1, to: startDate)
        return (startDate, nextDay ?? startDate.addingTimeInterval(86400), true)
    }
    guard let end, !end.isEmpty else {
        return (startDate, startDate.addingTimeInterval(Double(defaultEventMinutes) * 60), false)
    }
    let endAt = try parseDue(end, zone: zone)
    let endDate = date(for: endAt.point(), zone: zone) ?? startDate
    guard endDate > startDate else {
        throw ReminderFailure("An event's end must be after its start — end \(end) is not after start \(start).")
    }
    return (startDate, endDate, false)
}

/// Recurring events are read-only, by decision rather than by limitation of
/// effort. EventKit has no "edit this occurrence only" API, so a write to an
/// expanded occurrence would have to choose between the series and the single
/// event, and the wrong choice silently rewrites every future occurrence.
/// This lives here, not in the tool description, because a model that skipped
/// reading the description still has to be stopped.
public func rejectRecurring(_ recurring: Bool, title: String, id: String) throws {
    guard recurring else { return }
    throw ReminderFailure(
        "Event \"\(title)\" (\(id)) recurs, and recurring events are read-only: "
        + "apple-bridge will not guess whether you meant this occurrence or the whole series, "
        + "because the wrong choice edits every future event. Change it in Calendar.")
}

/// Reject an update that would change nothing, mirroring the reminder rule.
public func validateEventUpdate(changing: Bool) throws {
    guard changing else {
        throw ReminderFailure("Update needs at least one field to change.")
    }
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
