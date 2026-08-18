import DranikPower
import DranikSMC
import Foundation

/// A single, time-boxed test of whether the charge gate actually works.
///
/// The whole design follows from one fact: the gate's state outlives the process
/// that set it. Nothing here may be able to leave the machine refusing to charge,
/// so the restore path is armed — by timer and by signal — *before* the first
/// write happens, not after it succeeds. "Try it and see" is not available.
final class Experiment {
    /// How long to watch before concluding anything.
    static let defaultObserveSeconds = 15
    /// When the gate is reopened, no matter what has or has not been observed.
    static let defaultRestoreAfterSeconds = 30
    /// Hard ceiling on both. The deadline is the last thing standing between a
    /// bug here and a machine that will not charge, so no argument may push it
    /// out beyond this.
    static let maxSeconds = 120

    private let smc: SMCConnection
    private let specs: [SMCKeySpec]
    private let dryRun: Bool
    private let observeSeconds: Int
    private let restoreAfterSeconds: Int
    private let queue = DispatchQueue(label: "com.dranik.battery.gate-experiment")

    private var restored = false
    private var sources: [DispatchSourceProtocol] = []
    private var observationCount = 0
    private var sawChargingStop = false
    private var sawInhibitReason = false
    private var lostExternalPower = false
    private var observationTicker: DispatchSourceTimer?

    init(
        smc: SMCConnection,
        specs: [SMCKeySpec],
        dryRun: Bool,
        observeSeconds: Int = Experiment.defaultObserveSeconds,
        restoreAfterSeconds: Int = Experiment.defaultRestoreAfterSeconds
    ) {
        self.smc = smc
        self.specs = specs
        self.dryRun = dryRun
        self.observeSeconds = min(max(1, observeSeconds), Self.maxSeconds)
        self.restoreAfterSeconds = min(max(1, restoreAfterSeconds), Self.maxSeconds)
    }

    // MARK: - Running

    func run() {
        armRollback()

        queue.async { [self] in
            log("arming complete — rollback is active from this point on")
            do {
                try closeGate()
            } catch {
                log("FAILED to close the gate: \(error)")
                restore(reason: "close failed")
                return
            }
            startObserving()
        }

        dispatchMain()
    }

    /// Registers every path that reopens the gate. Called before any write.
    private func armRollback() {
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            // Ignore the default disposition so the dispatch source sees it.
            // A C signal handler cannot safely call IOKit; a dispatch source can.
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [self] in
                restore(reason: "signal \(signalNumber)")
            }
            source.resume()
            sources.append(source)
        }

        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + .seconds(restoreAfterSeconds))
        deadline.setEventHandler { [self] in
            restore(reason: "deadline reached")
        }
        deadline.resume()
        sources.append(deadline)

        log("rollback armed: signals \(SIGINT)/\(SIGTERM)/\(SIGHUP), "
            + "deadline \(restoreAfterSeconds)s")
    }

    private func startObserving() {
        let ticker = DispatchSource.makeTimerSource(queue: queue)
        ticker.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        ticker.setEventHandler { [self] in
            observationCount += 1
            report(tick: observationCount)
            if observationCount >= observeSeconds {
                restore(reason: "observation window complete")
            }
        }
        ticker.resume()
        observationTicker = ticker
        sources.append(ticker)
    }

    // MARK: - Gate

    private func closeGate() throws {
        for spec in specs {
            if dryRun {
                log("DRY RUN — would write \(spec.key) = \(hex(spec.offBytes)) (gate closed)")
            } else {
                try smc.write(spec.key, bytes: spec.offBytes, matching: spec.expectedInfo)
                log("wrote \(spec.key) = \(hex(spec.offBytes)) — gate closed")
            }
        }
    }

    /// Reopens the gate. Idempotent, and safe to reach from any path.
    private func restore(reason: String) {
        guard !restored else { return }
        restored = true

        // Stop polling first: whatever happens next, the observation window is
        // over, and lines printed after the restore only muddle the log.
        observationTicker?.cancel()
        observationTicker = nil

        log("restoring (\(reason))")

        var failures: [String] = []
        for spec in specs {
            if dryRun {
                log("DRY RUN — would write \(spec.key) = \(hex(spec.onBytes)) (gate open)")
                continue
            }
            do {
                try smc.write(spec.key, bytes: spec.onBytes, matching: spec.expectedInfo)
                log("wrote \(spec.key) = \(hex(spec.onBytes)) — gate open")
            } catch {
                failures.append("\(spec.key): \(error)")
                log("RESTORE FAILED for \(spec.key): \(error)")
            }
        }

        finish(restoreFailures: failures)
    }

    // MARK: - Observation

    private func report(tick: Int) {
        guard let snapshot = try? PowerReader.snapshot() else {
            log("t+\(tick)s  <battery unreadable>")
            return
        }

        // Evidence only counts while the charger is still attached. Unplugged,
        // the machine stops charging and reports a non-zero notChargingReason
        // for the obvious reason — observed as 128 on battery — which would
        // otherwise read as a successful gate close.
        if snapshot.isExternalConnected {
            if !snapshot.isCharging { sawChargingStop = true }
            // Only the gate's own bit counts. A plain non-zero test would also
            // fire on `onBattery`, which says nothing about the gate.
            if snapshot.notChargingReason?.contains(.inhibited) == true { sawInhibitReason = true }
            if (snapshot.chargerInhibitReason ?? 0) != 0 { sawInhibitReason = true }
        } else {
            lostExternalPower = true
        }

        let gate = specs.compactMap { spec in
            (try? smc.read(spec.key)).flatMap { $0 }.map { "\(spec.key)=\(hex($0.bytes))" }
        }.joined(separator: " ")

        let reason = snapshot.notChargingReason.map(String.init(describing:)) ?? "-"
        log("""
        t+\(tick)s  charging=\(snapshot.isCharging)  \
        notChargingReason=\(reason)  \
        inhibitReason=\(snapshot.chargerInhibitReason.map(String.init) ?? "-")  \
        \(snapshot.amperage) mA  \(gate)
        """)
    }

    // MARK: - Verdict

    private func finish(restoreFailures: [String]) {
        // The hardware does not act on a gate write immediately: closing it took
        // seven seconds to show up, and reopening it is no faster. Six seconds
        // was not enough — the first real run reported success while the battery
        // still read 0 mA, having never confirmed charging came back.
        let wait = dryRun ? 1 : Int(ChargeGateTiming.verificationWindow)
        if !dryRun {
            log("waiting \(wait)s for the charger to act on the reopened gate")
        }
        queue.asyncAfter(deadline: .now() + .seconds(wait)) { [self] in
            let after = try? PowerReader.snapshot()

            print("")
            print("─── result ───────────────────────────────────────────")

            if dryRun {
                print("DRY RUN — nothing was written. The rollback machinery ran end to end.")
                print("Restore path reached: yes")
                exitNow(0)
            }

            let gateReadings = specs.compactMap { spec -> String? in
                guard let reading = (try? smc.read(spec.key)) ?? nil else { return nil }
                let open = reading.bytes == spec.onBytes
                return "\(spec.key) = \(hex(reading.bytes)) (\(open ? "open" : "NOT OPEN"))"
            }
            for line in gateReadings {
                print("  gate now:  \(line)")
            }

            let chargingResumed = after.map { $0.isCharging || $0.amperage > 0 } ?? false
            if let after {
                print("  charging:  \(after.isCharging)")
                print("  amperage:  \(after.amperage) mA")
                print("  external:  \(after.isExternalConnected)")
                print("  reason:    \(after.notChargingReason.map(String.init(describing:)) ?? "-")")
            }

            print("")
            if !restoreFailures.isEmpty {
                print("  ⚠️  RESTORE FAILED — the gate may still be closed:")
                for failure in restoreFailures {
                    print("      \(failure)")
                }
                print("      Reboot restores the SMC to defaults on Apple Silicon.")
                exitNow(2)
            }

            if lostExternalPower {
                print("  ⚠️  INCONCLUSIVE — the charger was disconnected during the run.")
                print("     Charging stops on its own without it, so nothing observed")
                print("     after that point is evidence either way. Re-run on AC.")
            } else if sawChargingStop || sawInhibitReason {
                print("  ✅ CHTE responds. Writing the off-payload stopped charging")
                print("     (charging=false observed: \(sawChargingStop),")
                print("      hardware gave an inhibit reason: \(sawInhibitReason)).")
                print("     The charge-gate mechanism is confirmed on this machine.")
            } else {
                print("  ❌ No effect observed. Charging never stopped and the charger")
                print("     never reported an inhibit reason within \(observeSeconds)s.")
                print("     The off-payload may be wrong for this firmware.")
            }

            let allOpen = specs.allSatisfy { spec in
                guard let reading = (try? smc.read(spec.key)) ?? nil else { return false }
                return reading.bytes == spec.onBytes
            }
            print("")
            if !allOpen {
                print("  ⚠️  Gate is NOT open. Reboot to reset the SMC.")
            } else if chargingResumed {
                print("  Gate is open and charging has resumed. Nothing left behind.")
            } else {
                print("  ⚠️  Gate reads open, but charging has not resumed after \(wait)s.")
                print("     Check `dranik status`; if it does not recover, reboot.")
            }

            let conclusive = !lostExternalPower && (sawChargingStop || sawInhibitReason)
            exitNow(allOpen && chargingResumed && conclusive ? 0 : 1)
        }
    }

    private func exitNow(_ code: Int32) -> Never {
        smc.close()
        fflush(stdout)
        exit(code)
    }

    // MARK: - Helpers

    private func hex(_ bytes: [UInt8]) -> String { bytes.hexString }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("[\(stamp)] \(message)")
        fflush(stdout)
    }
}
