import XCTest
@testable import AppleBridgeProtocol

final class DeadlineTests: XCTestCase {

    func testClaimReturnsWhenTheGateIsSignalledInTime() throws {
        let deadline = Deadline(seconds: 5)
        let gate = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { gate.signal() }
        try deadline.claim(gate, hop: "test hop")   // must not throw
    }

    func testClaimThrowsNamingTheHopWhenTimeRunsOut() {
        let deadline = Deadline(seconds: 0.2)
        let gate = DispatchSemaphore(value: 0)      // never signalled
        XCTAssertThrowsError(try deadline.claim(gate, hop: "reminder fetch")) { error in
            let message = (error as? ReminderFailure)?.message ?? ""
            XCTAssertTrue(
                message.contains("reminder fetch"),
                "message should name the stuck hop, got: \(message)")
            XCTAssertTrue(
                message.contains("did not answer within"),
                "message should say what happened, got: \(message)")
        }
    }

    func testBudgetIsSharedAcrossHopsAndCannotCompound() {
        // One 0.4s budget, three hops. The first two succeed; the third must fail
        // because the budget is already spent — not get a fresh 0.4s of its own.
        let deadline = Deadline(seconds: 0.4)
        let first = DispatchSemaphore(value: 0)
        let second = DispatchSemaphore(value: 0)
        let third = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            first.signal()
            second.signal()
        }
        XCTAssertNoThrow(try deadline.claim(first, hop: "hop one"))
        XCTAssertNoThrow(try deadline.claim(second, hop: "hop two"))
        XCTAssertThrowsError(try deadline.claim(third, hop: "hop three"))
        XCTAssertEqual(deadline.secondsLeft, 0, accuracy: 0.05)
    }

    func testSecondsLeftNeverGoesNegative() {
        let deadline = Deadline(seconds: 0.01)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertGreaterThanOrEqual(deadline.secondsLeft, 0)
    }
}
