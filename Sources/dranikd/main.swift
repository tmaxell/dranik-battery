import DranikCore
import DranikDaemon
import DranikPower
import DranikSMC
import Foundation
import os

let usage = """
dranikd — holds the battery charge below a limit

USAGE
  sudo dranikd [--config <path>] [--dry-run]

  Normally started by launchd, not by hand. Reads its limit from
  \(ConfigStore.defaultPath) and moves the SMC charge gate to keep the
  battery inside it.

OPTIONS
  --config <path>   Configuration file (default: \(ConfigStore.defaultPath))
  --state <path>    Where to record what it is doing (default: \(StateStore.defaultPath))
  --lock <path>     Single-instance lock (default: \(InstanceLock.defaultPath))
  --socket <path>   Control socket (default: \(ControlProtocol.defaultSocketPath))
  --dry-run         Decide and log, but never write to the SMC. Needs no root.
  --clear-firmware-limit
                    Take the firmware charge corridor off the hardware and exit.
                    What `make uninstall` calls: the corridor is deliberately
                    left in place when the daemon stops, so removing the daemon
                    has to clear it explicitly. Exits non-zero if it could not.

SAFETY
  Which of these applies depends on what the hardware offers, and `dranik daemon`
  says which one is in force.

  Software charge gate — the limit is held by this process:
    the gate opens on SIGTERM, on any unreadable battery reading, below 20 %,
    and if a watchdog finds the controller stuck. It also opens by itself on
    reboot: the SMC returns to its defaults, measured on this hardware. So the
    worst case for any bug is bounded by one restart.

  Firmware corridor — the limit is held by the firmware:
    it is deliberately left in place when this process exits, because it is the
    limit working and clearing it would make charge limiting lapse on every
    restart. `make uninstall` clears it, and so does a reboot — measured, so the
    worst case is still bounded by one restart. The firmware charges on its own
    below the corridor's lower bound, so a corridor left behind cannot flatten
    the battery — but it can keep it near the lower bound until something clears
    it.
"""

let log = Logger(subsystem: "com.dranik.battery", category: "Startup")

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("dranikd: \(message)\n".utf8))
    log.fault("\(message, privacy: .public)")
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}

func option(_ name: String, default fallback: String) -> String {
    guard let index = arguments.firstIndex(of: name) else { return fallback }
    guard index + 1 < arguments.count else { fail("\(name) needs a path") }
    return arguments[index + 1]
}

let dryRun = arguments.contains("--dry-run")
let configPath = option("--config", default: ConfigStore.defaultPath)
let statePath = option("--state", default: StateStore.defaultPath)
let lockPath = option("--lock", default: InstanceLock.defaultPath)
let socketPath = option("--socket", default: ControlProtocol.defaultSocketPath)

let clearFirmwareLimit = arguments.contains("--clear-firmware-limit")

if !dryRun && geteuid() != 0 {
    fail("writing the charge gate needs root. Use --dry-run to watch it decide instead.")
}

// Handled before the instance lock on purpose. This is maintenance, not a second
// daemon, and being turned away by a lock would leave the corridor on the machine
// with the caller about to delete everything that could take it off.
if clearFirmwareLimit {
    let smc: SMCConnection
    do {
        smc = try SMCConnection()
    } catch {
        fail("cannot open AppleSMC: \(error)", code: EX_OSERR)
    }
    defer { smc.close() }

    let capabilities: Capabilities
    do {
        capabilities = try Capabilities.detect(using: smc)
    } catch {
        fail("cannot probe SMC capabilities: \(error)", code: EX_OSERR)
    }

    let outcome = FirmwareLimitMaintenance.clear(
        smc: smc, capabilities: capabilities, dryRun: dryRun
    )
    print(outcome.description)
    guard outcome.isSafeToProceed else {
        log.fault("\(outcome.description, privacy: .public)")
        exit(EX_UNAVAILABLE)
    }
    log.notice("\(outcome.description, privacy: .public)")
    exit(0)
}

// Before anything else. Two daemons would fight over the gate, and the loser of
// each round could be the one that wanted it open.
let lock: InstanceLock
do {
    lock = try InstanceLock(path: lockPath)
} catch {
    fail("\(error)", code: EX_TEMPFAIL)
}

let loaded = ConfigStore.load(from: configPath)
for problem in loaded.problems {
    log.notice("config: \(problem, privacy: .public)")
    if dryRun { print("config: \(problem)") }
}

let smc: SMCConnection
do {
    smc = try SMCConnection()
} catch {
    fail("cannot open AppleSMC: \(error)", code: EX_OSERR)
}

let capabilities: Capabilities
do {
    capabilities = try Capabilities.detect(using: smc)
} catch {
    fail("cannot probe SMC capabilities: \(error)", code: EX_OSERR)
}

withExtendedLifetime(lock) {
    Daemon(
        smc: smc,
        capabilities: capabilities,
        config: loaded.config,
        dryRun: dryRun,
        statePath: statePath,
        configPath: configPath,
        socketPath: socketPath
    ).run()
}
