import Foundation
import EventKit
import AppleBridgeProtocol

private let reminderPrefix = "x-apple-reminder://"

func dispatchReminder(_ request: BridgeRequest, store: EKEventStore) -> BridgeResponse {
    let deadline = Deadline()
    switch request.command {
    case .lists:
        return respond { try listsPage(store: store, deadline: deadline) }
    case .reminders:
        return respond { try readReminders(request, store: store, deadline: deadline) }
    case .create:
        return respond { try createReminder(request, store: store, deadline: deadline) }
    case .update:
        return respond { try updateReminder(request, store: store, deadline: deadline) }
    case .delete:
        return respond { try deleteReminder(request, store: store, deadline: deadline) }
    case .calendars, .events, .eventCreate, .eventUpdate, .eventDelete:
        return dispatchCalendar(request, store: store)
    }
}

/// Lists live here rather than in main.swift so every EventKit hop sits in one
/// file and shares the request deadline. The main-queue hop is defensive, not
/// proven necessary — the original no-response bug was a deallocated dispatch
/// source (see acceptSource in main.swift).
func listsPage(store: EKEventStore, deadline: Deadline) throws -> [ListInfo] {
    try onMain(deadline, hop: "list lookup") {
        let defaultId = store.defaultCalendarForNewReminders()?.calendarIdentifier
        return store.calendars(for: .reminder).map { calendar in
            ListInfo(
                id: calendar.calendarIdentifier,
                name: calendar.title,
                isDefault: calendar.calendarIdentifier == defaultId)
        }
    }
}

private func readReminders(
    _ request: BridgeRequest, store: EKEventStore, deadline: Deadline
) throws -> ReminderPage {
    // flagged true narrows the page. flagged false does not filter, and reading
    // the flag is not a write, so this path does not call rejectFlag.
    let query = ReminderQuery(
        status: request.status,
        search: request.search,
        dueAfter: request.dueAfter,
        dueBefore: request.dueBefore,
        flagged: request.flagged,
        priority: request.priority,
        limit: request.limit)
    let calendars = try onMain(deadline, hop: "list lookup") {
        try calendarsForQuery(store: store, request: request)
    }
    let items = try fetchReminders(store: store, calendars: calendars, deadline: deadline)
    let records = try onMain(deadline, hop: "reminder read") {
        try items.map { try makeRecord($0) }
    }
    return try reminderPage(
        records: records,
        query: query,
        scope: readScope(request: request, calendars: calendars))
}

/// How to describe what this read covered, so an empty page can be told apart from a
/// wrong question. `list` omitted means the default list — the trap that made "are my
/// reminders gone?" look true when only one of four lists was being read.
private func readScope(request: BridgeRequest, calendars: [EKCalendar]) -> String {
    let query = request.list ?? request.listId
    if let query, isAllLists(query) {
        return "all \(calendars.count) lists"
    }
    let title = calendars.first?.title ?? "unknown"
    return query == nil ? "default list \"\(title)\"" : "list \"\(title)\""
}

private func createReminder(
    _ request: BridgeRequest, store: EKEventStore, deadline: Deadline
) throws -> ReminderRecord {
    try rejectFlag(flagged: request.flagged)
    let title = try normalizeTitle(request.title ?? "")
    let priority = try priorityInt(request.priority ?? "none")
    let due = try request.due.map { try parseDue($0) }
    let notes = request.notes ?? ""
    return try onMain(deadline, hop: "reminder create") {
        let calendar = try calendarForQuery(store: store, request: request)
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = notes
        reminder.priority = priority
        if let due {
            applyDue(reminder, due)
        }
        try save(store, reminder)
        return try makeRecord(try findReminder(store, id: reminder.calendarItemIdentifier))
    }
}

private func updateReminder(
    _ request: BridgeRequest, store: EKEventStore, deadline: Deadline
) throws -> ReminderRecord {
    let id = request.reminderId ?? ""
    try rejectFlag(flagged: request.flagged)
    let clearDue = request.clearDue == true
    let changing = request.title != nil || request.notes != nil || request.list != nil
        || request.listId != nil || request.due != nil || request.priority != nil
        || request.completed != nil || request.flagged != nil
    try validateUpdate(changing: changing, due: request.due, clearDue: clearDue)
    let title = try request.title.map { try normalizeTitle($0) }
    let priority = try request.priority.map { try priorityInt($0) }
    let due = try request.due.map { try parseDue($0) }
    return try onMain(deadline, hop: "reminder update") {
        let reminder = try findReminder(store, id: id)
        if let title {
            reminder.title = title
        }
        if let notes = request.notes {
            reminder.notes = notes
        }
        if let priority {
            reminder.priority = priority
        }
        if clearDue {
            reminder.dueDateComponents = nil
        } else if let due {
            applyDue(reminder, due)
        }
        if let completed = request.completed {
            reminder.isCompleted = completed
        }
        if request.list != nil || request.listId != nil {
            reminder.calendar = try calendarForQuery(store: store, request: request)
        }
        try save(store, reminder)
        return try makeRecord(try findReminder(store, id: reminder.calendarItemIdentifier))
    }
}

private func deleteReminder(
    _ request: BridgeRequest, store: EKEventStore, deadline: Deadline
) throws -> DeletedReminder {
    let id = request.reminderId ?? ""
    return try onMain(deadline, hop: "reminder delete") {
        let reminder = try findReminder(store, id: id)
        let deleted = DeletedReminder(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            list: reminder.calendar?.title ?? "")
        try remove(store, reminder)
        return deleted
    }
}

/// The calendars a read should cover. `list: "all"` means every visible list; an
/// identifier or title means exactly one; omitting it means the default list.
private func calendarsForQuery(store: EKEventStore, request: BridgeRequest) throws -> [EKCalendar] {
    store.refreshSourcesIfNecessary()
    if let query = request.list ?? request.listId, isAllLists(query) {
        let all = store.calendars(for: .reminder).filter { $0.title != "Recently Deleted" }
        if all.isEmpty {
            throw ReminderFailure("No Reminders lists are available.")
        }
        return all
    }
    let lists = visibleLists(store)
    if let query = request.list ?? request.listId {
        let resolved = try resolveList(lists, query: query)
        guard let calendar = store.calendars(for: .reminder).first(where: {
            $0.calendarIdentifier == resolved.id
        }) else {
            throw ReminderFailure("No list named \"\(query)\".")
        }
        return [calendar]
    }
    guard let calendar = store.defaultCalendarForNewReminders(),
          lists.contains(where: { $0.id == calendar.calendarIdentifier }) else {
        throw ReminderFailure("No default Reminders list is available.")
    }
    return [calendar]
}

private func visibleLists(_ store: EKEventStore) -> [ListRef] {
    store.calendars(for: .reminder)
        .filter { $0.title != "Recently Deleted" }
        .map { ListRef(id: $0.calendarIdentifier, name: $0.title) }
}

/// The one calendar a write should target. `"all"` is a read scope, not a list you can
/// move a reminder into, so it is refused here rather than silently picking one.
private func calendarForQuery(store: EKEventStore, request: BridgeRequest) throws -> EKCalendar {
    let calendars = try calendarsForQuery(store: store, request: request)
    guard calendars.count == 1 else {
        throw ReminderFailure(
            "\"all\" reads every list; it is not a list you can write to. Name one list.")
    }
    return calendars[0]
}

private func fetchReminders(
    store: EKEventStore, calendars: [EKCalendar], deadline: Deadline
) throws -> [EKReminder] {
    precondition(!Thread.isMainThread, "must not block the main queue")
    let gate = DispatchSemaphore(value: 0)
    var fetched: [EKReminder]?
    DispatchQueue.main.async {
        let predicate = store.predicateForReminders(in: calendars)
        store.fetchReminders(matching: predicate) { reminders in
            fetched = reminders ?? []
            gate.signal()
        }
    }
    // A late callback writes the captured box after we throw; nobody reads it.
    try deadline.claim(gate, hop: "reminder fetch")
    return fetched ?? []
}

private func findReminder(_ store: EKEventStore, id: String) throws -> EKReminder {
    var keys = [id]
    if id.hasPrefix(reminderPrefix) {
        keys.append(String(id.dropFirst(reminderPrefix.count)))
    } else if !id.isEmpty {
        keys.append(reminderPrefix + id)
    }
    for key in keys where !key.isEmpty {
        if let reminder = store.calendarItem(withIdentifier: key) as? EKReminder {
            return reminder
        }
    }
    throw ReminderFailure("No reminder with id \"\(id)\".")
}

private func makeRecord(_ reminder: EKReminder) throws -> ReminderRecord {
    let id = reminder.calendarItemIdentifier
    let due = dueFields(reminder)
    return ReminderRecord(
        id: id,
        title: reminder.title ?? "",
        notes: reminder.notes ?? "",
        list: reminder.calendar?.title ?? "",
        listId: reminder.calendar?.calendarIdentifier ?? "",
        due: due?.format(),
        allDay: due?.allDay ?? false,
        priority: try priorityName(reminder.priority, reminderId: id),
        flagged: false,
        completed: reminder.isCompleted,
        completionTime: reminder.completionDate.map(formatTimestamp))
}

private func dueFields(_ reminder: EKReminder) -> DueInstant? {
    guard let components = reminder.dueDateComponents,
          let year = components.year, let month = components.month, let day = components.day else {
        return nil
    }
    if let hour = components.hour, let minute = components.minute,
       (0...23).contains(hour), (0...59).contains(minute) {
        return DueInstant(
            year: year, month: month, day: day, hour: hour, minute: minute, allDay: false)
    }
    return DueInstant(year: year, month: month, day: day, hour: 0, minute: 0, allDay: true)
}

private func applyDue(_ reminder: EKReminder, _ due: DueInstant) {
    var components = DateComponents()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    components.calendar = calendar
    components.timeZone = TimeZone.current
    components.year = due.year
    components.month = due.month
    components.day = due.day
    if !due.allDay {
        components.hour = due.hour
        components.minute = due.minute
    }
    reminder.dueDateComponents = components
}

func formatTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone.current
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return formatter.string(from: date)
}

private func save(_ store: EKEventStore, _ reminder: EKReminder) throws {
    do {
        try store.save(reminder, commit: true)
    } catch {
        throw ReminderFailure("Reminders failed: \(error.localizedDescription)")
    }
}

private func remove(_ store: EKEventStore, _ reminder: EKReminder) throws {
    do {
        try store.remove(reminder, commit: true)
    } catch {
        throw ReminderFailure("Reminders failed: \(error.localizedDescription)")
    }
}

func onMain<T>(
    _ deadline: Deadline, hop: String, _ work: @escaping () throws -> T
) throws -> T {
    precondition(!Thread.isMainThread, "must not block the main queue")
    var value: Result<T, Error>?
    let gate = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        value = Result(catching: work)
        gate.signal()
    }
    // A late work item writes the captured box after we throw; nobody reads it.
    try deadline.claim(gate, hop: hop)
    guard let value else {
        throw ReminderFailure("Reminders failed: \(hop) produced no result")
    }
    return try value.get()
}

func respond<T: Encodable>(_ body: () throws -> T) -> BridgeResponse {
    do {
        guard let result = jsonValue(from: try body()) else {
            return BridgeResponse(ok: false, error: "Reminders failed: could not encode the result")
        }
        return BridgeResponse(ok: true, result: result)
    } catch let error as ReminderFailure {
        return BridgeResponse(ok: false, error: error.message)
    } catch {
        return BridgeResponse(ok: false, error: "Reminders failed: \(error.localizedDescription)")
    }
}
