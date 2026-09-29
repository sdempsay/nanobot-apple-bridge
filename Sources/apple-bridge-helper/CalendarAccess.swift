import Foundation
import EventKit
import AppleBridgeProtocol

// PROTOTYPE — Calendar read only. No create/update/delete yet.
// Follows the Reminders shape: main-queue hops under one request Deadline.

func dispatchCalendar(_ request: BridgeRequest, store: EKEventStore) -> BridgeResponse {
    let deadline = Deadline()
    switch request.command {
    case .calendars:
        return respond { try calendarList(store: store, deadline: deadline) }
    case .events:
        return respond { try readEvents(request, store: store, deadline: deadline) }
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
    let calendars = try onMain(deadline, hop: "calendar lookup") {
        try calendarsForEventQuery(store: store, request: request)
    }
    let start = Date()
    // Default window: the next 7 days. A wide window on a big calendar is slow.
    let end = start.addingTimeInterval(60 * 60 * 24 * 7)
    // Unlike reminders, EventKit's event fetch is SYNCHRONOUS — it returns the
    // array directly rather than calling back. So there is no semaphore hop and
    // no second Deadline claim here, unlike fetchReminders.
    let events = try onMain(deadline, hop: "event read") {
        let predicate = store.predicateForEvents(
            withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate)
    }
    let records = events.map { makeEventRecord($0) }
    return eventPage(
        records: records, limit: request.limit ?? 50, calendars: calendars, request: request)
}

private func calendarsForEventQuery(
    store: EKEventStore, request: BridgeRequest
) throws -> [EKCalendar] {
    store.refreshSourcesIfNecessary()
    let all = store.calendars(for: .event)
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

private func makeEventRecord(_ event: EKEvent) -> EventRecord {
    EventRecord(
        id: event.eventIdentifier ?? "",
        title: event.title ?? "",
        notes: event.notes ?? "",
        calendar: event.calendar?.title ?? "",
        calendarId: event.calendar?.calendarIdentifier ?? "",
        start: event.startDate.map(formatTimestamp),
        end: event.endDate.map(formatTimestamp),
        allDay: event.isAllDay,
        location: event.location ?? "",
        url: event.url?.absoluteString)
}

/// Sort by start, all-day first, then title. No filter grammar yet — the
/// prototype is here to size the work, not to ship a query language.
private func eventPage(
    records: [EventRecord],
    limit: Int,
    calendars: [EKCalendar],
    request: BridgeRequest
) -> EventPage {
    let capped = min(max(limit, 1), 100)
    let sorted = records.sorted { a, b in
        if a.start != b.start { return (a.start ?? "") < (b.start ?? "") }
        return a.title < b.title
    }
    let query = request.list ?? request.listId
    let scope: String
    if let query, isAllLists(query) {
        scope = "all \(calendars.count) calendars"
    } else {
        scope = "calendar \"\(calendars.first?.title ?? "unknown")\""
    }
    return EventPage(
        events: Array(sorted.prefix(capped)),
        matched: sorted.count,
        truncated: sorted.count > capped,
        scope: scope)
}
