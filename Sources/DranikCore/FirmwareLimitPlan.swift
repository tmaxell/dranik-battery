import Foundation

/// What the firmware's charge corridor currently is, as three plain numbers.
///
/// Deliberately not the SMC type: this module decides and does not read, so the
/// caller converts. See `FirmwareLimitPolicy`.
public struct FirmwareLimitState: Equatable, Sendable {
    public let isActive: Bool
    public let upper: Int
    public let lower: Int

    public init(isActive: Bool, upper: Int, lower: Int) {
        self.isActive = isActive
        self.upper = upper
        self.lower = lower
    }
}

/// What the charger is doing, read off the hardware's own flags.
///
/// This exists instead of comparing the charge against the limit, and the reason
/// is a measurement. The firmware enforces its corridor against the battery
/// gauge's own state of charge; macOS displays a different, smoothed figure —
/// 79 against 83 on this machine on 2026-10-15, with the gap moving as charge
/// history changes (see `BatterySnapshot.percentage`). So "is the charge above
/// the limit" has two answers, ours is the wrong one, and the question does not
/// need asking: the corridor is held by the firmware, and the charger says
/// plainly what it is doing about it. Principle V — trust the hardware.
public enum FirmwareChargeActivity: Equatable, Sendable {
    /// Current is going into the battery.
    case charging
    /// Charging is inhibited and nothing is moving: sitting at the limit.
    case heldOff
    /// Inhibited and the battery is supplying the machine while on mains, which
    /// is how this firmware comes down to a corridor it is above.
    case comingDown
    /// No mains. Nothing about a charge limit applies.
    case onBattery
    /// On mains, not inhibited, not charging — or discharging for reasons that
    /// are not the corridor, such as a load the adapter cannot cover. Named
    /// rather than guessed at: the states above are the ones worth a sentence.
    case indeterminate

    /// Below this, current is noise rather than movement. The battery reports a
    /// few tens of milliamps of housekeeping while sitting still.
    public static let movementThreshold = 50

    public static func from(
        isExternalConnected: Bool,
        isCharging: Bool,
        milliamps: Int,
        isInhibited: Bool
    ) -> FirmwareChargeActivity {
        guard isExternalConnected else { return .onBattery }
        if isCharging || milliamps > movementThreshold { return .charging }
        guard isInhibited else { return .indeterminate }
        if milliamps < -movementThreshold { return .comingDown }
        return .heldOff
    }
}

/// What the corridor should be.
public enum FirmwareLimitPlan: Equatable, Sendable {
    /// Hand the firmware this corridor and let it enforce it.
    case hold(lower: Int, upper: Int)
    /// Take the corridor back, so charging is unrestricted. What `upperLimit`
    /// of 100 means, and what uninstalling must leave behind.
    case off

    public static func forConfig(_ config: ChargeConfig) -> FirmwareLimitPlan {
        guard config.upperLimit < 100 else { return .off }
        // The firmware's own rule is 0 <= lower < upper <= 100, and principle II
        // puts the floor at 20. `ChargeConfig` already clamps both, so this is a
        // second barrier rather than the only one — the same shape as the
        // metadata check in front of every SMC write.
        let upper = min(100, max(ChargeConfig.emergencyFloor + 1, config.upperLimit))
        let lower = min(upper - 1, max(ChargeConfig.emergencyFloor, config.lowerLimit))
        return .hold(lower: lower, upper: upper)
    }

    public var isLimiting: Bool { self != .off }

    public var upper: Int? {
        switch self {
        case .hold(_, let upper): return upper
        case .off: return nil
        }
    }

    /// Whether the firmware already holds exactly this.
    ///
    /// Exact rather than approximate on purpose. The firmware was measured not to
    /// adjust what it is given, so a difference means something else wrote these
    /// keys — and the useful response to that is to put them back, not to decide
    /// the difference was close enough.
    public func isSatisfied(by state: FirmwareLimitState) -> Bool {
        switch self {
        case .off:
            return !state.isActive
        case .hold(let lower, let upper):
            return state.isActive && state.upper == upper && state.lower == lower
        }
    }
}

/// Why the firmware path reported what it reported.
public enum FirmwareLimitReason: Equatable, Sendable, CustomStringConvertible {
    case chargingToLimit(upper: Int)
    case heldAtLimit(upper: Int)
    case comingDownToLimit(upper: Int)
    case onBattery
    case pluggedInNotCharging
    case limitingDisabled
    case corridorDrifted(wanted: FirmwareLimitPlan, found: FirmwareLimitState)
    case corridorUnreadable
    case writeFailed
    /// The corridor reads back exactly as asked, and the machine is charging
    /// above it anyway.
    ///
    /// The one thing reading the keys cannot tell you. `SMCConnection.write`
    /// says so itself: a matching read-back proves the key holds the value and
    /// nothing more. The gate path answers this with the charger's own flag
    /// after every write; this is the firmware path's version of that question.
    case notEnforcing(upper: Int, gauge: Int)

    public var code: String {
        switch self {
        case .chargingToLimit: return "firmwareChargingToLimit"
        // Shared with the gate path on purpose: a client drawing an icon for
        // "sitting at the limit" should not need to know which mechanism got it
        // there.
        case .heldAtLimit: return "reachedUpper"
        case .comingDownToLimit: return "firmwareComingDown"
        case .onBattery: return "onBattery"
        case .pluggedInNotCharging: return "firmwareIndeterminate"
        case .limitingDisabled: return "limitingDisabled"
        case .corridorDrifted: return "firmwareCorridorDrifted"
        case .corridorUnreadable: return "firmwareCorridorUnreadable"
        case .writeFailed: return "firmwareWriteFailed"
        case .notEnforcing: return "firmwareNotEnforcing"
        }
    }

    public var description: String {
        switch self {
        case .chargingToLimit(let upper):
            return "charging towards the \(upper)% limit, which the firmware is holding"
        case .heldAtLimit(let upper):
            // No percentage in this sentence, deliberately. The figure macOS
            // shows sits a few points above the one the firmware counts against,
            // so naming both invites the question and naming one is a half-truth.
            return "the firmware is holding charging off at the \(upper)% limit"
        case .comingDownToLimit(let upper):
            // Worth its own sentence because the machine behaves visibly
            // differently here: above the corridor it runs off the battery to
            // come down, which looks like a fault if nothing says otherwise.
            return "above the \(upper)% limit — running on battery until it comes down"
        case .onBattery:
            return "on battery — the limit applies once it is plugged in again"
        case .pluggedInNotCharging:
            return "plugged in and not charging, for reasons that are not the limit"
        case .limitingDisabled:
            return "limit is 100% — charging unrestricted"
        case .corridorDrifted(let wanted, let found):
            let asked: String
            switch wanted {
            case .off: asked = "off"
            case .hold(let lower, let upper): asked = "\(lower)–\(upper)%"
            }
            let has = found.isActive ? "\(found.lower)–\(found.upper)%" : "off"
            return "firmware corridor is \(has), not the \(asked) asked for — putting it back"
        case .corridorUnreadable:
            return "firmware corridor could not be read"
        case .writeFailed:
            return "the firmware refused the corridor — charging is not being limited"
        case .notEnforcing(let upper, let gauge):
            // Names the gauge figure rather than the displayed one, because this
            // is a statement about the scale the firmware itself counts on.
            return "the \(upper)% corridor is set and the battery is charging anyway "
                + "at \(gauge)% — the firmware is not enforcing it"
        }
    }

    /// Whether this is a state someone needs to do something about.
    public var isFault: Bool {
        switch self {
        case .corridorUnreadable, .writeFailed, .notEnforcing: return true
        case .chargingToLimit, .heldAtLimit, .comingDownToLimit, .onBattery,
             .pluggedInNotCharging, .limitingDisabled, .corridorDrifted:
            return false
        }
    }
}

public struct FirmwareLimitDecision: Equatable, Sendable {
    public let plan: FirmwareLimitPlan
    /// False when the firmware already holds the corridor. The caller uses this
    /// to keep from writing to the SMC for no reason — the corridor is held by
    /// the firmware between decisions, so the steady state is no writes at all.
    public let requiresWrite: Bool
    public let reason: FirmwareLimitReason

    public init(plan: FirmwareLimitPlan, requiresWrite: Bool, reason: FirmwareLimitReason) {
        self.plan = plan
        self.requiresWrite = requiresWrite
        self.reason = reason
    }
}

/// The whole of the firmware path's decision-making, as a pure function.
///
/// It is this short because the firmware does the work. There is no hysteresis
/// to run, no gate to chase, no clock and no charge level to compare against:
/// the corridor is state the hardware keeps, so there are exactly two questions
/// — does it still say what the configuration asks for, and what is the charger
/// doing about it.
public enum FirmwareLimitPolicy {
    /// - Parameter gaugeCharge: the battery gauge's own state of charge, which is
    ///   the scale the firmware enforces against — not the figure macOS shows.
    ///   `nil` where it could not be read, which only costs the confirmation
    ///   below; everything else is decided without it.
    public static func decide(
        config: ChargeConfig,
        observed: FirmwareLimitState?,
        activity: FirmwareChargeActivity,
        gaugeCharge: Int? = nil
    ) -> FirmwareLimitDecision {
        let plan = FirmwareLimitPlan.forConfig(config)

        guard let observed else {
            // Unreadable keys are not an excuse to write blindly: a write goes
            // through the guarded path anyway, which reads the descriptor first
            // and would refuse. Say so and let the next pass try again.
            return FirmwareLimitDecision(
                plan: plan, requiresWrite: false, reason: .corridorUnreadable
            )
        }

        if !plan.isSatisfied(by: observed) {
            return FirmwareLimitDecision(
                plan: plan,
                requiresWrite: true,
                reason: .corridorDrifted(wanted: plan, found: observed)
            )
        }

        guard let upper = plan.upper else {
            return FirmwareLimitDecision(plan: plan, requiresWrite: false, reason: .limitingDisabled)
        }

        // Charging while already past the corridor is the one unambiguous proof
        // that the corridor is not being honoured — the keys say one thing and
        // the current says another. Checked before anything calmer is reported,
        // and only against the gauge's own figure: the displayed percentage sits
        // above it often enough that using it here would cry wolf.
        if let gaugeCharge, gaugeCharge > upper, activity == .charging {
            return FirmwareLimitDecision(
                plan: plan,
                requiresWrite: false,
                reason: .notEnforcing(upper: upper, gauge: gaugeCharge)
            )
        }

        let reason: FirmwareLimitReason
        switch activity {
        case .charging: reason = .chargingToLimit(upper: upper)
        case .heldOff: reason = .heldAtLimit(upper: upper)
        case .comingDown: reason = .comingDownToLimit(upper: upper)
        case .onBattery: reason = .onBattery
        case .indeterminate: reason = .pluggedInNotCharging
        }
        return FirmwareLimitDecision(plan: plan, requiresWrite: false, reason: reason)
    }
}
