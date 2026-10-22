import DranikCore
import Foundation

/// The commands that need a running daemon.
///
/// Kept apart from `status`, which reads the battery itself and works whether or
/// not anything is installed — losing the daemon should not cost the ability to
/// look at the machine.
enum ControlCommands {
    static func limit(arguments: [String], socket: String) -> Never {
        guard let first = arguments.first, let upper = Int(first) else {
            fail("limit needs a percentage, e.g. `dranik limit 80`")
        }
        let lower = arguments.count > 1 ? Int(arguments[1]) : nil
        if arguments.count > 1 && lower == nil {
            fail("the resume point must be a number, e.g. `dranik limit 80 75`")
        }
        send(ControlRequest(command: .setLimit, upper: upper, lower: lower), socket: socket)
    }

    static func disable(socket: String) -> Never {
        send(ControlRequest(command: .disable), socket: socket)
    }

    static func retrust(socket: String) -> Never {
        send(ControlRequest(command: .retrust), socket: socket)
    }

    static func reload(socket: String) -> Never {
        send(ControlRequest(command: .reload), socket: socket)
    }

    static func daemonStatus(socket: String, json: Bool) -> Never {
        send(ControlRequest(command: .status), socket: socket, json: json)
    }

    private static func send(
        _ request: ControlRequest, socket: String, json: Bool = false
    ) -> Never {
        let response: ControlResponse
        do {
            response = try ControlClient.send(request, to: socket)
        } catch {
            fail("\(error)")
        }

        if json {
            if let data = try? ControlProtocol.encode(response) {
                FileHandle.standardOutput.write(data)
            }
            exit(response.ok ? 0 : 1)
        }

        if let error = response.error {
            fail(error)
        }
        for note in response.notes {
            print("note: \(note)")
        }
        if let report = response.report {
            print(render(report))
        }
        exit(response.ok ? 0 : 1)
    }

    private static func render(_ report: DaemonReport) -> String {
        let byFirmware = report.heldBy == DaemonReport.HeldBy.firmware
        var lines = [
            row("Limit", "\(report.lowerLimit)–\(report.upperLimit) %"),
            row("Held by", describeHolder(report.heldBy)),
            // Two different things wear the same row. On the gate path the
            // position of our own key is the interesting fact; on the firmware
            // path we have no key, and what matters is whether the charger is
            // currently being held off.
            byFirmware
                ? row("Charging", describeCharging(report.gate))
                : row("Gate", report.gate),
            row("Reason", report.reason),
            row("Charger says", report.chargerReason ?? "-"),
        ]
        if !byFirmware {
            // Both of these are the gate path's machinery. Printing them under
            // firmware control would promise behaviour that is not there.
            lines.append(row("Sleep policy", report.sleepPolicy))
            lines.append(row("Thermal cutoff", String(format: "%.0f °C", report.thermalCutoff)))
        }
        if report.preventIdleSleepWhileCharging && !byFirmware {
            lines.append(row("Idle sleep", "held off while charging"))
        }
        // Before the explanations, not after them: they are all about how the
        // limit behaves, and the first thing to know is that there isn't one.
        if report.upperLimit >= 100 {
            lines.append(row("", "limiting is off — charging is unmanaged"))
        }
        // And skipped entirely when limiting is off, because "a lidded laptop on
        // a charger stops at the limit" is a promise about a limit that is not
        // set.
        if byFirmware && report.upperLimit < 100 {
            lines.append("")
            lines.append("  The firmware holds the corridor, so it holds it while the Mac is")
            lines.append("  asleep too: a lidded laptop on a charger stops at the limit, and")
            lines.append("  `sleepPolicy` no longer applies.")
            lines.append("  The thermal cutoff does not apply on this path yet — overheating")
            lines.append("  is left to the firmware's own protection.")
            lines.append("  The firmware measures against the battery gauge's own charge, which")
            lines.append("  reads a little lower than macOS shows — so charging settles a point")
            lines.append("  or two above the limit. `dranik status` prints both figures.")
            lines.append("  A reboot clears the corridor, so the daemon writes it again when it")
            lines.append("  starts. Until it does, charging is unrestricted.")
        }
        if !report.limitingIsSupported {
            // Otherwise identical on screen to a gate that is open on purpose,
            // which is the one reading that must not be left available.
            lines.append("")
            lines.append("  NOTE: this Mac offers nothing this build can limit charging with.")
            lines.append("  The daemon runs and reports, but it is limiting nothing.")
        }
        // The charger reporting something this project cannot name means
        // something other than this daemon is involved — macOS's own battery
        // management being the likely candidate, since it is not readable as a
        // setting from anywhere unprivileged.
        if report.chargerReason?.contains("unknown") == true {
            lines.append("")
            lines.append("  Note: the charger reports a reason this build does not recognise.")
            lines.append("  Something else may also be managing charging — check")
            lines.append("  System Settings > Battery > Battery Health > Optimized Charging.")
        }
        if !report.gateIsTrusted {
            // The one state worth shouting about: the daemon is running, looks
            // healthy, and is not enforcing anything.
            lines.append("")
            lines.append("  WARNING: the daemon has stopped trusting the charge gate.")
            lines.append("  It will not close it again. Charging is NOT being limited.")
            lines.append("  Look at why first: dranik soak --since 24h")
            lines.append("  Then re-arm it: dranik retrust")
        }
        if report.version != DranikVersion.current {
            // Installing does not restart the daemon, so this is the ordinary
            // state after an upgrade rather than a strange one.
            lines.append("")
            lines.append("  NOTE: the daemon is version \(report.version), this is "
                + "\(DranikVersion.current).")
            lines.append("  Restart it to match: sudo launchctl kickstart -k system/com.dranik.battery")
        }
        return lines.joined(separator: "\n")
    }

    private static func describeHolder(_ heldBy: String) -> String {
        switch heldBy {
        case DaemonReport.HeldBy.firmware:
            // Not "survives restarts" unqualified: a reboot clears it, measured
            // 2026-10-22. Saying so here is the difference between a person
            // knowing why their battery reached 100 % overnight and not.
            return "the firmware — holds through sleep and crashes; a reboot clears it"
        case DaemonReport.HeldBy.daemon:
            return "this daemon — only while it is running"
        default:
            return "nothing"
        }
    }

    private static func describeCharging(_ gate: String) -> String {
        switch gate {
        case "closed": return "held off"
        case "open": return "permitted"
        default: return gate
        }
    }

    private static func row(_ label: String, _ value: String) -> String {
        "  " + label.padding(toLength: 16, withPad: " ", startingAt: 0) + value
    }
}
