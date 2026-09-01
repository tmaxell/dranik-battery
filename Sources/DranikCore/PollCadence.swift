import Foundation

/// How often the menu bar app asks, when nothing has told it to look.
///
/// The app is event-driven, and for a while it was *only* event-driven while its
/// popover was closed. That was wrong, and measurably so. On 2026-09-02 the gate
/// was opened and closed thirty seconds apart — charging started and stopped —
/// and `notify(3)` delivered nothing either time:
///
/// ```
/// 01:31:14 [Gate] CHTE -> 00000000 (open, charge 80% fell to the 81% resume point)
/// 01:31:44 [Gate] CHTE -> 01000000 (closed, charge 80% reached the 80% limit)
/// ```
///
/// `kIOPSNotifyPowerSource` fires when the power *source* changes, and
/// `com.apple.system.powersources.percent` when the percentage does. Charging
/// stopping at the limit is neither: the charger is still attached and the
/// charge has stopped moving, which is the whole point. So the status item went
/// on showing a charging bolt indefinitely.
///
/// The daemon has carried a safety net for exactly this reason since it was
/// written — notifications are not guaranteed, so something has to ask anyway.
/// This is the app's.
public struct PollCadence: Equatable, Sendable {
    /// While the popover is open, where staleness is being looked at directly.
    public static let whileOpen: TimeInterval = 5

    /// While it is closed. Half the daemon's own re-evaluation interval, so a
    /// decision is never more than about a minute from being on screen; asking
    /// faster than the daemon can decide would buy nothing.
    public static let whileClosed: TimeInterval = 30

    /// A ceiling on the fast cadence.
    ///
    /// `onDisappear` is not guaranteed to arrive for a menu bar window, and
    /// without a ceiling a missed one leaves the app polling every five seconds
    /// forever. Two minutes of an open popover is already unusual.
    public static let maximumFastTicks = 24

    public private(set) var isPopoverOpen = false
    private var fastTicks = 0

    public init() {}

    /// Never zero and never absent. The bug this type exists to prevent was the
    /// app stopping altogether, so there is no state here that means "stop".
    public var interval: TimeInterval {
        isPopoverOpen ? Self.whileOpen : Self.whileClosed
    }

    public mutating func popoverOpened() {
        isPopoverOpen = true
        fastTicks = 0
    }

    public mutating func popoverClosed() {
        isPopoverOpen = false
        fastTicks = 0
    }

    /// Counts one poll. Returns true when the cadence changed and the caller has
    /// to reschedule.
    public mutating func tick() -> Bool {
        guard isPopoverOpen else { return false }
        fastTicks += 1
        guard fastTicks > Self.maximumFastTicks else { return false }
        // Fall back to the idle cadence — never to nothing.
        isPopoverOpen = false
        fastTicks = 0
        return true
    }
}
