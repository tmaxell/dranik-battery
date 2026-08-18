import Foundation

/// Which way the charge gate is set.
public enum GatePosition: String, Equatable, Sendable {
    /// Charging permitted — the SMC key holds its on-payload.
    case open
    /// Charging inhibited — the SMC key holds its off-payload.
    case closed
}

/// Everything the controller is allowed to look at.
///
/// Deliberately not the raw `BatterySnapshot`: the controller decides, it does
/// not gather, and keeping the input this narrow is what lets every branch be
/// tested without a battery.
public struct ControllerInput: Equatable, Sendable {
    /// The percentage macOS reports. Not one derived from raw capacity — the two
    /// disagree by several points, and this is the one the user set the limit
    /// against.
    public let percentage: Int
    public let isExternalConnected: Bool
    /// Battery temperature in °C.
    public let temperature: Double
    /// When the reading was taken.
    public let observedAt: Date
    /// Now, as the caller sees it. Separate from `observedAt` so staleness is
    /// something the controller can judge rather than assume.
    public let now: Date

    public init(
        percentage: Int,
        isExternalConnected: Bool,
        temperature: Double,
        observedAt: Date = Date(),
        now: Date = Date()
    ) {
        self.percentage = percentage
        self.isExternalConnected = isExternalConnected
        self.temperature = temperature
        self.observedAt = observedAt
        self.now = now
    }

    var age: TimeInterval { now.timeIntervalSince(observedAt) }
}

/// What the controller carries between decisions.
public struct ControllerState: Equatable, Sendable {
    /// Where the gate is believed to be, or `nil` when that is not yet known —
    /// at startup, before the SMC has been read.
    public var gate: GatePosition?
    /// Sticky: set on crossing `thermalCutoff`, cleared only below
    /// `thermalRecoveryPoint`.
    public var isThermallyHeld: Bool
    public var hasDecided: Bool

    public init(
        gate: GatePosition? = nil,
        isThermallyHeld: Bool = false,
        hasDecided: Bool = false
    ) {
        self.gate = gate
        self.isThermallyHeld = isThermallyHeld
        self.hasDecided = hasDecided
    }
}

/// Why the controller chose what it chose. Carried alongside every decision so
/// the log and `dranik status` can say something better than "closed".
public enum ChargeReason: Equatable, Sendable, CustomStringConvertible {
    case staleReading(TimeInterval)
    case emergencyFloor(percentage: Int)
    case onBattery
    case tooHot(temperature: Double, cutoff: Double)
    case coolingDown(temperature: Double, recoversAt: Double)
    case limitingDisabled
    case reachedUpper(percentage: Int, upper: Int)
    case fellToLower(percentage: Int, lower: Int)
    case withinBand(percentage: Int, lower: Int, upper: Int)
    case initialTopUp(percentage: Int, upper: Int)

    /// A stable identifier for *what* happened, as opposed to `description`,
    /// which is prose written for a person and may be reworded at any time.
    ///
    /// A client that has to behave differently per reason — an icon, a colour, a
    /// warning — must branch on this. Matching on the prose was the alternative,
    /// and it breaks silently the first time a sentence is improved.
    public var code: String {
        switch self {
        case .staleReading: return "staleReading"
        case .emergencyFloor: return "emergencyFloor"
        case .onBattery: return "onBattery"
        case .tooHot: return "tooHot"
        case .coolingDown: return "coolingDown"
        case .limitingDisabled: return "limitingDisabled"
        case .reachedUpper: return "reachedUpper"
        case .fellToLower: return "fellToLower"
        case .withinBand: return "withinBand"
        case .initialTopUp: return "initialTopUp"
        }
    }

    public var description: String {
        switch self {
        case .staleReading(let age):
            return String(format: "reading is %.0fs old — failing open", age)
        case .emergencyFloor(let percentage):
            return "charge \(percentage)% is below the \(ChargeConfig.emergencyFloor)% floor"
        case .onBattery:
            return "on battery — gate held shut so plugging in cannot micro-charge"
        case .tooHot(let temperature, let cutoff):
            return String(format: "battery at %.1f°C, above the %.1f°C cutoff", temperature, cutoff)
        case .coolingDown(let temperature, let recoversAt):
            return String(format: "still cooling: %.1f°C, resumes below %.1f°C", temperature, recoversAt)
        case .limitingDisabled:
            return "limit is 100% — charging unrestricted"
        case .reachedUpper(let percentage, let upper):
            return "charge \(percentage)% reached the \(upper)% limit"
        case .fellToLower(let percentage, let lower):
            return "charge \(percentage)% fell to the \(lower)% resume point"
        case .withinBand(let percentage, let lower, let upper):
            return "charge \(percentage)% is inside \(lower)–\(upper)% — holding position"
        case .initialTopUp(let percentage, let upper):
            return "first decision at \(percentage)% — charging up to \(upper)%"
        }
    }
}

public struct ChargeDecision: Equatable, Sendable {
    public let position: GatePosition
    public let reason: ChargeReason
    /// False when the gate is already believed to be where it should be. The
    /// caller uses this to avoid writing to the SMC for no reason.
    public let requiresWrite: Bool
}

/// Decides where the charge gate belongs. A pure function of its inputs.
///
/// Nothing here touches IOKit, the clock or the filesystem, which is the point:
/// the branch that strands a battery is the one that was never exercised, and
/// every branch below is reachable from a plain struct.
///
/// Two rules sit above all the others and are worth stating plainly.
///
/// **Fail open.** Anything the controller cannot establish resolves to `.open`.
/// The gate outlives the process that set it, so the cost of wrongly leaving
/// charging enabled is a slightly fuller battery, while the cost of wrongly
/// leaving it disabled is a laptop that quietly refuses to charge.
///
/// **The floor is not negotiable.** Below `emergencyFloor` the gate opens
/// regardless of temperature, limits or anything else.
public enum ChargeController {
    /// Readings older than this are not trusted. Comfortably longer than the
    /// gate's own ~7s response time, short enough that a wedged event source
    /// cannot hold the gate shut indefinitely.
    public static let maximumReadingAge: TimeInterval = 90

    public static func decide(
        input: ControllerInput,
        config: ChargeConfig,
        state: ControllerState
    ) -> (decision: ChargeDecision, state: ControllerState) {
        var next = state
        next.hasDecided = true

        func settle(_ position: GatePosition, _ reason: ChargeReason) -> (ChargeDecision, ControllerState) {
            let requiresWrite = state.gate != position
            next.gate = position
            return (ChargeDecision(position: position, reason: reason, requiresWrite: requiresWrite), next)
        }

        // A stale reading is indistinguishable from no reading at all, and the
        // gate must never be held shut on the strength of one.
        if input.age > maximumReadingAge {
            next.isThermallyHeld = false
            return settle(.open, .staleReading(input.age))
        }

        // Below everything else, including the thermal hold: a machine that will
        // not charge because its battery is warm and flat is worse than a warm
        // battery.
        if input.percentage < ChargeConfig.emergencyFloor {
            next.isThermallyHeld = false
            return settle(.open, .emergencyFloor(percentage: input.percentage))
        }

        // A limit of 100 means "leave my charging alone", and it has to sit above
        // every rule that closes the gate for that to be true. Only the two rules
        // above it survive, and both of them can only ever open.
        //
        // This was originally further down, below the thermal hold and the
        // on-battery rule, which made disabling the limit not actually disable
        // anything: a machine on battery with limiting off still had its gate
        // shut, so plugging in charged a few seconds late for no benefit at all.
        // The micro-charge rule exists to serve the limit; with no limit it is
        // pure cost. The thermal hold is a genuine protection, but the hardware
        // has its own — the charger reports thermal limiting on its own account —
        // and a machine refusing to charge after its owner explicitly turned the
        // feature off reads as broken.
        if config.isLimitingDisabled {
            next.isThermallyHeld = false
            return settle(.open, .limitingDisabled)
        }

        // Thermal state is evaluated before the limit so that cooling is tracked
        // even while running on battery.
        if state.isThermallyHeld {
            if input.temperature < config.thermalRecoveryPoint {
                next.isThermallyHeld = false
            } else if input.isExternalConnected {
                return settle(.closed, .coolingDown(
                    temperature: input.temperature,
                    recoversAt: config.thermalRecoveryPoint
                ))
            }
        } else if input.temperature > config.thermalCutoff {
            next.isThermallyHeld = true
            if input.isExternalConnected {
                return settle(.closed, .tooHot(
                    temperature: input.temperature,
                    cutoff: config.thermalCutoff
                ))
            }
        }

        // Running on battery, the gate is shut for a reason that only pays off
        // later: it means the gate is already closed at the moment the charger
        // is plugged in, so charging cannot begin before the controller has had
        // a chance to decide. Otherwise every reconnection costs a burst of
        // charge that no limit ever asked for.
        if !input.isExternalConnected {
            return settle(.closed, .onBattery)
        }

        if input.percentage >= config.upperLimit {
            return settle(.closed, .reachedUpper(
                percentage: input.percentage, upper: config.upperLimit
            ))
        }

        if input.percentage <= config.lowerLimit {
            return settle(.open, .fellToLower(
                percentage: input.percentage, lower: config.lowerLimit
            ))
        }

        // Inside the band. Normally the point is to change nothing — that is what
        // the band is for. But on the very first decision there is no position to
        // hold: the SMC resets to its default on boot, so the gate is open and
        // the battery has already been charging. Holding here would strand it
        // mid-band, never reaching the limit the user actually asked for.
        if !state.hasDecided || state.gate == nil {
            return settle(.open, .initialTopUp(
                percentage: input.percentage, upper: config.upperLimit
            ))
        }

        let held = state.gate ?? .open
        return settle(held, .withinBand(
            percentage: input.percentage,
            lower: config.lowerLimit,
            upper: config.upperLimit
        ))
    }
}
