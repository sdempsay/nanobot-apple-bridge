import Foundation
import EventKit
import AppleBridgeProtocol

private let reminderPrefix = "x-apple-reminder://"
private let fetchTimeoutSeconds: TimeInterval = 25

func dispatchReminder(_ request: BridgeRequest, store: EKEventStore) -> BridgeResponse {
    switch request.command {
    case .lists:
        return BridgeResponse(ok: true, result: jsonValue(from: reminderListsOnMain(store: store)))
    case .reminders:
        return respond { try readReminders(request, store: store) }
    case .create:
        return respond { try createReminder(request, store: store) }
    case .update:
        return respond { try updateReminder(request, store: store) }
    case .delete:
        return respond { try deleteReminder(request, store: store) }
    }
}

private func readReminders(_ request: BridgeRequest, store: EKEventStore) throws -> ReminderPage {
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
    let calendar = try onMain { try calendarForQuery(store: store, request: request) }
    let items = try fetchReminders(store: store, calendar: calendar)
    let records = try onMain { try items.map { try makeRecord($0) } }
    return try reminderPage(records: records, query: query)
}

private func createReminder(_ request: BridgeRequest, store: EKEventStore) throws -> ReminderRecord {
    try rejectFlag(flagged: request.flagged, updating: false)
    let title = try normalizeTitle(request.title ?? "")
    let priority = try priorityInt(request.priority ?? "none")
    let due = try request.due.map { try parseDue($0) }
    let notes = request.notes ?? ""
    return try onMain {
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

private func updateReminder(_ request: BridgeRequest, store: EKEventStore) throws -> ReminderRecord {
    let id = request.reminderId ?? ""
    try rejectFlag(flagged: request.flagged, updating: true)
    let clearDue = request.clearDue == true
    let changing = request.title != nil || request.notes != nil || request.list != nil
        || request.listId != nil || request.due != nil || request.priority != nil
        || request.completed != nil || request.flagged != nil
    try validateUpdate(changing: changing, due: request.due, clearDue: clearDue)
    let title = try request.title.map { try normalizeTitle($0) }
    let priority = try request.priority.map { try priorityInt($0) }
    let due = try request.due.map { try parseDue($0) }
    return try onMain {
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

private func deleteReminder(_ request: BridgeRequest, store: EKEventStore) throws -> DeletedReminder {
    let id = request.reminderId ?? ""
    return try onMain {
        let reminder = try findReminder(store, id: id)
        let deleted = DeletedReminder(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            list: reminder.calendar?.title ?? "")
        try remove(store, reminder)
        return deleted
    }
}

private func calendarForQuery(store: EKEventStore, request: BridgeRequest) throws -> EKCalendar {
    store.refreshSourcesIfNecessary()
    let lists = visibleLists(store)
    if let query = request.list ?? request.listId {
        let resolved = try resolveList(lists, query: query)
        guard let calendar = store.calendars(for: .reminder).first(where: {
            $0.calendarIdentifier == resolved.id
        }) else {
            throw ReminderFailure("No list named \"\(query)\".")
        }
        return calendar
    }
    guard let calendar = store.defaultCalendarForNewReminders(),
          lists.contains(where: { $0.id == calendar.calendarIdentifier }) else {
        throw ReminderFailure("No default Reminders list is available.")
    }
    return calendar
}

private func visibleLists(_ store: EKEventStore) -> [ListRef] {
    store.calendars(for: .reminder)
        .filter { $0.title != "Recently Deleted" }
        .map { ListRef(id: $0.calendarIdentifier, name: $0.title) }
}

private func fetchReminders(store: EKEventStore, calendar: EKCalendar) throws -> [EKReminder] {
    precondition(!Thread.isMainThread, "must not block the main queue")
    let gate = DispatchSemaphore(value: 0)
    var fetched: [EKReminder]?
    DispatchQueue.main.async {
        let predicate = store.predicateForReminders(in: [calendar])
        store.fetchReminders(matching: predicate) { reminders in
            fetched = reminders ?? []
            gate.signal()
        }
    }
    if gate.wait(timeout: .now() + fetchTimeoutSeconds) == .timedOut {
        throw ReminderFailure("Reminders did not answer within 25 seconds.")
    }
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

private func formatTimestamp(_ date: Date) -> String {
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

private func onMain<T>(_ work: @escaping () throws -> T) throws -> T {
    precondition(!Thread.isMainThread, "must not block the main queue")
    var value: Result<T, Error>?
    let gate = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        value = Result(catching: work)
        gate.signal()
    }
    gate.wait()
    guard let value else {
        throw ReminderFailure("Reminders failed: the main queue did not answer")
    }
    return try value.get()
}

private func respond<T: Encodable>(_ body: () throws -> T) -> BridgeResponse {
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
