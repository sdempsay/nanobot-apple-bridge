import Darwin
import XCTest
import AppleBridgeProtocol

/// The response framing shared by the MCP client and the helper. These are the
/// failure paths that used to be untested: a silent helper, a slow one, and a
/// closed one.
final class FrameReadTests: XCTestCase {
    func testReturnsOneFrameAndLeavesTheNextOne() throws {
        let pair = try socketPair()
        defer { close(pair.0); close(pair.1) }
        let first = Data("{\"ok\":true}\n".utf8)
        let second = Data("{\"ok\":false}\n".utf8)
        XCTAssertEqual(writeAll(fd: pair.0, data: first + second), 0)

        let deadline = Deadline(seconds: 2)
        let got = try readFrame(fd: pair.1, deadline: deadline, hop: "test")
        XCTAssertEqual(String(data: got, encoding: .utf8), "{\"ok\":true}")
        // The reader must not have swallowed the second frame's bytes.
        let again = try readFrame(fd: pair.1, deadline: deadline, hop: "test")
        XCTAssertEqual(String(data: again, encoding: .utf8), "{\"ok\":false}")
    }

    func testSilentPeerTimesOutInsideTheBudget() throws {
        let pair = try socketPair()
        defer { close(pair.0); close(pair.1) }
        let started = Date()
        XCTAssertThrowsError(try readFrame(fd: pair.1, deadline: Deadline(seconds: 0.4),
                                          hop: "test")) { error in
            guard case FrameReadError.timeout(let hop, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(hop, "test")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    /// The regression this exists for: `SO_RCVTIMEO` bounds one `read`, so a peer
    /// that dribbles bytes could keep an exchange open indefinitely. A partial
    /// frame followed by silence must still die inside one budget.
    func testPartialFrameThenSilenceTimesOutInsideTheBudget() throws {
        let pair = try socketPair()
        defer { close(pair.0); close(pair.1) }
        // Two bytes arrive, then nothing — no newline, so the frame never completes.
        XCTAssertEqual(writeAll(fd: pair.0, data: Data("ab".utf8)), 0)
        let started = Date()
        XCTAssertThrowsError(try readFrame(fd: pair.1, deadline: Deadline(seconds: 0.5),
                                          hop: "test")) { error in
            guard case FrameReadError.timeout = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 1.5, "stalling peer outran the budget (\(elapsed)s)")
    }

    func testClosedPeerIsReportedAsClosed() throws {
        let pair = try socketPair()
        defer { close(pair.1) }
        XCTAssertEqual(writeAll(fd: pair.0, data: Data("{\"a\":1}".utf8)), 0)
        close(pair.0)
        XCTAssertThrowsError(try readFrame(fd: pair.1, deadline: Deadline(seconds: 2),
                                          hop: "test")) { error in
            guard case FrameReadError.closed = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testSpentBudgetRefusesWithoutWaiting() throws {
        let pair = try socketPair()
        defer { close(pair.0); close(pair.1) }
        let deadline = Deadline(seconds: 0.05)
        Thread.sleep(forTimeInterval: 0.1)
        let started = Date()
        XCTAssertThrowsError(try readFrame(fd: pair.1, deadline: deadline, hop: "test"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
    }

    private func socketPair() throws -> (Int32, Int32) {
        var fds: (Int32, Int32) = (0, 0)
        let created = withUnsafeMutablePointer(to: &fds) { pair in
            pair.withMemoryRebound(to: Int32.self, capacity: 2) { raw in
                socketpair(AF_UNIX, SOCK_STREAM, 0, raw)
            }
        }
        try XCTSkipIf(created != 0, "socketpair failed")
        return fds
    }
}
