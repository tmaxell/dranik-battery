import Foundation

/// What to do with the charge gate as the machine goes to sleep.
public enum SleepTransition: Equatable, Sendable {
    case closeGate(String)
    case openGate(String)
    case leaveAlone(String)

    public var position: GatePosition? {
        switch self {
        case .closeGate: return .closed
        case .openGate: return .open
        case .leaveAlone: return nil
        }
    }

    public var explanation: String {
        switch self {
        case .closeGate(let why), .openGate(let why), .leaveAlone(let why): return why
        }
    }
}

/// The sleep rules, separated from the plumbing that carries them out.
///
/// Sleep is the part of this that is hardest to observe and easiest to get
/// wrong: it happens once a night, the machine is not running while it matters,
/// and the evidence is a battery percentage the next morning. So the decisions
/// live here, where every combination can be checked in a millisecond.
///
/// The whole shape of the problem comes from one measured fact: **the gate state
/// survives sleep** on this hardware. The daemon is not running, but whatever it
/// left behind is still in force. That is what makes a limit hold overnight, and
/// equally what makes a machine sit on a charger all night without charging.
public enum SleepPolicyDecision {
    public static func onWillSleep(config: ChargeConfig, percentage: Int) -> SleepTransition {
        guard !config.isLimitingDisabled else {
            return .leaveAlone("limiting is off")
        }

        switch config.sleepPolicy {
        case .holdLimit:
            // Unconditional, whatever the level. Closing at 30 % costs nothing
            // that waking does not undo, and the alternative — deciding per
            // level — is what `chargeIfLow` is for.
            return .closeGate("holding the limit through sleep")

        case .allowCharge:
            return .openGate("policy allows charging past the limit while asleep")

        case .chargeIfLow:
            // The one case where charging overnight is what anyone actually
            // wants: the battery is below the point where charging would resume
            // anyway, so it is going to charge as soon as the machine wakes.
            // Doing it while asleep only makes it ready sooner — at the cost of
            // possibly going past the limit, which is the trade this policy is.
            if percentage <= config.lowerLimit {
                return .openGate("at \(percentage)%, below the \(config.lowerLimit)% resume point")
            }
            return .closeGate("at \(percentage)%, above the \(config.lowerLimit)% resume point")
        }
    }

    /// Whether to refuse idle sleep because charging towards the limit is still
    /// in progress.
    ///
    /// Off unless asked for. A laptop that will not sleep, for a reason its owner
    /// cannot see, is a worse problem than a few percent of charge — and it only
    /// holds off *idle* sleep, so closing the lid still works.
    public static func shouldPreventIdleSleep(
        config: ChargeConfig,
        isExternalConnected: Bool,
        percentage: Int
    ) -> Bool {
        guard config.preventIdleSleepWhileCharging else { return false }
        guard !config.isLimitingDisabled else { return false }
        guard isExternalConnected else { return false }
        return percentage < config.upperLimit
    }
}
