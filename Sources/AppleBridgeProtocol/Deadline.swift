import Foundation

/// One time budget per request, threaded to every hop that waits (the main queue
/// or remindd). A stuck hop then fails inside the budget instead of hanging until
/// the agent's own timeout kills the call — and the total can never compound past
/// the budget, no matter how many hops a single request uses.
///
/// The old shape had a 25s timeout on fetch only, while `onMain` waited forever;
/// three hops in one request could have stacked to 75s, or hung indefinitely.
///
/// Pure Foundation logic, so it lives in the shared module and is testable —
/// the helper's failure paths should not be the untested ones.
public struct Deadline {
    public let budgetSeconds: TimeInterval
    private let end: Date

    public init(seconds: TimeInterval = 25) {
        budgetSeconds = seconds
        end = Date().addingTimeInterval(seconds)
    }

    /// Seconds left, never negative.
    public var secondsLeft: TimeInterval {
        max(0, end.timeIntervalSinceNow)
    }

    /// Spend whatever is left of the budget waiting on `gate`. Throws a
    /// `ReminderFailure` naming the hop that ran out of time.
    public func claim(_ gate: DispatchSemaphore, hop: String) throws {
        let left = secondsLeft
        if left <= 0 {
            throw failure(hop)
        }
        if gate.wait(timeout: .now() + left) == .timedOut {
            throw failure(hop)
        }
    }

    private func failure(_ hop: String) -> ReminderFailure {
        ReminderFailure(
            "Reminders failed: \(hop) did not answer within \(Int(budgetSeconds)) seconds.")
    }
}
