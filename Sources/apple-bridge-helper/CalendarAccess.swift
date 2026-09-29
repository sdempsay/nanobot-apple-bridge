import Foundation
import EventKit
import AppleBridgeProtocol

// Calendar read only. No create/update/delete yet.
// Follows the Reminders shape: main-queue hops under one request Deadline.

func dispatchCalendar(_ request: BridgeRequest, store: EKEventStore) -> BridgeResponse {
    let deadline = Deadline()
    switch request.command {
    case .calendars:
        return respond { try calendarList(store: store, deadline: deadline) }
    case .events:
        return respond { try readEvents(request, store: store, deadline: deadline) }
    case .eventCreate:
        return respond { try createEvent(request, store: store, deadline: deadline) }
    case .eventUpdate:
        return respond { try updateEvent(request, store: store, deadline: deadline) }
    case .eventDelete:
        return respond { try deleteEvent(request, store: store, deadline: deadline) }
    default:
        return BridgeResponse(ok: false, error: "not a calendar command")
    }
}

func calendarList(store: EKEventStore, deadline: Deadline) throws -> [CalendarInfo] {
    try onMain(deadline, hop: "calendar lookup") {
        let defaultId = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event).map { calendar in
            CalendarInfo(
                id: calendar.calendarIdentifier,
                name: calendar.title,
                isDefault: calendar.calendarIdentifier == defaultId)
        }
    }
}

private func readEvents(
    _ request: BridgeRequest, store: EKEventStore, deadline: Deadline
) throws -> EventPage {
    let query = EventQuery(
        calendar: request.list ?? request.listId,
        startAfter: request.startAfter,
        startBefore: request.startBefore,
        limit: request.limit)
    let window = try resolveEventWindow(query)
    let calendars = try onMain(deadline, hop: "calendar lookup") {
        try calendarsForEventQuery(store: store, request: request)
    }
    // Unlike reminders, EventKit's event fetch is SYNCHRONOUS — it returns the
    // array directly rather than calling back. So there is no semaphore hop and
    // no second Deadline claim here, unlike fetchReminders. The work still runs on
    // the main queue, which is why the window is width-capped upstream.
    let events = try onMain(deadline, hop: "event read") {
        let predicate = store.predicateForEvents(
            withStart: window.start, end: window.end, calendars: calendars)
        return store.events(matching: predicate)
    }
    let records = events.map { makeEventRecord($0) }
    return try eventPage(
        records: records,
        window: window,
        scope: eventScope(request: request, calendars: calendars),
        limit: query.limit)
}

/// The same trap the reminder side guards: a caller who asks about "my calendar"
/// and gets one calendar's events. `default calendar` is called out by name so the
/// note can fire on an empty page.
private func eventScope(request: BridgeRequest, calendars: [EKCalendar]) -> String {
    let query = request.list ?? request.listId
    if let query, isAllLists(query) {
        return "all \(calendars.count) calendars"
    }
    let title = calendars.first?.title ?? "unknown"
    return query == nil ? "default calendar \"\(title)\"" : "calendar \"\(title)\""
}

private func calendarsForEventQuery(
    store: EKEventStore, request: BridgeRequest
) throws -> [EKCalendar] {
    store.refreshSourcesIfNecessary()
    let all = store.calendars(for: .event).filter { $0.title != "Recently Deleted" }
    if let query = request.list ?? request.listId, isAllLists(query) {
        guard !all.isEmpty else { throw ReminderFailure("No calendars are available.") }
        return all
    }
    let refs = all.map { ListRef(id: $0.calendarIdentifier, name: $0.title) }
    if let query = request.list ?? request.listId {
        let resolved = try resolveList(refs, query: query)
        guard let calendar = all.first(where: { $0.calendarIdentifier == resolved.id }) else {
            throw ReminderFailure("No calendar named \"\(query)\".")
        }
        return [calendar]
    }
    guard let calendar = store.defaultCalendarForNewEvents else {
        throw ReminderFailure("No default calendar is available.")
    }
    return [calendar]
}

/// EKEvent has no `isRecurring`. Recurrence lives on `recurrenceRules` on the
/// superclass, and a non-nil *empty* array is not recurring — only a non-empty
/// one is. Getting this wrong in the permissive direction would refuse ordinary
/// events, so the emptiness check is the point.
private func isRecurringEvent(_ event: EKEvent) -> Bool {
    !(event.recurrenceRules ?? []).isEmpty
}

private func makeEventRecord(_ event: EKEvent) -> EventRecord {    EventRecord(
        // calendarItemIdentifier, NOT eventIdentifier. Apple documents the latter
        // as changing when an event moves between calendars and possibly on sync,
        // so it is not a handle a caller can come back with. EKEvent is an
        // EKCalendarItem, so the stable identifier is available — and it is what
        // the reminder side already uses.
        id: event.calendarItemIdentifier,
        title: event.title ?? "",
        notes: event.notes ?? "",
        calendar: event.calendar?.title ?? "",
        calendarId: event.calendar?.calendarIdentifier ?? "",
        start: event.startDate.map(formatTimestamp),
        end: event.endDate.map(formatTimestamp),
        allDay: event.isAllDay,
        location: event.location ?? "",
        url: event.url?.absoluteString,
        recurring: isRecurringEvent(event))
}

// MARK: - Writes

private func createEvent(
    _ request: BridgeRequest, store: EKEventStore, deadline: Deadline
) throws -> EventRecord {
    let title = try normalizeTitle(request.title ?? "")
    guard let times = try eventTimes(
        start: request.start, end: request.end, allDay: request.allDay, required: true)
    else {
        throw ReminderFailure("An event needs a start.")
    }
    return try onMain(deadline, hop: "event create") {
        let calendar = try calendarForWrite(store: store, request: request)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.notes = request.notes ?? ""
        event.location = request.location ?? ""
        event.startDate = times.start
        event.endDate = times.end
        event.isAllDay = times.allDay
        if let url = request.url, !url.isEmpty {
            event.url = URL(string: url)
        }
        try saveEvent(store, event)
        return makeEventRecord(try findEvent(store, id: event.calendarItemIdentifier))
    }
}

private func updateEvent(
    _ request: BridgeRequest, store: EKEventStore, deadline: Deadline
) throws -> EventRecord {
    let id = request.eventId ?? ""
    try validateEventUpdate(changing: changingFields(request))
    let times = try eventTimes(
        start: request.start, end: request.end, allDay: request.allDay, required: false)
    return try onMain(deadline, hop: "event update") {
        let event = try findEvent(store, id: id)
        try rejectRecurring(isRecurringEvent(event), title: event.title ?? "", id: id)
        if let title = request.title {
            event.title = try normalizeTitle(title)
        }
        if let notes = request.notes {
            event.notes = notes
        }
        if let location = request.location {
            event.location = location
        }
        if let times {
            event.startDate = times.start
            event.endDate = times.end
            event.isAllDay = times.allDay
        }
        if request.list != nil || request.listId != nil {
            event.calendar = try calendarForWrite(store: store, request: request)
        }
        try saveEvent(store, event)
        return makeEventRecord(try findEvent(store, id: event.calendarItemIdentifier))
    }
}

private func deleteEvent(
    _ request: BridgeRequest, store: EKEventStore, deadline: Deadline
) throws -> DeletedEvent {
    let id = request.eventId ?? ""
    return try onMain(deadline, hop: "event delete") {
        let event = try findEvent(store, id: id)
        try rejectRecurring(isRecurringEvent(event), title: event.title ?? "", id: id)
        let deleted = DeletedEvent(
            id: event.calendarItemIdentifier,
            title: event.title ?? "",
            calendar: event.calendar?.title ?? "",
            calendarId: event.calendar?.calendarIdentifier ?? "")
        try removeEvent(store, event)
        return deleted
    }
}

private func changingFields(_ request: BridgeRequest) -> Bool {
    request.title != nil || request.notes != nil || request.location != nil
        || request.start != nil || request.end != nil || request.allDay != nil
        || request.list != nil || request.listId != nil
}

/// The single calendar a write targets. `"all"` is a read scope, not a calendar
/// you can dump an event into, so it is refused here rather than silently picking
/// the first one — same rule as the reminder path.
private func calendarForWrite(store: EKEventStore, request: BridgeRequest) throws -> EKCalendar {
    let calendars = try calendarsForEventQuery(store: store, request: request)
    guard calendars.count == 1 else {
        throw ReminderFailure(
            "\"all\" reads every calendar; it is not a calendar you can write to. Name one.")
    }
    return calendars[0]
}

private func findEvent(_ store: EKEventStore, id: String) throws -> EKEvent {
    guard !id.isEmpty else {
        throw ReminderFailure(
            "An event id is required. Read events with events_read and use the id from the result — "
            + "do not invent one.")
    }
    guard let item = store.calendarItem(withIdentifier: id) else {
        throw ReminderFailure(
            "No event with id \"\(id)\". If it came from an earlier read, a full iCloud re-sync "
            + "discards event identifiers, so re-read to get a fresh one.")
    }
    guard let event = item as? EKEvent else {
        throw ReminderFailure("Id \"\(id)\" is not a calendar event.")
    }
    return event
}

// Events save and remove through the span-based API, not the generic
// EKCalendarItem one the reminder path uses. `.thisEvent` vs `.futureEvents` only
// differ for a series, and recurring events are refused before we get here, so the
// span is not a decision we are making here.
private func saveEvent(_ store: EKEventStore, _ event: EKEvent) throws {
    do {
        try store.save(event, span: .thisEvent, commit: true)
    } catch {
        throw ReminderFailure("Calendar failed: \(error.localizedDescription)")
    }
}

private func removeEvent(_ store: EKEventStore, _ event: EKEvent) throws {
    do {
        try store.remove(event, span: .thisEvent, commit: true)
    } catch {
        throw ReminderFailure("Calendar failed: \(error.localizedDescription)")
    }
}
