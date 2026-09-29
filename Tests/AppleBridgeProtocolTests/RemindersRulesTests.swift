import XCTest
import AppleBridgeProtocol

final class RemindersRulesTests: XCTestCase {
    private let zone = TimeZone(secondsFromGMT: -7 * 3600)!

    func testParseDueDateIsAllDay() throws {
        let due = try parseDue("2026-09-29", zone: zone)
        XCTAssertTrue(due.allDay)
        XCTAssertEqual(due.format(), "2026-09-29")
        XCTAssertEqual(due.span().end.hour, 23)
        XCTAssertEqual(due.span().end.minute, 59)
    }

    func testParseDueLocalDropsSeconds() throws {
        let due = try parseDue("2026-09-29T10:15:45", zone: zone)
        XCTAssertFalse(due.allDay)
        XCTAssertEqual(due.format(), "2026-09-29T10:15")
    }

    func testParseDueZonedConvertsIntoTheGivenZone() throws {
        let zulu = try parseDue("2026-09-29T17:00:00Z", zone: zone)
        XCTAssertEqual(zulu.format(), "2026-09-29T10:00")
        let offset = try parseDue("2026-09-29T01:30+0530", zone: zone)
        XCTAssertEqual(offset.format(), "2026-09-28T13:00")
    }

    func testParseDueRejectsImpossibleAndFractionalValues() {
        XCTAssertThrowsError(try parseDue("2026-02-31", zone: zone)) { error in
            XCTAssertEqual(
                error as? ReminderFailure,
                ReminderFailure("Due value \"2026-02-31\" is not a calendar date or a local time."))
        }
        XCTAssertThrowsError(try parseDue("2026-09-29T10:15:00.000Z", zone: zone))
        XCTAssertThrowsError(try parseDue("2026-09-29T24:00", zone: zone))
    }

    func testResolveListPrefersAnIdentifier() throws {
        let lists = [
            ListRef(id: "Work", name: "Family"),
            ListRef(id: "abc", name: "Work"),
        ]
        XCTAssertEqual(try resolveList(lists, query: "Work").id, "Work")
    }

    func testResolveListReportsUnknownAndAmbiguousNames() {
        let lists = [
            ListRef(id: "a", name: "Reminders"),
            ListRef(id: "b", name: "Reminders"),
            ListRef(id: "c", name: "Work"),
        ]
        XCTAssertThrowsError(try resolveList(lists, query: "Nope")) { error in
            XCTAssertEqual(
                error as? ReminderFailure,
                ReminderFailure("No list named \"Nope\". Available lists: Reminders, Reminders, Work."))
        }
        XCTAssertThrowsError(try resolveList(lists, query: "Reminders")) { error in
            XCTAssertEqual(
                error as? ReminderFailure,
                ReminderFailure(
                    "More than one list is named \"Reminders\": Reminders (a), Reminders (b)."))
        }
    }

    func testPriorityMap() throws {
        XCTAssertEqual(try priorityInt("none"), 0)
        XCTAssertEqual(try priorityInt("high"), 1)
        XCTAssertEqual(try priorityInt("medium"), 5)
        XCTAssertEqual(try priorityInt("low"), 9)
        XCTAssertEqual(try priorityName(0, reminderId: "id"), "none")
        XCTAssertEqual(try priorityName(1, reminderId: "id"), "high")
        XCTAssertEqual(try priorityName(4, reminderId: "id"), "high")
        XCTAssertEqual(try priorityName(5, reminderId: "id"), "medium")
        XCTAssertEqual(try priorityName(6, reminderId: "id"), "low")
        XCTAssertEqual(try priorityName(9, reminderId: "id"), "low")
        XCTAssertThrowsError(try priorityInt("urgent"))
        XCTAssertThrowsError(try priorityName(10, reminderId: "abc")) { error in
            XCTAssertEqual(
                error as? ReminderFailure,
                ReminderFailure("Reminder \"abc\" has priority 10, which is outside 0\u{2013}9."))
        }
    }

    func testRejectFlagAllowsOnlyACreateTimeFalse() throws {
        try rejectFlag(flagged: nil, updating: false)
        try rejectFlag(flagged: nil, updating: true)
        try rejectFlag(flagged: false, updating: false)
        XCTAssertThrowsError(try rejectFlag(flagged: true, updating: false)) { error in
            XCTAssertEqual(error as? ReminderFailure, ReminderFailure(ReminderText.flagUnavailable))
        }
        XCTAssertThrowsError(try rejectFlag(flagged: false, updating: true)) { error in
            XCTAssertEqual(error as? ReminderFailure, ReminderFailure(ReminderText.flagUnavailable))
        }
    }

    func testValidateUpdate() throws {
        try validateUpdate(changing: false, due: nil, clearDue: true)
        try validateUpdate(changing: true, due: "2026-09-29", clearDue: false)
        XCTAssertThrowsError(try validateUpdate(changing: false, due: nil, clearDue: false)) { error in
            XCTAssertEqual(error as? ReminderFailure, ReminderFailure(ReminderText.emptyUpdate))
        }
        XCTAssertThrowsError(try validateUpdate(changing: true, due: "2026-09-29", clearDue: true)) { error in
            XCTAssertEqual(error as? ReminderFailure, ReminderFailure(ReminderText.dueAndClear))
        }
    }

    func testReminderPageSortsTruncatesAndFilters() throws {
        let records = [
            sample("b", title: "Bravo"),
            sample("a", title: "Alpha", due: "2026-01-03", allDay: true),
            sample("c", title: "Zulu", due: "2026-01-01T09:00"),
            sample("e", title: "Alpha", due: "2026-01-01T08:00"),
            sample("d", title: "Alpha", due: "2026-01-01T08:00"),
            sample("done", title: "Done", due: "2026-01-01T07:00", completed: true),
        ]
        let page = try reminderPage(records: records, query: ReminderQuery(limit: 2), zone: zone)
        XCTAssertEqual(page.reminders.map(\.id), ["d", "e"])
        XCTAssertEqual(page.matched, 5)
        XCTAssertTrue(page.truncated)

        let window = try reminderPage(
            records: records,
            query: ReminderQuery(status: "any", dueAfter: "2026-01-02", dueBefore: "2026-01-03"),
            zone: zone)
        XCTAssertEqual(window.reminders.map(\.id), ["a"])

        let flagged = try reminderPage(
            records: records,
            query: ReminderQuery(flagged: true),
            zone: zone)
        XCTAssertEqual(flagged.matched, 0)

        let openFlag = try reminderPage(
            records: records,
            query: ReminderQuery(search: "alpha", flagged: false),
            zone: zone)
        XCTAssertEqual(openFlag.reminders.map(\.id), ["d", "e", "a"])
    }

    func testReminderPageRejectsABadQuery() {
        XCTAssertThrowsError(try reminderPage(records: [], query: ReminderQuery(status: "later"))) { error in
            XCTAssertEqual(error as? ReminderFailure, ReminderFailure(ReminderText.badStatus))
        }
        XCTAssertThrowsError(try reminderPage(records: [], query: ReminderQuery(search: "  "))) { error in
            XCTAssertEqual(error as? ReminderFailure, ReminderFailure(ReminderText.blankSearch))
        }
        XCTAssertThrowsError(
            try reminderPage(records: [], query: ReminderQuery(dueAfter: "2026-02-02", dueBefore: "2026-02-01"))
        ) { error in
            XCTAssertEqual(error as? ReminderFailure, ReminderFailure(ReminderText.invertedWindow))
        }
        XCTAssertThrowsError(try reminderPage(records: [], query: ReminderQuery(limit: 0))) { error in
            XCTAssertEqual(error as? ReminderFailure, ReminderFailure(ReminderText.badLimit))
        }
    }

    func testRecordEncodesThePublicKeys() throws {
        let data = try JSONEncoder().encode(sample("id", title: "Milk"))
        let object = try JSONDecoder().decode([String: JSONValue].self, from: data)
        XCTAssertEqual(object["list_id"], .string("list-1"))
        XCTAssertEqual(object["all_day"], .bool(false))
        XCTAssertEqual(object["flagged"], .bool(false))
        XCTAssertNil(object["due"])
        XCTAssertNil(object["completion_time"])
        XCTAssertNil(object["listId"])
    }

    func testRequestDecodesMissingFieldsAsNil() throws {
        let decoded = try JSONDecoder().decode(BridgeRequest.self, from: Data("{\"command\":\"lists\"}".utf8))
        XCTAssertEqual(decoded.command, .lists)
        XCTAssertNil(decoded.list)
        XCTAssertNil(decoded.dueAfter)
        XCTAssertNil(decoded.clearDue)
        XCTAssertNil(decoded.flagged)
        XCTAssertNil(decoded.limit)
    }

    private func sample(
        _ id: String,
        title: String,
        due: String? = nil,
        allDay: Bool = false,
        completed: Bool = false
    ) -> ReminderRecord {
        ReminderRecord(
            id: id,
            title: title,
            notes: "",
            list: "Reminders",
            listId: "list-1",
            due: due,
            allDay: allDay,
            priority: "none",
            flagged: false,
            completed: completed,
            completionTime: nil)
    }
}
