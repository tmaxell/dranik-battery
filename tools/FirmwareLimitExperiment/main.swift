import DranikPower
import DranikSMC
import Foundation

// Answers whether this machine's firmware charge limit can be driven at all.
//
// Background: firmware mBoot-20457.1.29 removed `CHTE` and brought the
// `bfF0`/`bfD0`/`bfE0` family in its place. On macOS 27 the `AppleSMC` user
// client filters those keys — every operation returns kIOReturnNotPrivileged
// even as root. Here they read fine, which suggests the filter lives in that
// kext rather than in the firmware. One write settles it.
//
// Semantics come from `charlie0129/batt`, `pkg/smc/charging.go`: `bfF0` is the
// activation byte (0x02 on, 0x00 off), `bfD0` the upper bound and `bfE0` the
// lower, both ui32 percentages, written deactivate -> upper -> lower -> activate.
// Two independent sources agreeing is still not verification, which is the whole
// reason this tool exists.
//
// Deliberately a separate executable rather than a `dranik` subcommand, and the
// key descriptors live here rather than in `DranikSMC`: until the change is
// approved, nothing in the product itself is able to write these keys.

// MARK: - What it writes

/// The firmware charge-limit keys, with the metadata each must still report.
///
/// The metadata is part of the identity check. The project has already been
/// caught out once by firmware moving charge control, so a key whose size, type
/// or attributes have drifted is treated as a different key.
enum FirmwareLimitKeys {
    static let activation = (
        key: SMCKey("bfF0")!,
        info: SMCKeyInfo(size: 1, type: "ui8", attributes: 0xD4)
    )
    static let upper = (
        key: SMCKey("bfD0")!,
        info: SMCKeyInfo(size: 4, type: "ui32", attributes: 0xD4)
    )
    static let lower = (
        key: SMCKey("bfE0")!,
        info: SMCKeyInfo(size: 4, type: "ui32", attributes: 0xD4)
    )

    static let activeByte: UInt8 = 0x02
    static let inactiveByte: UInt8 = 0x00

    /// Little-endian, which is what raw SMC bytes are on Apple Silicon — fact 4
    /// of the project. `batt` reverses its bytes only because its codec is
    /// big-endian; ours is not, so there is nothing to reverse.
    static func percentBytes(_ value: Int) -> [UInt8] {
        let v = UInt32(value)
        return [
            UInt8(v & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 24) & 0xFF),
        ]
    }
}

let usage = """
dranik-firmware-limit-experiment — drive the firmware charge limit, once, with a
guaranteed rollback

USAGE
  sudo dranik-firmware-limit-experiment [--upper 80] [--lower 75] [--yes]
  dranik-firmware-limit-experiment --dry-run

WHAT IT DOES
  1. Checks that all three keys exist and still report the expected metadata.
  2. Records their current values — that is the rollback target, not a guess.
  3. Arms the rollback: signal handlers and a deadline, before the first write.
  4. Writes deactivate -> upper -> lower -> activate.
  5. Reads all three back immediately and again after settling, so firmware
     quietly correcting the bounds cannot pass for success.
  6. Restores the recorded values, whatever happened.

  A firmware limit cannot discharge the battery — below the lower bound the
  firmware charges on its own — so what this guards against is a limit left
  behind, not a machine that will not charge.

OPTIONS
  --dry-run      Exercise every step except the writes. Needs no privileges.
  --yes          Skip the confirmation prompt.
  --upper <pct>  Upper bound to write (default 80).
  --lower <pct>  Lower bound to write (default 75).
  --settle <s>   Seconds before the second read-back (default 10, max 60).
  --leave-on     Do NOT restore on success: leave the limit active. This is the
                 point of the exercise rather than a debugging aid, but it
                 writes state that outlives the process, so it has to be asked
                 for. A failure part-way through still rolls back.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dranik-firmware-limit-experiment: \(message)\n".utf8))
    exit(1)
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func describe(_ info: SMCKeyInfo) -> String {
    "\(info.size)/\(info.type)/\(String(format: "0x%02X", info.attributes))"
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}

let dryRun = arguments.contains("--dry-run")
let assumeYes = arguments.contains("--yes")
let leaveOn = arguments.contains("--leave-on")

func intOption(_ name: String, default fallback: Int) -> Int {
    guard let index = arguments.firstIndex(of: name) else { return fallback }
    guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
        fail("\(name) needs a number")
    }
    return value
}

let upper = intOption("--upper", default: 80)
let lower = intOption("--lower", default: 75)
let settleSeconds = min(max(1, intOption("--settle", default: 10)), 60)

// The firmware's own bounds, from batt: 0 <= lower < upper <= 100. Checked here
// too, because an inverted pair is the one argument mistake that would ask the
// firmware for something meaningless.
guard lower >= 0, upper <= 100, lower < upper else {
    fail("bounds must satisfy 0 <= lower < upper <= 100, got lower=\(lower) upper=\(upper)")
}
// Principle II: the unconditional emergency floor is 20 %. A lower bound under
// it would hand the firmware a corridor the daemon would then have to fight.
guard lower >= 20 else {
    fail("lower bound \(lower) is below the 20 % emergency floor")
}

if !dryRun && geteuid() != 0 {
    fail("writing to the SMC requires root. Re-run with sudo, or use --dry-run.")
}

let smc: SMCConnection
do {
    smc = try SMCConnection()
} catch {
    fail("cannot open AppleSMC: \(error)")
}

// MARK: - Preconditions

print("dranik firmware charge-limit experiment")
print("")

func checkKey(_ named: String, _ pair: (key: SMCKey, info: SMCKeyInfo)) -> SMCReading {
    let live: SMCKeyInfo?
    do {
        live = try smc.keyInfo(pair.key)
    } catch {
        fail("""
        \(pair.key) KeyInfo failed: \(error). On macOS 27 this is exactly how the \
        gated keys present themselves, and there is nothing this tool can do about it.
        """)
    }
    guard let live else {
        fail("\(pair.key) is absent on this machine — the firmware limit is not available")
    }
    guard live == pair.info else {
        fail("""
        \(pair.key) metadata changed: expected \(describe(pair.info)), found \(describe(live)). \
        Refusing to write a key whose meaning may have moved with it.
        """)
    }
    guard live.isWritable else {
        fail("\(pair.key) is not writable")
    }
    guard let reading = try? smc.read(pair.key) else {
        fail("\(pair.key) could not be read")
    }
    let label = named.padding(toLength: 10, withPad: " ", startingAt: 0)
    print("  \(pair.key)  \(label) \(describe(live))  = \(hex(reading.bytes))")
    return reading
}

print("Keys")
let baselineActivation = checkKey("activation", FirmwareLimitKeys.activation)
let baselineUpper = checkKey("upper", FirmwareLimitKeys.upper)
let baselineLower = checkKey("lower", FirmwareLimitKeys.lower)
print("")

if let snapshot = try? PowerReader.snapshot() {
    print("Battery")
    print("""
      charge \(snapshot.percentage) %, charging=\(snapshot.isCharging), \
    external=\(snapshot.isExternalConnected), \(snapshot.amperage) mA
    """)
    if snapshot.percentage > upper {
        print("""
      NOTE: the charge is already above the upper bound being written, so
            "charging stops at the limit" is not observable in this run. What
            this run answers is whether the write lands and sticks.
    """)
    }
    print("")
}

let baselineTriple =
    "\(hex(baselineActivation.bytes))/\(hex(baselineUpper.bytes))/\(hex(baselineLower.bytes))"

if !dryRun && !assumeYes {
    print("This writes to the SMC:")
    print("  \(FirmwareLimitKeys.activation.key) = 00         deactivate")
    print("  \(FirmwareLimitKeys.upper.key) = \(hex(FirmwareLimitKeys.percentBytes(upper)))   upper \(upper) %")
    print("  \(FirmwareLimitKeys.lower.key) = \(hex(FirmwareLimitKeys.percentBytes(lower)))   lower \(lower) %")
    print("  \(FirmwareLimitKeys.activation.key) = 02         activate")
    print(leaveOn
        ? "and then LEAVES THE LIMIT ACTIVE (--leave-on)."
        : "and then restores \(baselineTriple).")
    print("")
    print("Type yes to continue: ", terminator: "")
    guard let answer = readLine()?.trimmingCharacters(in: .whitespaces), answer == "yes" else {
        print("nothing written.")
        exit(0)
    }
    print("")
}

// MARK: - Rollback, armed before the first write

let queue = DispatchQueue(label: "com.dranik.battery.firmware-limit-experiment")
var restored = false
var sources: [DispatchSourceProtocol] = []

let started = Date()

func log(_ message: String) {
    let elapsed = String(format: "%5.1f", Date().timeIntervalSince(started))
    print("[\(elapsed)s] \(message)")
}

/// Puts the three keys back exactly as they were found. Idempotent, reachable
/// from any path, and deactivation goes first so the bounds are never live while
/// half-written.
func restore(reason: String, thenExit code: Int32?) {
    guard !restored else { return }
    restored = true
    log("restoring (\(reason))")

    let steps: [(SMCKey, [UInt8], SMCKeyInfo)] = [
        (
            FirmwareLimitKeys.activation.key,
            [FirmwareLimitKeys.inactiveByte],
            FirmwareLimitKeys.activation.info
        ),
        (FirmwareLimitKeys.upper.key, baselineUpper.bytes, FirmwareLimitKeys.upper.info),
        (FirmwareLimitKeys.lower.key, baselineLower.bytes, FirmwareLimitKeys.lower.info),
        (
            FirmwareLimitKeys.activation.key,
            baselineActivation.bytes,
            FirmwareLimitKeys.activation.info
        ),
    ]

    var failures: [String] = []
    for (key, bytes, info) in steps {
        if dryRun {
            log("DRY RUN — would write \(key) = \(hex(bytes))")
            continue
        }
        do {
            try smc.write(key, bytes: bytes, matching: info)
            log("restored \(key) = \(hex(bytes))")
        } catch {
            failures.append("\(key): \(error)")
        }
    }

    if failures.isEmpty {
        log("baseline restored")
    } else {
        for failure in failures { log("RESTORE FAILED — \(failure)") }
        log("""
        THE FIRMWARE LIMIT MAY STILL BE ACTIVE. Clear it by hand with
        `--upper 100 --lower 99 --yes`, or reboot and re-check with
        `dranik smc bfF0 bfD0 bfE0`.
        """)
        exit(max(code ?? 2, 2))
    }

    if let code { exit(code) }
}

for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
    // The default disposition would kill the process before a handler ran, and a
    // C signal handler may not call IOKit. A dispatch source may.
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
    source.setEventHandler { restore(reason: "signal \(signalNumber)", thenExit: 130) }
    source.resume()
    sources.append(source)
}

// The deadline exists even with --leave-on: it only fires while the run is still
// in progress, and a run that wedges part-way through must not leave bounds set.
let deadlineSeconds = settleSeconds + 30
let deadline = DispatchSource.makeTimerSource(queue: queue)
deadline.schedule(deadline: .now() + .seconds(deadlineSeconds))
deadline.setEventHandler { restore(reason: "deadline reached", thenExit: 3) }
deadline.resume()
sources.append(deadline)

log("rollback armed: signals, deadline \(deadlineSeconds)s, target \(baselineTriple)")

// MARK: - The writes

queue.async {
    func write(_ named: String, _ pair: (key: SMCKey, info: SMCKeyInfo), _ bytes: [UInt8]) throws {
        if dryRun {
            log("DRY RUN — would write \(pair.key) = \(hex(bytes))  (\(named))")
            return
        }
        try smc.write(pair.key, bytes: bytes, matching: pair.info)
        log("wrote \(pair.key) = \(hex(bytes))  (\(named))")
    }

    do {
        try write("deactivate", FirmwareLimitKeys.activation, [FirmwareLimitKeys.inactiveByte])
        try write("upper \(upper) %", FirmwareLimitKeys.upper, FirmwareLimitKeys.percentBytes(upper))
        try write("lower \(lower) %", FirmwareLimitKeys.lower, FirmwareLimitKeys.percentBytes(lower))
        try write("activate", FirmwareLimitKeys.activation, [FirmwareLimitKeys.activeByte])
    } catch {
        log("WRITE FAILED: \(error)")
        let text = "\(error)"
        if text.contains("e00002c1") || text.lowercased().contains("notprivileged") {
            log("""
            That is kIOReturnNotPrivileged — the same filter macOS 27 applies. \
            The firmware route is closed here too, and the adapter route (CHIE) \
            is the only one left.
            """)
        }
        restore(reason: "write failed", thenExit: 1)
        return
    }

    // Read back twice. `SMCConnection.write` already confirms the key holds the
    // value immediately; what that cannot see is the firmware accepting a write
    // and then quietly correcting the bounds, which is open question 6.
    func readBack(_ label: String) -> (activation: UInt8, upper: UInt32, lower: UInt32)? {
        guard !dryRun else {
            log("DRY RUN — would read all three back (\(label))")
            return nil
        }
        guard let a = try? smc.read(FirmwareLimitKeys.activation.key),
              let u = try? smc.read(FirmwareLimitKeys.upper.key),
              let l = try? smc.read(FirmwareLimitKeys.lower.key),
              let activation = a.bytes.first
        else {
            log("read-back failed (\(label))")
            return nil
        }
        func u32(_ bytes: [UInt8]) -> UInt32 {
            var value: UInt32 = 0
            for (index, byte) in bytes.prefix(4).enumerated() {
                value |= UInt32(byte) << (8 * index)
            }
            return value
        }
        let triple = (activation: activation, upper: u32(u.bytes), lower: u32(l.bytes))
        log("\(label): bfF0=\(hex(a.bytes)) bfD0=\(triple.upper) % bfE0=\(triple.lower) %")
        return triple
    }

    let immediate = readBack("immediately")
    log("settling for \(settleSeconds)s")
    Thread.sleep(forTimeInterval: Double(settleSeconds))
    let settled = readBack("after \(settleSeconds)s")

    if let snapshot = try? PowerReader.snapshot() {
        let reason = snapshot.notChargingReason.map(String.init(describing:)) ?? "-"
        log("""
        battery \(snapshot.percentage) %, charging=\(snapshot.isCharging), \
        \(snapshot.amperage) mA, notChargingReason=\(reason)
        """)
    }

    print("")
    print("VERDICT")
    if dryRun {
        print("  Dry run — nothing was written, so nothing is claimed.")
    } else if let settled {
        if settled == (FirmwareLimitKeys.activeByte, UInt32(upper), UInt32(lower)) {
            print("  OK — the firmware took the limit and is still holding it: "
                + "active, \(lower)–\(upper) %.")
            print("  Writes to this family are NOT privileged on this machine.")
        } else {
            print("  The write landed, but the firmware did not keep it as asked.")
            print("  wanted active/\(upper)/\(lower), reads "
                + "\(String(format: "0x%02X", settled.activation))/\(settled.upper)/\(settled.lower)")
            if let immediate, immediate != settled {
                print("  It changed between the two reads — the firmware is correcting it.")
            }
        }
    }
    print("")

    if leaveOn && !dryRun && settled?.activation == FirmwareLimitKeys.activeByte {
        restored = true  // disarm: leaving it on is the whole point of this run
        print("Limit left ACTIVE at \(lower)–\(upper) %.")
        print("Clear it with:  sudo dranik-firmware-limit-experiment --upper 100 --lower 99 --yes")
        print("Check it with:  dranik smc bfF0 bfD0 bfE0")
        exit(0)
    }

    restore(reason: "run complete", thenExit: 0)
}

dispatchMain()
