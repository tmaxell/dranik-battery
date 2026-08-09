import Foundation

/// User-settable limits, with every value forced into a range the controller can
/// safely act on.
///
/// Bounds are enforced here rather than at the edges because this is the type the
/// controller reads. A configuration file, an IPC message and a test fixture all
/// arrive through `init`, so none of them can express a limit that would strand
/// the battery somewhere useless.
/// What to do with the gate when the machine goes to sleep.
///
/// There is no third option on hardware without a firmware charge limit. The gate
/// state survives sleep (measured), and the daemon does not run during it, so
/// either the gate is shut and the machine will not charge overnight, or it is
/// open and the battery charges past the limit. Both are honest; neither is free.
public enum SleepPolicy: String, Codable, Equatable, Sendable {
    /// Close the gate before sleeping. The limit holds; a lidded machine on AC
    /// will not charge.
    case holdLimit
    /// Leave the gate open. The machine charges overnight, past the limit.
    case allowCharge
}

public struct ChargeConfig: Equatable, Sendable {
    /// Charge is held at or below this. 100 disables limiting entirely.
    public let upperLimit: Int
    /// Charging resumes at or below this. The gap to `upperLimit` is what stops
    /// the gate flapping every time the battery drifts a percent.
    public let lowerLimit: Int
    /// Battery temperature in °C above which charging is held off.
    public let thermalCutoff: Double
    /// What happens to the gate at sleep. See `SleepPolicy`.
    public let sleepPolicy: SleepPolicy
    /// Hold off idle sleep while charging towards the limit.
    ///
    /// Off by default on purpose: a laptop that will not sleep for reasons its
    /// owner cannot see is a worse problem than a few percent of charge.
    public let preventIdleSleepWhileCharging: Bool

    /// Below this, charging is permitted no matter what else is true. Not
    /// configurable: it is the backstop for the rest of the logic being wrong,
    /// and a backstop with a dial is not a backstop.
    public static let emergencyFloor = 20

    /// How far the temperature must fall below `thermalCutoff` before charging
    /// resumes. Without it the gate would chatter around the threshold.
    public static let thermalRecoveryMargin = 2.0

    public static let upperRange = 50...100
    public static let lowerFloor = 20
    public static let thermalRange = 30.0...50.0
    public static let defaultUpper = 80
    public static let defaultHysteresis = 5
    public static let defaultThermalCutoff = 40.0

    /// What `init` had to change to make the values usable. Empty when the input
    /// was already sound. Reported rather than swallowed: a limit silently
    /// different from the one asked for is its own kind of failure.
    public let corrections: [String]

    public init(
        upperLimit: Int = ChargeConfig.defaultUpper,
        lowerLimit: Int? = nil,
        thermalCutoff: Double = ChargeConfig.defaultThermalCutoff,
        sleepPolicy: SleepPolicy = .holdLimit,
        preventIdleSleepWhileCharging: Bool = false
    ) {
        var corrections: [String] = []

        // An upper limit below 50 is far more likely to be a mistake than an
        // intention, and living there is worse for the battery than 80 anyway.
        let upper: Int
        if Self.upperRange.contains(upperLimit) {
            upper = upperLimit
        } else {
            upper = Self.defaultUpper
            corrections.append(
                "upperLimit \(upperLimit) outside \(Self.upperRange) — using \(upper)"
            )
        }

        let requestedLower = lowerLimit ?? (upper - Self.defaultHysteresis)
        // The band must be wide enough to actually be a band.
        let lowerCeiling = upper - 2
        let lower: Int
        if requestedLower >= Self.lowerFloor && requestedLower <= lowerCeiling {
            lower = requestedLower
        } else {
            lower = max(Self.lowerFloor, min(lowerCeiling, upper - Self.defaultHysteresis))
            corrections.append(
                "lowerLimit \(requestedLower) outside \(Self.lowerFloor)...\(lowerCeiling) — using \(lower)"
            )
        }

        let cutoff: Double
        if Self.thermalRange.contains(thermalCutoff) {
            cutoff = thermalCutoff
        } else {
            cutoff = Self.defaultThermalCutoff
            corrections.append(
                "thermalCutoff \(thermalCutoff) outside \(Self.thermalRange) — using \(cutoff)"
            )
        }

        self.upperLimit = upper
        self.lowerLimit = lower
        self.thermalCutoff = cutoff
        self.sleepPolicy = sleepPolicy
        self.preventIdleSleepWhileCharging = preventIdleSleepWhileCharging
        self.corrections = corrections
    }

    /// True when the user has asked for no limiting at all.
    public var isLimitingDisabled: Bool {
        upperLimit >= 100
    }

    public var thermalRecoveryPoint: Double {
        thermalCutoff - Self.thermalRecoveryMargin
    }
}
