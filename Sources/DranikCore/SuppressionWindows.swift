import Foundation

/// Two short windows in which one direction of gate movement is held back.
///
/// They point in opposite directions, and that is the whole idea.
///
/// After waking, the machine reports transient nonsense for a while — charging
/// false, odd inhibit reasons — so nothing may be **closed** on the strength of
/// it. After closing the gate for sleep, macOS still waits half a minute before
/// actually sleeping, and an ordinary evaluation in that gap would **open** the
/// gate again and undo the whole point.
///
/// Each window blocks exactly one direction. Neither can leave the gate shut for
/// longer than the window lasts, and the direction that fails safe — opening —
/// is never blocked by the one that follows waking.
public struct SuppressionWindows: Equatable, Sendable {
    /// Set after waking. Blocks closing only.
    public var closingSuppressedUntil: Date?
    /// Set after closing the gate for sleep. Blocks opening only.
    public var openingSuppressedUntil: Date?

    public init(closingSuppressedUntil: Date? = nil, openingSuppressedUntil: Date? = nil) {
        self.closingSuppressedUntil = closingSuppressedUntil
        self.openingSuppressedUntil = openingSuppressedUntil
    }

    public func allows(_ position: GatePosition, at now: Date) -> Bool {
        switch position {
        case .closed:
            guard let until = closingSuppressedUntil else { return true }
            return now >= until
        case .open:
            guard let until = openingSuppressedUntil else { return true }
            return now >= until
        }
    }

    public mutating func suppressClosing(until: Date) {
        closingSuppressedUntil = until
    }

    public mutating func suppressOpening(until: Date) {
        openingSuppressedUntil = until
    }

    public mutating func clearOpeningSuppression() {
        openingSuppressedUntil = nil
    }

    public mutating func clearClosingSuppression() {
        closingSuppressedUntil = nil
    }
}
