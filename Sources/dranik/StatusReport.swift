import DranikCore
import DranikPower
import DranikSMC
import Foundation

/// Everything `dranik status` shows, gathered in one place so the human and JSON
/// renderings cannot drift apart.
struct StatusReport {
    let battery: BatterySnapshot
    let capabilities: Capabilities?
    let capabilitiesError: String?
    /// Raw readings of the charge-gate keys — the hardware's own answer, not the
    /// daemon's account of it, which is the point of having both commands.
    let gateReadings: [(key: SMCKey, value: String)]
    /// What the firmware says its own corridor is, when this machine has one.
    /// Read here rather than asked of the daemon for the same reason as the gate
    /// readings: this command answers from the hardware.
    let firmwareLimit: FirmwareLimitState?
    /// The battery gauge's own state of charge, from `BRSC`.
    ///
    /// Worth a line of its own because it is the number the firmware enforces
    /// its corridor against, and it is not the number macOS displays: 79 against
    /// 83, measured 2026-10-15. Without it, a Mac told to stop at 80 and sitting
    /// at 83 has no visible explanation.
    let gaugeCharge: Int?
    let telemetry: [(label: String, value: String)]

    static func gather() throws -> StatusReport {
        let battery = try PowerReader.snapshot()

        var capabilities: Capabilities?
        var capabilitiesError: String?
        var gateReadings: [(SMCKey, String)] = []
        var firmwareLimit: FirmwareLimitState?
        var gaugeCharge: Int?
        var telemetry: [(String, String)] = []

        do {
            let smc = try SMCConnection()
            defer { smc.close() }

            let detected = try Capabilities.detect(using: smc)
            capabilities = detected

            for key in detected.chargeGate.keys + detected.firmwareLimit.keys {
                if let reading = try smc.read(key) {
                    gateReadings.append((key, reading.value.description))
                }
            }

            if let brsc = SMCKey("BRSC"), let reading = try smc.read(brsc) {
                gaugeCharge = reading.value.doubleValue.map { Int($0) }
            }

            if let spec = detected.firmwareLimit.spec,
               let activation = try smc.read(spec.activation)?.bytes.first,
               let upper = try smc.read(spec.upper)?.bytes,
               let lower = try smc.read(spec.lower)?.bytes {
                firmwareLimit = FirmwareLimitState(
                    isActive: activation == FirmwareLimitSpec.activeByte,
                    upper: FirmwareLimitSpec.percent(from: upper),
                    lower: FirmwareLimitSpec.percent(from: lower)
                )
            }

            for (key, label, unit) in Self.telemetryKeys {
                guard let smcKey = SMCKey(key), let reading = try smc.read(smcKey) else { continue }
                guard let number = reading.value.doubleValue else { continue }
                telemetry.append((label, String(format: "%.2f %@", number, unit)))
            }
        } catch {
            capabilitiesError = String(describing: error)
        }

        return StatusReport(
            battery: battery,
            capabilities: capabilities,
            capabilitiesError: capabilitiesError,
            gateReadings: gateReadings,
            firmwareLimit: firmwareLimit,
            gaugeCharge: gaugeCharge,
            telemetry: telemetry
        )
    }

    /// SMC keys with no equivalent in the public IOKit battery properties.
    private static let telemetryKeys: [(String, String, String)] = [
        ("PDTR", "Adapter input", "W"),
        ("PSTR", "System draw", "W"),
        ("PPBR", "Battery power", "W"),
        ("VD0R", "Adapter voltage", "V"),
        ("ID0R", "Adapter current", "A"),
        ("TB0T", "Battery sensor", "°C"),
    ]
}

extension StatusReport {
    func humanReadable() -> String {
        var lines: [String] = []

        lines.append("Battery")
        lines.append(row("Charge", "\(battery.percentage) %"))
        lines.append(row("State", batteryState))
        if let health = battery.healthFraction {
            lines.append(row("Health", String(
                format: "%.1f %% (%d / %d mAh)",
                health * 100, battery.rawMaxCapacity, battery.designCapacity
            )))
        }
        lines.append(row("Cycles", "\(battery.cycleCount)"))
        lines.append(row("Temperature", String(format: "%.1f °C", battery.temperature)))
        lines.append(row("Voltage", "\(battery.voltage) mV"))
        lines.append(row("Current", "\(battery.amperage) mA"))
        lines.append(row("Power", String(format: "%+.2f W", battery.powerWatts)))
        if let minutes = battery.timeRemaining {
            lines.append(row("Time remaining", "\(minutes / 60) h \(minutes % 60) min"))
        }
        if let reason = battery.notChargingReason {
            lines.append(row("Not-charging reason", "\(reason)"))
        }
        if let reason = battery.chargerInhibitReason {
            lines.append(row("Charger inhibit reason", "\(reason)"))
        }

        if !telemetry.isEmpty {
            lines.append("")
            lines.append("Power (SMC)")
            for entry in telemetry {
                lines.append(row(entry.label, entry.value))
            }
        }

        lines.append("")
        lines.append("Charge control")
        if let error = capabilitiesError {
            lines.append(row("SMC", "unavailable — \(error)"))
        } else if let capabilities {
            lines.append(row("Charge gate", describe(capabilities.chargeGate)))
            lines.append(row("Firmware limit", describeFirmwareLimit(capabilities)))
            if capabilities.firmwareLimit.isSupported, let gaugeCharge {
                // The limit is enforced against this figure, not against the one
                // at the top of this report.
                var line = "\(gaugeCharge) % (what the corridor is measured against)"
                if gaugeCharge != battery.percentage {
                    line += " — macOS shows \(battery.percentage) %"
                }
                lines.append(row("Gauge charge", line))
            }
            lines.append(row("Hardware 80 % limit", capabilities.hasHardwareChargeLimit ? "yes (CHWA)" : "no"))
            lines.append(row(
                "Adapter control keys",
                capabilities.adapterControlKeys.isEmpty
                    ? "none"
                    : capabilities.adapterControlKeys.map(\.description).joined(separator: ", ")
            ))
            for reading in gateReadings {
                lines.append(row("\(reading.key) reads", reading.value))
            }
        }

        lines.append("")
        lines.append(daemonHint)

        return lines.joined(separator: "\n")
    }

    func json() throws -> String {
        var root: [String: Any] = [
            "battery": [
                "percentage": battery.percentage,
                "isCharging": battery.isCharging,
                "isExternalConnected": battery.isExternalConnected,
                "isFullyCharged": battery.isFullyCharged,
                "rawCurrentCapacity": battery.rawCurrentCapacity,
                "rawMaxCapacity": battery.rawMaxCapacity,
                "designCapacity": battery.designCapacity,
                "healthFraction": battery.healthFraction as Any,
                "cycleCount": battery.cycleCount,
                "temperature": battery.temperature,
                "voltage": battery.voltage,
                "amperage": battery.amperage,
                "powerWatts": battery.powerWatts,
                "timeRemaining": battery.timeRemaining as Any,
                // Both forms: the names are what a human wants, the raw mask is
                // what survives a firmware revision setting a bit we cannot name.
                "notChargingReason": battery.notChargingReason
                    .map(String.init(describing:)) as Any,
                "notChargingReasonRaw": battery.notChargingReason
                    .map { String($0.rawValue) } as Any,
                "chargerInhibitReason": battery.chargerInhibitReason as Any,
            ],
        ]

        if let capabilities {
            root["capabilities"] = [
                "chargeGate": describe(capabilities.chargeGate),
                "chargeGateKeys": capabilities.chargeGate.keys.map(\.description),
                "hasHardwareChargeLimit": capabilities.hasHardwareChargeLimit,
                "adapterControlKeys": capabilities.adapterControlKeys.map(\.description),
                "gateReadings": Dictionary(
                    uniqueKeysWithValues: gateReadings.map { ($0.key.description, $0.value) }
                ),
            ]
        }
        if let capabilitiesError {
            root["capabilitiesError"] = capabilitiesError
        }
        root["telemetry"] = Dictionary(uniqueKeysWithValues: telemetry.map { ($0.label, $0.value) })

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// `status` reads the machine directly and says nothing about whether a
    /// limit is being enforced. Pointing at the command that does is more useful
    /// than leaving someone to wonder why the gate is shut.
    private var daemonHint: String {
        FileManager.default.fileExists(atPath: ControlProtocol.defaultSocketPath)
            ? "A daemon is running — `dranik daemon` shows what it is doing."
            : "No daemon is running, so nothing is limiting charge. `make install` starts one."
    }

    private var batteryState: String {
        if battery.isCharging { return "charging" }
        if battery.isFullyCharged { return "full" }
        return battery.isExternalConnected ? "on AC, not charging" : "on battery"
    }

    private func describe(_ gate: ChargeGate) -> String {
        switch gate {
        case .single(let spec):
            return "\(spec.key) (single key)"
        case .pair(let first, let second):
            return "\(first.key) + \(second.key) (key pair)"
        case .unsupported:
            return "unsupported"
        }
    }

    /// The corridor and whether it is live, in one line.
    ///
    /// Says the keys as well as the state, because "no" to a question about
    /// firmware support and "no" to a question about whether it is switched on
    /// are different answers that would otherwise read the same.
    private func describeFirmwareLimit(_ capabilities: Capabilities) -> String {
        guard let spec = capabilities.firmwareLimit.spec else { return "unsupported" }
        let keys = spec.keys.map(\.description).joined(separator: "+")
        guard let state = firmwareLimit else { return "\(keys) — unreadable" }
        guard state.isActive else { return "\(keys) — off" }
        return "\(keys) — active, \(state.lower)–\(state.upper) %"
    }

    private func row(_ label: String, _ value: String) -> String {
        "  " + label.padding(toLength: 24, withPad: " ", startingAt: 0) + value
    }
}
