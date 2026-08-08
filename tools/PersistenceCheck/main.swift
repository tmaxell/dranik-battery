import DranikPower
import DranikSMC
import Foundation

// Answers the two questions left open after the charge gate itself was
// confirmed: does a closed gate survive sleep, and does it survive a reboot?
//
// Both matter for the daemon that comes next. Sleep decides whether closing the
// gate before sleeping actually holds the limit overnight. Reboot decides how
// bad the worst case is — whether "reboot" is a complete recovery from a stuck
// gate or no recovery at all.

let usage = """
dranik-persistence — does a closed charge gate survive sleep, or a reboot?

USAGE
  sudo dranik-persistence sleep [--sleep-now]
  sudo dranik-persistence reboot-arm
  sudo dranik-persistence reboot-result
  sudo dranik-persistence abort
  dranik-persistence status
  dranik-persistence plist

SLEEP TEST — safe, no reboot
  Closes the gate, waits for the machine to sleep and wake, reads the gate on
  the first tick after waking, then reopens it. The gate is also reopened on any
  signal, or after \(Int(SleepTest.awakeBudget))s of awake time if the machine never sleeps.
  --sleep-now puts the machine to sleep for you.

REBOOT TEST — leaves the gate closed on purpose
  `reboot-arm` closes the gate and leaves it closed, which is exactly the state
  everything else in this project exists to prevent. So it first installs a
  one-shot LaunchDaemon that runs at the next boot, records what it finds and
  reopens the gate — automatically, before you could notice a machine that will
  not charge. If that daemon cannot be installed, the gate is not closed at all.

  Then reboot, and read the answer with `reboot-result`.
  `abort` cancels an armed test and reopens the gate.

  Recovery, in order of severity, if anything goes wrong:
    sudo dranik-persistence abort
    sudo reboot
"""

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "status"

if command == "help" || command == "--help" || command == "-h" {
    print(usage)
    exit(0)
}

let writingCommands = ["sleep", "reboot-arm", "reboot-check", "reboot-result", "abort"]
let readingCommands = ["status", "plist"]
guard writingCommands.contains(command) || readingCommands.contains(command) else {
    fail("unknown command '\(command)'. Try `dranik-persistence help`.")
}

// Prints the launchd job `reboot-arm` would install, so it can be read — and
// checked with plutil — before agreeing to any of this.
if command == "plist" {
    let data = try! PropertyListSerialization.data(
        fromPropertyList: RebootTest.bootDaemonPlist(), format: .xml, options: 0
    )
    print("// would be written to \(RebootTest.plistPath)")
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

// Status is the one thing worth being able to see without privileges.
if command == "status" {
    let gate = Gate()
    print("gate:   \(gate.describe())")
    if let record = PersistenceRecord.load() {
        let armed = ISO8601DateFormatter().string(from: record.armedAt)
        if let observation = record.observation {
            print("reboot test: complete — survived=\(observation.survived), armed \(armed)")
        } else {
            print("reboot test: ARMED at \(armed), not yet rebooted")
        }
    } else {
        print("reboot test: none armed")
    }
    let installed = FileManager.default.fileExists(atPath: RebootTest.plistPath)
    print("boot daemon: \(installed ? "installed" : "not installed")")
    if FileManager.default.fileExists(atPath: RebootTest.installedBinary) {
        print("leftover:    \(RebootTest.installedBinary) — remove with `abort`")
    }
    if let snapshot = try? PowerReader.snapshot() {
        print("battery: \(snapshot.percentage) %, charging=\(snapshot.isCharging), "
            + "reason=\(snapshot.notChargingReason.map(String.init(describing:)) ?? "-")")
    }
    exit(0)
}

guard geteuid() == 0 else {
    fail("`\(command)` writes to the SMC and needs root. Re-run with sudo, "
        + "or use `dranik-persistence status`.")
}

let gate = Gate()

switch command {
case "sleep":
    guard let snapshot = try? PowerReader.snapshot(), snapshot.isExternalConnected else {
        fail("""
        not on AC power. Run this plugged in — on battery the gate is closed \
        anyway and the result would say nothing.
        """)
    }
    SleepTest.run(gate: gate, sleepNow: arguments.contains("--sleep-now"))

case "reboot-arm":
    RebootTest.arm(gate: gate)

case "reboot-check":
    RebootTest.check(gate: gate)

case "reboot-result":
    RebootTest.result(gate: gate)

case "abort":
    RebootTest.abort(gate: gate)

default:
    fail("unreachable: '\(command)' passed validation but has no handler")
}
