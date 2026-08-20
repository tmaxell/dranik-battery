import Foundation

/// A run of failed gate verifications, and whether it is long enough to mean the
/// mechanism is broken.
///
/// Counting alone is not enough, and that is not a hypothesis. On 2026-08-19 two
/// contradicted checks eighteen minutes apart — one caused by a wake, one never
/// explained — switched charge limiting off, and it stayed off for two days
/// until someone noticed the battery at 100 %.
///
/// The reason a plain counter fails here is that verifications are rare. One
/// happens only when the gate moves, which on the measured machine is about five
/// times in two days. "Twice in a row" was meant to say "this mechanism is
/// broken"; with checks that sparse it says "twice, ever", and any two unrelated
/// hiccups a week apart add up to a permanent shutdown.
///
/// So a run has a memory. A failure far enough from the previous one starts a
/// new run rather than extending the old.
public struct VerificationFailures: Equatable, Sendable {
    /// How close together two failures must be to count as the same fault.
    ///
    /// Measured in **awake** seconds, like everything else that judges the gate:
    /// a machine that spent the interval asleep has not been given a chance to
    /// fail again, and should not have the gap held against it.
    public static let sameFaultWindow: TimeInterval = 30 * 60

    /// How long a run has to be to act on. Two conclusive contradictions close
    /// together is still the right bar — it is the "close together" that was
    /// missing.
    public static let threshold = 2

    public private(set) var count = 0
    private var lastFailureAt: TimeInterval?

    public init() {}

    /// A check confirmed the gate. Whatever was wrong is over.
    public mutating func confirmed() {
        count = 0
        lastFailureAt = nil
    }

    /// A check contradicted the gate. Returns true when the run is now long
    /// enough to stop trusting the gate.
    public mutating func contradicted(at awakeNow: TimeInterval) -> Bool {
        if let last = lastFailureAt, awakeNow - last > Self.sameFaultWindow {
            count = 1
        } else {
            count += 1
        }
        lastFailureAt = awakeNow
        return count >= Self.threshold
    }
}
