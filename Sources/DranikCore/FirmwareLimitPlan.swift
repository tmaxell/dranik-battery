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
    case holdingBelow(percentage: Int, lower: Int, upper: Int)
    case holdingAtLimit(percentage: Int, upper: Int)
    /// The corridor is held, but the charge is not readable. Its own case rather
    /// than `holdingBelow` with a zero: a fabricated percentage reads as fact.
    case holdingUnknownCharge(lower: Int, upper: Int)
    case aboveCorridor(percentage: Int, upper: Int)
    case limitingDisabled
    case corridorDrifted(wanted: FirmwareLimitPlan, found: FirmwareLimitState)
    case corridorUnreadable
    case writeFailed

    public var code: String {
        switch self {
        case .holdingBelow: return "firmwareHoldingBelow"
        case .holdingAtLimit: return "reachedUpper"
        case .holdingUnknownCharge: return "firmwareHoldingUnknownCharge"
        case .aboveCorridor: return "firmwareAboveCorridor"
        case .limitingDisabled: return "limitingDisabled"
        case .corridorDrifted: return "firmwareCorridorDrifted"
        case .corridorUnreadable: return "firmwareCorridorUnreadable"
        case .writeFailed: return "firmwareWriteFailed"
        }
    }

    public var description: String {
        switch self {
        case .holdingBelow(let percentage, let lower, let upper):
            return "firmware holds \(lower)–\(upper)% — charge \(percentage)% is charging towards it"
        case .holdingAtLimit(let percentage, let upper):
            return "charge \(percentage)% reached the \(upper)% limit — firmware is holding it there"
        case .holdingUnknownCharge(let lower, let upper):
            return "firmware holds \(lower)–\(upper)% — the charge level is not readable"
        case .aboveCorridor(let percentage, let upper):
            // Worth its own sentence because the machine behaves visibly
            // differently here: above the corridor it runs off the battery to
            // come down, which looks like a fault if nothing says otherwise.
            return "charge \(percentage)% is above the \(upper)% limit — "
                + "running on battery until it comes down"
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
        }
    }

    /// Whether this is a state someone needs to do something about.
    public var isFault: Bool {
        switch self {
        case .corridorUnreadable, .writeFailed: return true
        case .holdingBelow, .holdingAtLimit, .holdingUnknownCharge, .aboveCorridor,
             .limitingDisabled, .corridorDrifted:
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
/// to run, no gate to chase and nothing to verify against a clock: the corridor
/// is state the hardware keeps, so the only question is whether it still says
/// what the configuration asks for.
public enum FirmwareLimitPolicy {
    public static func decide(
        config: ChargeConfig,
        observed: FirmwareLimitState?,
        percentage: Int?
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

        switch plan {
        case .off:
            return FirmwareLimitDecision(plan: plan, requiresWrite: false, reason: .limitingDisabled)
        case .hold(let lower, let upper):
            guard let percentage else {
                return FirmwareLimitDecision(
                    plan: plan,
                    requiresWrite: false,
                    reason: .holdingUnknownCharge(lower: lower, upper: upper)
                )
            }
            if percentage > upper {
                return FirmwareLimitDecision(
                    plan: plan,
                    requiresWrite: false,
                    reason: .aboveCorridor(percentage: percentage, upper: upper)
                )
            }
            if percentage == upper {
                return FirmwareLimitDecision(
                    plan: plan,
                    requiresWrite: false,
                    reason: .holdingAtLimit(percentage: percentage, upper: upper)
                )
            }
            return FirmwareLimitDecision(
                plan: plan,
                requiresWrite: false,
                reason: .holdingBelow(percentage: percentage, lower: lower, upper: upper)
            )
        }
    }
}
