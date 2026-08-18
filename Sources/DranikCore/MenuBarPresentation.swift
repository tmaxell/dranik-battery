import Foundation

/// What the menu bar shows, decided as a pure function.
///
/// The views that will consume this contain no rule about meaning — only about
/// layout. Everything that could be wrong about *what* is displayed is decided
/// here, where it can be tested without a screen, a daemon or a battery. This is
/// the habit that paid for itself three times in the daemon, applied to the one
/// part of the product a test cannot look at.

/// The subset of a battery reading the menu bar has any use for.
///
/// Deliberately not `BatterySnapshot`: that type lives in `DranikPower` and
/// carries IOKit with it, and this module is the one that must not touch the
/// system. The caller maps one to the other.
public struct BatteryFacts: Equatable, Sendable {
    public let percentage: Int
    public let isCharging: Bool
    public let isExternalConnected: Bool
    /// Degrees Celsius.
    public let temperature: Double
    /// Minutes until full or empty; `nil` while macOS is still estimating.
    public let minutesRemaining: Int?

    public init(
        percentage: Int,
        isCharging: Bool,
        isExternalConnected: Bool,
        temperature: Double,
        minutesRemaining: Int? = nil
    ) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isExternalConnected = isExternalConnected
        self.temperature = temperature
        self.minutesRemaining = minutesRemaining
    }
}

/// How the last attempt to reach the daemon went.
///
/// Three cases rather than an optional report, because "no daemon installed" and
/// "installed but not answering" call for different words and the difference
/// matters to whoever is reading.
public enum DaemonLink: Equatable, Sendable {
    case connected(DaemonReport)
    case notRunning
    case unreachable(String)
}

public struct MenuBarSummary: Equatable, Sendable {
    /// Which glyph the status item shows. Names describe the situation, not the
    /// picture, so the artwork can change without the logic moving.
    public enum Icon: String, Equatable, Sendable {
        case unlimited
        case chargingToLimit
        case holding
        case onBattery
        case warning
    }

    public enum Tone: String, Equatable, Sendable {
        case normal
        case caution
        case alarm
    }

    /// One sentence answering "is my machine charging, and why not".
    public let headline: String
    /// A second line, present only when there is something worth adding. Never a
    /// restatement of the headline in other words.
    public let detail: String?
    public let icon: Icon
    public let tone: Tone
    /// False when changing the limit would achieve nothing — no daemon to tell,
    /// or no gate to move.
    public let controlsAreEnabled: Bool
    public let isLimiting: Bool
    public let upperLimit: Int
    public let lowerLimit: Int

    public init(
        headline: String,
        detail: String?,
        icon: Icon,
        tone: Tone,
        controlsAreEnabled: Bool,
        isLimiting: Bool,
        upperLimit: Int,
        lowerLimit: Int
    ) {
        self.headline = headline
        self.detail = detail
        self.icon = icon
        self.tone = tone
        self.controlsAreEnabled = controlsAreEnabled
        self.isLimiting = isLimiting
        self.upperLimit = upperLimit
        self.lowerLimit = lowerLimit
    }
}

public enum MenuBarPresentation {
    /// Shown when there is no daemon to ask. Not a claim about configuration —
    /// just something for the disabled slider to sit at.
    static let fallbackLimits = (upper: ChargeConfig.defaultUpper,
                                 lower: ChargeConfig.defaultUpper - ChargeConfig.defaultHysteresis)

    /// The order of the checks below *is* the design. Anything that means "the
    /// limit is not being enforced" outranks anything about charging, because a
    /// limiter that has quietly stopped limiting is the failure this whole
    /// project exists to avoid, and it must not be reported as a calm state.
    public static func summary(link: DaemonLink, battery: BatteryFacts?) -> MenuBarSummary {
        switch link {
        case .connected(let report):
            return connected(report, battery)
        case .notRunning:
            return offline("Daemon not running", "Charging is not being limited.")
        case .unreachable(let why):
            return offline("Daemon not responding", why)
        }
    }

    /// Nothing to ask and nothing to command: the limits shown are a resting
    /// place for a disabled slider, not a claim about how the machine is set up.
    private static func offline(_ headline: String, _ detail: String) -> MenuBarSummary {
        MenuBarSummary(
            headline: headline,
            detail: detail,
            icon: .warning,
            tone: .caution,
            controlsAreEnabled: false,
            isLimiting: false,
            upperLimit: fallbackLimits.upper,
            lowerLimit: fallbackLimits.lower
        )
    }

    private static func connected(
        _ report: DaemonReport, _ battery: BatteryFacts?
    ) -> MenuBarSummary {
        let isLimiting = report.upperLimit < 100

        func summary(
            _ headline: String,
            _ detail: String? = nil,
            icon: MenuBarSummary.Icon,
            tone: MenuBarSummary.Tone = .normal,
            controls: Bool = true
        ) -> MenuBarSummary {
            MenuBarSummary(
                headline: headline,
                detail: detail ?? chargerDisagreement(report),
                icon: icon,
                tone: tone,
                controlsAreEnabled: controls,
                isLimiting: isLimiting,
                upperLimit: report.upperLimit,
                lowerLimit: report.lowerLimit
            )
        }

        // The daemon is up, looks healthy, and is enforcing nothing. Loudest
        // state there is, and the only one worth the word "gate" on screen —
        // because there is no way to say it that is both accurate and gentler.
        if !report.gateIsTrusted {
            return summary(
                "Not limiting — the gate stopped responding",
                "Restart the daemon to try again.",
                icon: .warning, tone: .alarm
            )
        }

        if !report.limitingIsSupported {
            return summary(
                "This Mac has no charge gate",
                "The daemon is running, but there is nothing here it can limit.",
                icon: .warning, tone: .caution, controls: false
            )
        }

        if report.reasonCode == "staleReading" {
            return summary(
                "Not limiting — the battery reading went stale",
                "Charging was allowed to resume rather than held on old data.",
                icon: .warning, tone: .caution
            )
        }

        guard let battery else {
            // The report alone still says something true; the battery does not
            // read from anywhere privileged, so this is rare rather than routine.
            return summary(
                isLimiting ? "Limiting to \(report.upperLimit) %" : "Not limiting",
                "The battery is not readable right now.",
                icon: isLimiting ? .holding : .unlimited, tone: .caution
            )
        }

        // Before anything about limits: on battery, nothing is charging and the
        // gate's position says nothing a person would want to read.
        if !battery.isExternalConnected {
            return summary(onBatteryHeadline(battery), icon: .onBattery)
        }

        if !isLimiting {
            return summary("Not limiting — charging to full", icon: .unlimited)
        }

        switch report.reasonCode {
        case "tooHot", "coolingDown":
            return summary(
                String(format: "Paused — battery at %.1f °C", battery.temperature),
                "Charging resumes once it cools.",
                icon: .holding, tone: .caution
            )
        case "emergencyFloor":
            return summary(
                "Charging — below the \(ChargeConfig.emergencyFloor) % floor",
                "The limit does not apply this low.",
                icon: .chargingToLimit
            )
        default:
            break
        }

        if report.gate == GatePosition.closed.rawValue {
            return summary("Holding at \(report.upperLimit) %", icon: .holding)
        }
        if battery.isCharging {
            return summary("Charging to \(report.upperLimit) %", icon: .chargingToLimit)
        }
        // Plugged in, allowed to charge, and not charging: the charger's own
        // business — a full battery, or macOS holding it back for its own reasons.
        return summary("Plugged in — not charging", icon: .holding)
    }

    /// The one thing worth saying about the charger, and only when it contradicts
    /// us or says something this build cannot name.
    ///
    /// Agreement is not news. Printing "charger says: inhibited" under "Holding
    /// at 80 %" costs a line to say the same thing twice.
    private static func chargerDisagreement(_ report: DaemonReport) -> String? {
        guard let charger = report.chargerReason else { return nil }
        if charger.contains("unknown") {
            return "The charger gives a reason this build does not recognise."
        }
        if report.gate == GatePosition.open.rawValue && charger.contains("inhibited") {
            return "Something else is holding charging back — check Optimized Battery Charging."
        }
        return nil
    }

    private static func onBatteryHeadline(_ battery: BatteryFacts) -> String {
        guard let minutes = battery.minutesRemaining, minutes > 0 else {
            return "On battery"
        }
        return "On battery — \(duration(minutes)) left"
    }

    public static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        if rest == 0 { return "\(hours) h" }
        return "\(hours) h \(rest) min"
    }
}
