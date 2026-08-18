import DranikPower
import DranikSMC
import Foundation

// Answers the one question the rest of the project is blocked on: does writing
// the off-payload to the charge-gate key actually stop this machine charging?
//
// Battery-Toolkit and batt independently write 01 00 00 00 to CHTE, and the key's
// metadata here matches Battery-Toolkit's expectation byte for byte — but two
// projects agreeing is not the same as verified. See docs/04-safety.md.
//
// Deliberately a separate executable rather than a `dranik` subcommand: this is
// the only thing in the repository that writes to the SMC, and it should have to
// be invoked by name.

let usage = """
dranik-gate-experiment — verify the charge gate, once, with a guaranteed rollback

USAGE
  sudo dranik-gate-experiment [--yes]
  dranik-gate-experiment --dry-run

WHAT IT DOES
  1. Checks preconditions: on AC, actively charging, gate key recognised.
  2. Arms the rollback — signal handlers and a \(Experiment.defaultRestoreAfterSeconds)s deadline.
  3. Closes the charge gate.
  4. Watches charging state for \(Experiment.defaultObserveSeconds)s.
  5. Reopens the gate, whatever happened, and confirms charging resumes.

  Charging stops for about \(Experiment.defaultRestoreAfterSeconds) seconds. Nothing else changes.
  The rollback is armed before the first write, so interrupting it with Ctrl-C
  reopens the gate rather than leaving it shut.

OPTIONS
  --dry-run          Exercise every step except the writes. Needs no privileges.
  --yes              Skip the confirmation prompt.
  --observe <s>      Observation window (default \(Experiment.defaultObserveSeconds)).
  --deadline <s>     Unconditional restore (default \(Experiment.defaultRestoreAfterSeconds)).
                     Both are clamped to \(Experiment.maxSeconds)s: the deadline is the last
                     thing between a bug and a machine that will not charge,
                     so no argument can push it further out.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dranik-gate-experiment: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}

let dryRun = arguments.contains("--dry-run")
let assumeYes = arguments.contains("--yes")

func intOption(_ name: String, default fallback: Int) -> Int {
    guard let index = arguments.firstIndex(of: name) else { return fallback }
    guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
        fail("\(name) needs a number of seconds")
    }
    return value
}

let observeSeconds = intOption("--observe", default: Experiment.defaultObserveSeconds)
let deadlineSeconds = intOption("--deadline", default: Experiment.defaultRestoreAfterSeconds)

// MARK: - Preconditions

if !dryRun && geteuid() != 0 {
    fail("writing to the SMC requires root. Re-run with sudo, or use --dry-run.")
}

let smc: SMCConnection
do {
    smc = try SMCConnection()
} catch {
    fail("cannot open AppleSMC: \(error)")
}

let capabilities: Capabilities
do {
    capabilities = try Capabilities.detect(using: smc)
} catch {
    fail("cannot probe SMC capabilities: \(error)")
}

let specs = capabilities.chargeGate.specs
if specs.isEmpty {
    fail("""
    no charge-gate key on this machine matched its expected description. \
    Nothing to test, and nothing safe to write.
    """)
}

let battery: BatterySnapshot
do {
    battery = try PowerReader.snapshot()
} catch {
    fail("cannot read the battery: \(error)")
}

// These two are requirements of the *observation*, not of safety: if the battery
// is not charging there is nothing to watch stop. A dry run writes nothing, so
// they do not apply to it — which is also what makes the rollback machinery
// testable on a machine that happens to be unplugged.
if !dryRun {
    guard battery.isExternalConnected else {
        fail("not on AC power. The experiment needs the charger connected.")
    }
    guard battery.isCharging else {
        fail("""
        the battery is not charging right now (\(battery.percentage) %), so there \
        would be nothing to observe stopping. Let it drop below the charge \
        threshold, then try again.
        """)
    }
} else if !battery.isCharging {
    print("note: battery is not charging — a real run would refuse. Proceeding, "
        + "since a dry run writes nothing.\n")
}

// MARK: - Plan

print("""
dranik-gate-experiment\(dryRun ? " (DRY RUN — nothing will be written)" : "")

  machine     charge gate \(capabilities.chargeGate.keys.map(\.description).joined(separator: " + "))
  battery     \(battery.percentage) %, \
\(battery.isCharging ? "charging" : battery.isExternalConnected ? "on AC, not charging" : "on battery"), \
\(battery.amperage) mA
  will write  \(specs.map { "\($0.key)=\($0.offBytes.hexString)" }.joined(separator: " "))
  then        restore after at most \(min(deadlineSeconds, Experiment.maxSeconds))s, whatever happens

""")

if !dryRun && !assumeYes {
    print("Charging will stop for up to \(min(deadlineSeconds, Experiment.maxSeconds)) seconds. Continue? [y/N] ", terminator: "")
    fflush(stdout)
    let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    guard answer == "y" || answer == "yes" else {
        print("aborted — nothing written")
        exit(0)
    }
}

Experiment(
    smc: smc,
    specs: specs,
    dryRun: dryRun,
    observeSeconds: observeSeconds,
    restoreAfterSeconds: deadlineSeconds
).run()
