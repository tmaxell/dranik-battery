import DranikCore
import DranikDaemon
import Foundation

// Drives the menu bar app against a daemon that misbehaves on purpose.
//
// The states worth being certain about are the ones where the app must say "the
// limit is not being enforced". A healthy daemon will not produce any of them on
// request, and waiting for one to happen naturally is how they end up untested —
// so this serves them from a real `ControlServer` over a real socket and reads
// back what the app made of it.
//
// Only the states that rank *above* the battery are drilled here. The rest —
// holding, charging, on battery, too hot — depend on the machine's actual charge
// and temperature, which this cannot set, and they are already covered branch by
// branch in `MenuBarPresentationTests`. What this adds is the wiring those tests
// cannot reach: socket, decode, presentation, output.

struct Scenario {
    let name: String
    /// `nil` publishes nothing, which is a daemon that has not decided yet.
    let report: DaemonReport?
    /// `false` runs the app against a path with no socket on it at all.
    let serve: Bool
    /// Applied after the server is listening, to take the socket away again.
    let permissions: mode_t?
    let expectedHeadline: String
    let expectedIcon: String
    let expectedControls: String

    init(
        _ name: String,
        report: DaemonReport? = nil,
        serve: Bool = true,
        permissions: mode_t? = nil,
        headline: String,
        icon: String,
        controls: String = "enabled"
    ) {
        self.name = name
        self.report = report
        self.serve = serve
        self.permissions = permissions
        self.expectedHeadline = headline
        self.expectedIcon = icon
        self.expectedControls = controls
    }
}

func report(
    gate: String = "closed",
    reasonCode: String = "reachedUpper",
    trusted: Bool = true,
    supported: Bool = true
) -> DaemonReport {
    DaemonReport(
        upperLimit: 80, lowerLimit: 75, thermalCutoff: 40, sleepPolicy: "holdLimit",
        gate: gate, reason: "drill", gateIsTrusted: trusted, reasonCode: reasonCode,
        limitingIsSupported: supported, decidedAt: Date()
    )
}

let scenarios = [
    Scenario(
        "no daemon at all",
        serve: false,
        headline: "Daemon not running", icon: "warning", controls: "disabled"
    ),
    Scenario(
        "a daemon that has not decided yet",
        report: nil,
        headline: "Daemon not responding", icon: "warning", controls: "disabled"
    ),
    Scenario(
        "a gate the daemon no longer trusts",
        report: report(trusted: false),
        headline: "Not limiting", icon: "warning"
    ),
    Scenario(
        "hardware with no charge gate",
        report: report(gate: "open", supported: false),
        headline: "This Mac has no charge gate", icon: "warning", controls: "disabled"
    ),
    Scenario(
        "a socket this user is not allowed to open",
        report: report(),
        permissions: 0o000,
        headline: "Daemon not responding", icon: "warning", controls: "disabled"
    ),
    Scenario(
        "a reading too old to act on",
        report: report(gate: "open", reasonCode: "staleReading"),
        headline: "Not limiting", icon: "warning"
    ),
]

/// The app sits next to this binary in the build directory.
let appPath = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .appendingPathComponent("DranikApp")

guard FileManager.default.isExecutableFile(atPath: appPath.path) else {
    FileHandle.standardError.write(Data("no DranikApp next to the drill at \(appPath.path)\n".utf8))
    exit(EX_UNAVAILABLE)
}

func run(_ socketPath: String) throws -> String {
    let process = Process()
    process.executableURL = appPath
    process.arguments = ["--check", "--socket", socketPath]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Pulls one labelled row back out of what `--check` printed.
func field(_ label: String, from output: String) -> String? {
    for line in output.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(label) else { continue }
        return String(trimmed.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
    }
    return nil
}

var failures = 0

print("ui drill — \(scenarios.count) scenarios\n")

for scenario in scenarios {
    let socketPath = NSTemporaryDirectory() + "dranik-drill-\(UUID().uuidString).sock"
    var server: ControlServer?

    if scenario.serve {
        let started = ControlServer(
            path: socketPath, initialConfig: ChargeConfig(),
            applyConfig: { _ in }, reloadConfig: {}
        )
        try started.start()
        if let report = scenario.report {
            started.publish(report, config: ChargeConfig())
        }
        if let permissions = scenario.permissions {
            chmod(socketPath, permissions)
        }
        server = started
    }
    defer { server?.stop() }

    let output: String
    do {
        output = try run(socketPath)
    } catch {
        print("  FAIL  \(scenario.name): could not run the app — \(error)")
        failures += 1
        continue
    }

    var problems: [String] = []
    let headline = field("Headline", from: output) ?? "<missing>"
    let icon = field("Icon", from: output) ?? "<missing>"
    let controls = field("Controls", from: output) ?? "<missing>"

    if !headline.hasPrefix(scenario.expectedHeadline) {
        problems.append("headline: expected \(scenario.expectedHeadline)…, got \(headline)")
    }
    if icon != scenario.expectedIcon {
        problems.append("icon: expected \(scenario.expectedIcon), got \(icon)")
    }
    if controls != scenario.expectedControls {
        problems.append("controls: expected \(scenario.expectedControls), got \(controls)")
    }

    if problems.isEmpty {
        print("  ok    \(scenario.name) → \(headline)")
    } else {
        failures += 1
        print("  FAIL  \(scenario.name)")
        for problem in problems { print("        \(problem)") }
    }
}

print("")
if failures == 0 {
    print("all \(scenarios.count) scenarios rendered as intended")
    exit(0)
}
print("\(failures) of \(scenarios.count) scenarios rendered wrongly")
exit(1)
