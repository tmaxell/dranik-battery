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
        var lines = [
            row("Limit", "\(report.lowerLimit)–\(report.upperLimit) %"),
            row("Gate", report.gate),
            row("Reason", report.reason),
            row("Sleep policy", report.sleepPolicy),
            row("Thermal cutoff", String(format: "%.0f °C", report.thermalCutoff)),
        ]
        if report.upperLimit >= 100 {
            lines.append(row("", "limiting is off — charging is unmanaged"))
        }
        if !report.gateIsTrusted {
            // The one state worth shouting about: the daemon is running, looks
            // healthy, and is not enforcing anything.
            lines.append("")
            lines.append("  WARNING: the daemon has stopped trusting the charge gate.")
            lines.append("  It will not close it again. Charging is NOT being limited.")
            lines.append("  Restart it: sudo launchctl kickstart -k system/com.dranik.battery")
        }
        return lines.joined(separator: "\n")
    }

    private static func row(_ label: String, _ value: String) -> String {
        "  " + label.padding(toLength: 16, withPad: " ", startingAt: 0) + value
    }
}
