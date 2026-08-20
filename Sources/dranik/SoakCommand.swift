import DranikCore
import Foundation

/// `dranik soak` — did the daemon behave over the last stretch of time?
///
/// `dranik daemon` answers "is it right now". Neither that nor any single log
/// line would have shown the watchdog forcing the gate open after every sleep;
/// that took reading three days of records together. This is that reading, as a
/// command.
enum SoakCommand {
    static func run(since: String) -> Never {
        let records: [DaemonLogRecord]
        do {
            records = try fetch(since: since)
        } catch {
            fail("\(error)")
        }

        guard !records.isEmpty else {
            print("""
            No daemon records in the last \(since).

            Either it has not been running, or the log has rolled over. `dranik daemon`
            says whether one is running now.
            """)
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

    private static func render(_ analysis: SoakAnalysis, since: String) -> String {
        var lines = ["Daemon behaviour over the last \(since)", ""]

        if let duration = analysis.duration, duration > 0 {
            lines.append(row("Records span", format(duration)))
        }
        lines.append(row("Daemon starts", "\(analysis.restarts)"))
        lines.append(row("Gate closed", "\(analysis.gateClosures) time(s)"))
        lines.append(row("Gate opened", "\(analysis.gateOpens) time(s)"))
        lines.append(row("Slept / woke", "\(analysis.sleeps) / \(analysis.wakes)"))
        if analysis.unannouncedSleeps > 0 {
            lines.append(row("Sleeps not announced", "\(analysis.unannouncedSleeps) (caught anyway)"))
        }
        lines.append(row("Watchdog firings", "\(analysis.watchdogStalls)"))
        lines.append(row(
            "Gate checks",
            "\(analysis.verificationsConfirmed) passed, \(analysis.verificationFailures) failed"
        ))

        lines.append("")
        if analysis.concerns.isEmpty {
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

    private static func wrap(_ text: String) -> String {
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
        return lines.joined(separator: "\n     ")
    }

    private static func row(_ label: String, _ value: String) -> String {
        "  " + label.padding(toLength: 22, withPad: " ", startingAt: 0) + value
    }
}
