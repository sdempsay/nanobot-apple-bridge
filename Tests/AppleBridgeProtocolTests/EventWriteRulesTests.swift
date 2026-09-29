import XCTest
import AppleBridgeProtocol

/// Event write rules. The recurring refusal is the load-bearing one: it is the
/// answer to "what should a write to one occurrence of a series do", and it has
/// to be a refusal because the alternatives silently rewrite the future.
final class EventWriteRulesTests: XCTestCase {
    private let zone = TimeZone(secondsFromGMT: -7 * 3600)!

    private func times(
        start: String? = "2026-10-01T10:00",
        end: String? = nil,
        allDay: Bool? = nil,
        required: Bool = false
    ) throws -> (start: Date, end: Date, allDay: Bool)? {
        try eventTimes(
            start: start, end: end, allDay: allDay, required: required, zone: zone,
            now: Date(timeIntervalSince1970: 1_789_000_000))
    }

    // MARK: - Times

    func testDateOnlyStartIsAllDay() throws {
        let result = try XCTUnwrap(try times(start: "2026-10-01"))
        XCTAssertTrue(result.allDay)
    }

    /// EventKit's convention: an all-day event ends at midnight at the *start* of
    /// the next day, exclusive. The read path then renders that 00:00, which is
    /// the oddity TODO-13 still tracks on the read side.
    func testAllDayEndsAtMidnightTheNextDay() throws {
        let result = try XCTUnwrap(try times(start: "2026-10-01"))
        XCTAssertEqual(result.end.timeIntervalSince(result.start), 86400, accuracy: 1.0)
    }

    /// 2026-10-31 + 1 is not the 32nd of anything. Month end is where naive
    /// day+1 arithmetic breaks.
    func testAllDayAcrossMonthEnd() throws {
        let result = try XCTUnwrap(try times(start: "2026-10-31"))
        XCTAssertEqual(result.end.timeIntervalSince(result.start), 86400, accuracy: 1.0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let end = calendar.dateComponents([.year, .month, .day], from: result.end)
        XCTAssertEqual(end.month, 11)
        XCTAssertEqual(end.day, 1)
    }

    func testAllDayIgnoresTheEndArgument() throws {
        // "2026-10-01" to "2026-10-01" means one day, not zero.
        let result = try XCTUnwrap(try times(start: "2026-10-01", end: "2026-10-01"))
        XCTAssertEqual(result.end.timeIntervalSince(result.start), 86400, accuracy: 1.0)
    }

    func testTimedEventDefaultsToOneHour() throws {
        let result = try XCTUnwrap(try times())
        XCTAssertFalse(result.allDay)
        XCTAssertEqual(result.end.timeIntervalSince(result.start), 3600, accuracy: 1.0)
    }

    func testExplicitEndIsHonoured() throws {
        let result = try XCTUnwrap(try times(start: "2026-10-01T10:00", end: "2026-10-01T11:30"))
        XCTAssertEqual(result.end.timeIntervalSince(result.start), 5400, accuracy: 1.0)
    }

    func testEndBeforeStartIsRefused() {
        XCTAssertThrowsError(try times(start: "2026-10-01T10:00", end: "2026-10-01T09:00"))
    }

    func testAllDayFlagOverridesTheStartFormat() throws {
        let forced = try XCTUnwrap(try times(start: "2026-10-01T10:00", allDay: true))
        XCTAssertTrue(forced.allDay)
    }

    func testStartIsRequiredOnCreateButNotUpdate() throws {
        XCTAssertThrowsError(try times(start: nil, required: true))
        XCTAssertNil(try times(start: nil, required: false))
    }

    // MARK: - The recurring refusal

    func testNonRecurringEventIsNotRefused() {
        XCTAssertNoThrow(try rejectRecurring(false, title: "Standup", id: "abc"))
    }

    func testRecurringEventIsRefusedWithTheReasonAndTheId() {
        XCTAssertThrowsError(try rejectRecurring(true, title: "Standup", id: "abc-123")) { error in
            let message = (error as? ReminderFailure)?.message ?? ""
            XCTAssertTrue(message.contains("Standup"), message)
            XCTAssertTrue(message.contains("abc-123"), message)
            XCTAssertTrue(message.contains("read-only"), message)
            XCTAssertTrue(message.contains("occurrence"), message)
        }
    }

    /// The refusal must explain the hazard, not just deny. A model that retries
    /// after "not allowed" will try a different field; a model that reads "will
    /// not guess between this occurrence and the whole series" will stop.
    func testRefusalExplainsWhyRatherThanJustDenying() {
        XCTAssertThrowsError(try rejectRecurring(true, title: "T", id: "i")) { error in
            let message = (error as? ReminderFailure)?.message ?? ""
            XCTAssertTrue(message.contains("guess"), message)
            XCTAssertTrue(message.contains("every future event"), message)
        }
    }

    // MARK: - Update validation

    func testEmptyUpdateIsRefused() {
        XCTAssertThrowsError(try validateEventUpdate(changing: false))
    }

    func testAnyFieldCountsAsAChange() {
        XCTAssertNoThrow(try validateEventUpdate(changing: true))
    }
}
