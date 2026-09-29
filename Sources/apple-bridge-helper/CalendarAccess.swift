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

private func makeEventRecord(_ event: EKEvent) -> EventRecord {
    EventRecord(
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
        url: event.url?.absoluteString)
}
