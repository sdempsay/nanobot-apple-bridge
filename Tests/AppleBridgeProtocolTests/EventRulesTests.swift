import XCTest
import AppleBridgeProtocol

/// The event read rules, tested without EventKit. What matters here is the
/// promise the result makes to a caller that we cannot control: that the window
/// it searched is named, that an omitted bound narrows rather than widens, and
/// that an empty page is not mistaken for an empty calendar.
final class EventRulesTests: XCTestCase {
    private let zone = TimeZone(secondsFromGMT: -7 * 3600)!
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func window(
        _ query: EventQuery, now: Date? = nil
    ) throws -> EventWindow {
        try resolveEventWindow(query, now: now ?? self.now, zone: zone)
    }

    private func record(
        _ title: String, start: String?, allDay: Bool = false
    ) -> EventRecord {
        EventRecord(
            id: "id-\(title)", title: title, notes: "", calendar: "Work",
            calendarId: "cal", start: start, end: nil, allDay: allDay,
            location: "", url: nil)
    }

    private func page(
        _ records: [EventRecord], _ query: EventQuery, scope: String = "all 3 calendars"
    ) throws -> EventPage {
        try eventPage(
            records: records, window: try window(query), scope: scope, limit: query.limit)
    }

    // MARK: - The default window

    func testOmittedBoundsDefaultToSevenDaysForward() throws {
        let resolved = try window(EventQuery())
        XCTAssertTrue(resolved.isDefaulted)
        XCTAssertNil(resolved.filters)
        XCTAssertEqual(
            resolved.end.timeIntervalSince(resolved.start) - 60,
            Double(defaultEventWindowDays) * 86400,
            accuracy: 1.0)
    }

    func testDefaultWindowIsReportedNotInvisible() throws {
        let result = try page([record("Standup", start: "2026-09-30T09:00")], EventQuery())
        let window = try XCTUnwrap(result.window)
        XCTAssertTrue(window.contains(".."))
        XCTAssertEqual(window.split(separator: "..").count, 2)
    }

    // MARK: - An absent bound must never mean "no bound"

    func testStartBeforeAloneDoesNotReachIntoThePast() throws {
        let resolved = try window(EventQuery(startBefore: "2026-10-10"))
        XCTAssertEqual(resolved.start, now)
        XCTAssertFalse(resolved.isDefaulted)
        XCTAssertEqual(resolved.filters?["start_before"], "2026-10-10")
    }

    func testStartAfterAloneKeepsTheBoundedLookahead() throws {
        let resolved = try window(EventQuery(startAfter: "2026-10-01"))
        XCTAssertFalse(resolved.isDefaulted)
        XCTAssertEqual(resolved.filters?["start_after"], "2026-10-01")
        XCTAssertLessThanOrEqual(
            resolved.end.timeIntervalSince(resolved.start), Double(maxEventWindowDays) * 86400)
    }

    // MARK: - Bounds

    func testInvertedWindowIsRefused() {
        XCTAssertThrowsError(try window(EventQuery(startAfter: "2026-10-10", startBefore: "2026-10-01"))) {
            XCTAssertEqual(($0 as? ReminderFailure)?.message, ReminderText.invertedEventWindow)
        }
    }

    func testOverWideWindowIsRefusedRatherThanTrimmed() {
        let query = EventQuery(startAfter: "2026-01-01", startBefore: "2026-12-31")
        XCTAssertThrowsError(try window(query)) {
            XCTAssertEqual(($0 as? ReminderFailure)?.message, ReminderText.eventWindowTooWide)
        }
    }

    func testWindowExactlyAtTheCapIsAccepted() throws {
        let start = "2026-10-01"
        let query = EventQuery(startAfter: start, startBefore: "2026-12-01")
        XCTAssertNoThrow(try window(query))
    }

    func testAllDayBoundCoversTheWholeDay() throws {
        let resolved = try window(EventQuery(startAfter: "2026-10-01", startBefore: "2026-10-01"))
        XCTAssertGreaterThan(resolved.end.timeIntervalSince(resolved.start), 23 * 3600)
    }

    /// The predicate end is exclusive, so the last searched *minute* gets one
    /// extra minute. Without this an event starting at the bound is dropped
    /// while the result claims the bound was inclusive.
    func testPredicateEndCoversTheLastSearchedMinute() throws {
        let resolved = try window(EventQuery(startAfter: "2026-10-01T09:00", startBefore: "2026-10-01T09:00"))
        XCTAssertEqual(resolved.end.timeIntervalSince(resolved.start), 60, accuracy: 1.0)
    }

    func testBothBoundsCollapseIntoOneFilterKey() throws {
        let query = EventQuery(startAfter: "2026-10-01", startBefore: "2026-10-05")
        let resolved = try window(query)
        XCTAssertEqual(resolved.filters?["start"], "2026-10-01..2026-10-05")
        XCTAssertNil(resolved.filters?["start_after"])
        XCTAssertNil(resolved.filters?["start_before"])
    }

    // MARK: - Page shape

    func testSortsByStartThenTitle() throws {
        let result = try page(
            [
                record("B", start: "2026-09-30T09:00"),
                record("A", start: "2026-09-30T09:00"),
                record("C", start: "2026-09-29T09:00"),
            ], EventQuery())
        XCTAssertEqual(result.events.map(\.title), ["C", "A", "B"])
    }

    func testUndatedEventsSortLast() throws {
        let result = try page(
            [record("Z", start: nil), record("A", start: "2026-09-30T09:00")], EventQuery())
        XCTAssertEqual(result.events.map(\.title), ["A", "Z"])
    }

    func testMatchedCountsBeforeTheCap() throws {
        let records = (1...5).map { record("E\($0)", start: "2026-09-30T09:0\($0 % 10)") }
        let result = try page(records, EventQuery(limit: 2))
        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.matched, 5)
        XCTAssertTrue(result.truncated)
    }

    func testNotTruncatedWhenThePageFits() throws {
        let result = try page([record("A", start: "2026-09-30T09:00")], EventQuery(limit: 5))
        XCTAssertFalse(result.truncated)
        XCTAssertNil(result.note)
    }

    func testLimitIsValidatedNotSilentlyClamped() {
        XCTAssertThrowsError(
            try page([record("A", start: "2026-09-30T09:00")], EventQuery(limit: 0))
        )
        XCTAssertThrowsError(
            try page([record("A", start: "2026-09-30T09:00")], EventQuery(limit: 101))
        )
    }

    // MARK: - The note

    /// The trap: a defaulted window plus an empty page reads as "your calendar is
    /// empty" unless the result says the emptiness is about the window.
    func testEmptyDefaultedPageSaysTheEmptinessIsAboutTheWindow() throws {
        let result = try page([], EventQuery())
        let note = try XCTUnwrap(result.note)
        XCTAssertTrue(note.contains("not about the calendar"), note)
        XCTAssertTrue(note.contains("start_after"), note)
    }

    func testEmptyExplicitPageDoesNotNagAboutWidening() throws {
        let result = try page([], EventQuery(startAfter: "2026-10-01", startBefore: "2026-10-02"))
        let note = try XCTUnwrap(result.note)
        XCTAssertTrue(note.contains("not about the calendar"), note)
        XCTAssertFalse(note.contains("pass start_after"), note)
    }

    func testEmptyDefaultCalendarPagePointsAtTheUnmisfillableTool() throws {
        let result = try page([], EventQuery(), scope: "default calendar \"Work\"")
        let note = try XCTUnwrap(result.note)
        XCTAssertTrue(note.contains("events_upcoming"), note)
    }

    func testEmptyAllCalendarsPageDoesNotBlameTheScope() throws {
        let result = try page([], EventQuery(), scope: "all 3 calendars")
        XCTAssertFalse(try XCTUnwrap(result.note).contains("events_upcoming"))
    }

    func testTruncationIsExplainedOnANonEmptyPage() throws {
        let records = (1...4).map { record("E\($0)", start: "2026-09-30T09:0\($0)") }
        let note = try XCTUnwrap(try page(records, EventQuery(limit: 2)).note)
        XCTAssertTrue(note.contains("capped"), note)
    }
}
