import DranikCore
import Foundation

/// `dranik soak` — did the daemon behave over the last stretch of time?
///
/// `dranik daemon` answers "is it right now". Neither that nor any single log
/// line would have shown the watchdog forcing the gate open after every sleep;
/// that took reading three days of records together. This is that reading, as a
/// command.
enum SoakCommand {
    static func run(since: String, socket: String) -> Never {
        let records: [DaemonLogRecord]
        do {
            records = try fetch(since: since)
        } catch {
            fail("\(error)")
        }

        guard !records.isEmpty else {
            // An empty window is not evidence that nothing is running. A daemon
            // with no gate to drive writes one line at startup and then nothing
            // at all, so every window after that one looks like an absence.
            // Asking it is cheaper than guessing, and it was guessing wrong.
            print(noRecords(since: since, socket: socket))
            exit(1)
        }

        let analysis = SoakAnalysis.analyse(records)
        print(render(analysis, since: since))
        exit(analysis.isHealthy ? 0 : 1)
    }

    private static func fetch(since: String) throws -> [DaemonLogRecord] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--style", "ndjson", "--last", since,
            "--predicate", #"subsystem == "com.dranik.battery""#,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"

        var records: [DaemonLogRecord] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let entry = object as? [String: Any],
                  let message = entry["eventMessage"] as? String
            else { continue }

            // Only the daemon's own records. The CLI and the test suite log to
            // the same subsystem and would otherwise be counted as restarts.
            let image = entry["processImagePath"] as? String ?? ""
            guard image.hasSuffix("dranikd") else { continue }

            let stamp = entry["timestamp"] as? String ?? ""
            records.append(DaemonLogRecord(
                timestamp: formatter.date(from: stamp) ?? Date.distantPast,
                category: entry["category"] as? String ?? "",
                message: message
            ))
        }
        return records
    }

    private static func noRecords(since: String, socket: String) -> String {
        var lines = ["No daemon records in the last \(since).", ""]

        guard let report = (try? ControlClient.send(ControlRequest(command: .status), to: socket))?
            .report else {
            lines.append("No daemon answered either, so either it has not been running")
            lines.append("or the log has rolled over.")
            return lines.joined(separator: "\n")
        }

        if report.heldBy == DaemonReport.HeldBy.firmware {
            lines.append("A daemon IS running, and the firmware is holding the limit for")
            lines.append("it. That path has no gate to move and nothing to verify on a")
            lines.append("timer, so an empty window is the normal state rather than a")
            lines.append("finding. What the corridor reads now is in `dranik status`.")
        } else if report.limitingIsSupported {
            lines.append("A daemon IS running and can limit charging — this window just")
            lines.append("contains none of its records. Try a longer one.")
        } else {
            lines.append("A daemon IS running, but it reports no charge gate on this")
            lines.append("machine. Nothing is being limited, and a daemon with nothing")
            lines.append("to do has nothing to write down — which is why this window is")
            lines.append("empty. The silence is the finding.")
        }
        return lines.joined(separator: "\n")
    }

    /// The window actually covered, against the one asked for.
    ///
    /// `--since 7d` quietly reporting a day and a half reads as a verdict about
    /// the week. The system log keeps far less than people assume.
    private static func requestedSeconds(_ since: String) -> TimeInterval? {
        guard let unit = since.last, let value = Double(since.dropLast()) else { return nil }
        switch unit {
        case "m": return value * 60
        case "h": return value * 3600
        case "d": return value * 86400
        default: return nil
        }
    }

    private static func render(_ analysis: SoakAnalysis, since: String) -> String {
        var lines = ["Daemon behaviour over the last \(since)", ""]

        var coverageNote: String?
        if let duration = analysis.duration, duration > 0 {
            lines.append(row("Records span", format(duration)))
            if let asked = requestedSeconds(since), duration < asked * 0.8 {
                coverageNote = analysis.firmwareLimiting
                    // On this path the daemon writes almost nothing, so a short
                    // span is its own silence rather than a rolled-over log.
                    // Blaming the log here would send someone looking for a
                    // problem that is not there.
                    ? "Records only span \(format(duration)) — but on this path the daemon"
                        + " has little to write down, so that is expected."
                    : "Records only go back \(format(duration)) of the \(since) asked for"
                        + " — the system log keeps less than that."
            }
        }
        lines.append(row("Daemon starts", "\(analysis.restarts)"))
        if analysis.firmwareLimiting {
            // None of the gate figures exist on this path, and printing them as
            // zeroes would read as a daemon that did nothing.
            lines.append(row("Limit held by", "the firmware"))
            lines.append(row("Corridor rewritten", "\(analysis.corridorRepairs) time(s)"))
            lines.append(row("Corridor refused", "\(analysis.corridorRefusals) time(s)"))
            lines.append(row("Corridor unreadable", "\(analysis.corridorUnreadable) time(s)"))
        } else {
            lines.append(row("Gate closed", "\(analysis.gateClosures) time(s)"))
            lines.append(row("Gate opened", "\(analysis.gateOpens) time(s)"))
            lines.append(row("Slept / woke", "\(analysis.sleeps) / \(analysis.wakes)"))
            if analysis.unannouncedSleeps > 0 {
                lines.append(
                    row("Sleeps not announced", "\(analysis.unannouncedSleeps) (caught anyway)")
                )
            }
            lines.append(row("Watchdog firings", "\(analysis.watchdogStalls)"))
            lines.append(row(
                "Gate checks",
                "\(analysis.verificationsConfirmed) passed, \(analysis.verificationFailures) failed"
            ))
        }

        if let coverageNote {
            lines.append("")
            lines.append("  " + wrap(coverageNote, indent: 2))
        }

        lines.append("")
        if analysis.concerns.isEmpty && analysis.firmwareLimiting {
            // Says what it checked rather than just "fine". On this path the
            // daemon is quiet by design, so an empty window is not evidence —
            // the evidence is the corridor still reading what was asked, and
            // that is a question about now, not about the window.
            lines.append("  Nothing to report. The corridor stayed as set for the whole")
            lines.append("  window, and the firmware held it — including while asleep,")
            lines.append("  when nothing of ours was running.")
            lines.append("")
            lines.append("  Note that this path is quiet by design: there is no gate to")
            lines.append("  move and nothing to verify on a timer. What the corridor reads")
            lines.append("  right now is in `dranik status`.")
        } else if analysis.concerns.isEmpty {
            lines.append("  Nothing to report. The gate moved when it should and nothing")
            lines.append("  intervened to force it open.")
        } else {
            for concern in analysis.concerns {
                let mark = concern.severity == .serious ? "!!" : " •"
                lines.append("  \(mark) \(wrap(concern.text))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    }

    /// Wraps at 68 columns, continuing at `indent` spaces.
    ///
    /// Five by default, which is where a concern's text starts after its "  !! "
    /// marker. A line with no marker needs two, or the continuation hangs.
    private static func wrap(_ text: String, indent: Int = 5) -> String {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.count + word.count + 1 > 68 {
                lines.append(current)
                current = String(word)
            } else {
                current += current.isEmpty ? String(word) : " \(word)"
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n" + String(repeating: " ", count: indent))
    }

    private static func row(_ label: String, _ value: String) -> String {
        "  " + label.padding(toLength: 22, withPad: " ", startingAt: 0) + value
    }
}
