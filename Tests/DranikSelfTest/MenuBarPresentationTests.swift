import DranikCore
import Foundation

private func daemonReport(
    upper: Int = 80,
    lower: Int = 75,
    gate: String = "closed",
    reasonCode: String = "reachedUpper",
    trusted: Bool = true,
    supported: Bool = true,
    chargerReason: String? = nil
) -> DaemonReport {
    DaemonReport(
        upperLimit: upper, lowerLimit: lower, thermalCutoff: 40,
        sleepPolicy: "holdLimit", gate: gate, reason: "because",
        gateIsTrusted: trusted, chargerReason: chargerReason, reasonCode: reasonCode,
        limitingIsSupported: supported, decidedAt: Date()
    )
}

private func facts(
    percentage: Int = 80,
    charging: Bool = false,
    plugged: Bool = true,
    temperature: Double = 31,
    minutes: Int? = nil
) -> BatteryFacts {
    BatteryFacts(
        percentage: percentage, isCharging: charging, isExternalConnected: plugged,
        temperature: temperature, minutesRemaining: minutes
    )
}

func runMenuBarPresentationTests() {
    // MARK: - No usable answer from the daemon

    test("no daemon at all is said plainly, and the controls go dead") {
        let summary = MenuBarPresentation.summary(link: .notRunning, battery: facts())
        expectEqual(summary.headline, "Daemon not running")
        expectEqual(summary.icon, .warning)
        expectFalse(summary.controlsAreEnabled, "a limit nobody will hear is not a control")
        expectFalse(summary.isLimiting)
    }

    test("a daemon that will not answer is distinguished from one that is absent") {
        let summary = MenuBarPresentation.summary(
            link: .unreachable("connection refused"), battery: facts()
        )
        expectEqual(summary.headline, "Daemon not responding")
        expectEqual(summary.detail, "connection refused")
        expectFalse(summary.controlsAreEnabled)
    }

    // MARK: - Not enforcing anything, while looking fine

    test("a gate the daemon no longer trusts is the loudest state there is") {
        let summary = MenuBarPresentation.summary(
            link: .connected(daemonReport(trusted: false)), battery: facts()
        )
        expectEqual(summary.tone, .alarm)
        expectTrue(summary.headline.hasPrefix("Not limiting"), summary.headline)
    }

    test("an untrusted gate outranks anything else that could be said") {
        // Everything below would otherwise produce a calm, plausible sentence.
        let summary = MenuBarPresentation.summary(
            link: .connected(daemonReport(gate: "open", reasonCode: "onBattery", trusted: false)),
            battery: facts(charging: false, plugged: false, minutes: 200)
        )
        expectEqual(summary.tone, .alarm)
        expectTrue(summary.headline.contains("gate"), summary.headline)
    }

    test("hardware with no charge gate says so and offers no controls") {
        let summary = MenuBarPresentation.summary(
            link: .connected(daemonReport(gate: "open", supported: false)), battery: facts()
        )
        expectEqual(summary.headline, "This Mac has no charge gate")
        expectFalse(summary.controlsAreEnabled)
        expectEqual(summary.tone, .caution)
    }

    test("a stale reading is reported as not limiting, not as calm") {
        let summary = MenuBarPresentation.summary(
            link: .connected(daemonReport(gate: "open", reasonCode: "staleReading")),
            battery: facts()
        )
        expectEqual(summary.icon, .warning)
        expectTrue(summary.headline.contains("stale"), summary.headline)
    }

    test("an unreadable battery still says what the daemon knows") {
        let summary = MenuBarPresentation.summary(
            link: .connected(daemonReport()), battery: nil
        )
        expectEqual(summary.tone, .caution)
        expectEqual(summary.upperLimit, 80, "the limit is known even when the battery is not")
    }

    // MARK: - Ordinary states

    test("on battery, the gate's position is not what gets shown") {
        // The daemon holds the gate shut on battery by design. Reporting that as
        // "Holding at 80 %" would be true and useless: nothing is charging.
        let summary = MenuBarPresentation.summary(
            link: .connected(daemonReport(gate: "closed", reasonCode: "onBattery")),
            battery: facts(percentage: 64, plugged: false, minutes: 200)
        )
        expectEqual(summary.icon, .onBattery)
        expectEqual(summary.headline, "On battery — 3 h 20 min left")
    }

    test("on battery with no estimate yet says only what is known") {
        let summary = MenuBarPresentation.summary(
            link: .connected(daemonReport(gate: "closed", reasonCode: "onBattery")),
            battery: facts(plugged: false, minutes: nil)
        )
        expectEqual(summary.headline, "On battery")
    }

    test("a limit of 100 reads as not limiting rather than as a limit of 100") {
        let summary = MenuBarPresentation.summary(
            link: .connected(daemonReport(upper: 100, gate: "open", reasonCode: "limitingDisabled")),
            battery: facts(charging: true)
        )
        expectEqual(summary.headline, "Not limiting — charging to full")
        expectEqual(summary.icon, .unlimited)
        expectFalse(summary.isLimiting)
        expectTrue(summary.controlsAreEnabled, "turning it back on must stay possible")
    }

    test("a thermal hold names the temperature, since that is the whole reason") {
        let summary = MenuBarPresentation.summary(
            link: .connected(daemonReport(reasonCode: "tooHot")),
            battery: facts(temperature: 41.2)
        )
        expectEqual(summary.headline, "Paused — battery at 41.2 °C")
        expectEqual(summary.tone, .caution)
    }

    test("still cooling reads the same as too hot — the difference is ours, not theirs") {
        let summary = MenuBarPresentation.summary(
            link: .connected(daemonReport(reasonCode: "coolingDown")),
            battery: facts(temperature: 39.4)
        )
        expectTrue(summary.headline.hasPrefix("Paused"), summary.headline)
    }

    test("below the floor, charging is explained rather than looking like a broken limit") {
        let summary = MenuBarPresentation.summary(
            link: .connected(daemonReport(gate: "open", reasonCode: "emergencyFloor")),
            battery: facts(percentage: 12, charging: true)
        )
        expectEqual(summary.headline, "Charging — below the 20 % floor")
        expectEqual(summary.icon, .chargingToLimit)
    }

    test("a closed gate on the charger is the limit doing its job") {
        let summary = MenuBarPresentation.summary(
            link: .connected(daemonReport(gate: "closed", reasonCode: "reachedUpper")),
            battery: facts(percentage: 80)
        )
        expectEqual(summary.headline, "Holding at 80 %")
        expectEqual(summary.icon, .holding)
        expectEqual(summary.tone, .normal)
    }

    test("charging towards the limit says where it is going") {
        let summary = MenuBarPresentation.summary(
            link: .connected(daemonReport(gate: "open", reasonCode: "fellToLower")),
            battery: facts(percentage: 74, charging: true)
        )
        expectEqual(summary.headline, "Charging to 80 %")
        expectEqual(summary.icon, .chargingToLimit)
    }

    test("plugged in, permitted, and not charging is its own state") {
        let summary = MenuBarPresentation.summary(
            link: .connected(daemonReport(gate: "open", reasonCode: "withinBand")),
            battery: facts(percentage: 77, charging: false)
        )
        expectEqual(summary.headline, "Plugged in — not charging")
    }

    // MARK: - What the charger says

    test("the charger is quoted only when it contradicts us") {
        let agreeing = MenuBarPresentation.summary(
            link: .connected(daemonReport(gate: "closed", chargerReason: "inhibited")),
            battery: facts()
        )
        expectNil(agreeing.detail, "agreement is not news and does not deserve a line")

        let disagreeing = MenuBarPresentation.summary(
            link: .connected(daemonReport(
                gate: "open", reasonCode: "withinBand", chargerReason: "inhibited"
            )),
            battery: facts(percentage: 77)
        )
        expectTrue(disagreeing.detail?.contains("Something else") == true,
                   "\(String(describing: disagreeing.detail))")
    }

    test("a charger reason this build cannot name is surfaced, not swallowed") {
        let summary = MenuBarPresentation.summary(
            link: .connected(daemonReport(chargerReason: "inhibited|unknown(0x40)")),
            battery: facts()
        )
        expectTrue(summary.detail?.contains("does not recognise") == true,
                   "\(String(describing: summary.detail))")
    }

    // MARK: - Formatting

    test("durations read the way a person would say them") {
        expectEqual(MenuBarPresentation.duration(45), "45 min")
        expectEqual(MenuBarPresentation.duration(60), "1 h")
        expectEqual(MenuBarPresentation.duration(200), "3 h 20 min")
    }

    test("every reason the controller can produce has a stable code") {
        // The presentation branches on these strings. A new case arriving with a
        // code that collides with an old one would route it to the wrong words.
        let reasons: [ChargeReason] = [
            .staleReading(120), .emergencyFloor(percentage: 15), .onBattery,
            .tooHot(temperature: 41, cutoff: 40), .coolingDown(temperature: 39, recoversAt: 38),
            .limitingDisabled, .reachedUpper(percentage: 80, upper: 80),
            .fellToLower(percentage: 75, lower: 75),
            .withinBand(percentage: 77, lower: 75, upper: 80),
            .initialTopUp(percentage: 60, upper: 80),
        ]
        let codes = reasons.map(\.code)
        expectEqual(Set(codes).count, codes.count, "codes must be unique: \(codes)")
        expectTrue(codes.allSatisfy { !$0.isEmpty })
    }
}
