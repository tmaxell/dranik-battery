import DranikCore
import DranikPower
import DranikSMC
import Foundation

/// Question 2.6: does a closed charge gate survive sleep?
///
/// It matters because the daemon does not run while the machine is asleep. If
/// the gate holds, closing it before sleep is enough to keep the limit through
/// the night. If the SMC clears it on wake, the battery charges freely until
/// the daemon gets a chance to run, and the whole sleep policy has to change.
///
/// Safe to run: no reboot, and the gate is reopened when the machine wakes, when
/// the awake budget runs out, or on any signal.
enum SleepTest {
    /// How long the machine may stay awake before the test gives up and
    /// restores. Counted in awake seconds, so a long sleep does not consume it.
    static let awakeBudget: TimeInterval = 150

    static func run(gate: Gate, sleepNow: Bool) -> Never {
        let queue = DispatchQueue(label: "com.dranik.battery.persistence.sleep")
        var restored = false
        var detector = SleepDetector()
        let started = Clocks.excludingSleep()

        // Every path that reopens the gate, registered before it is ever closed.
        func restore(_ reason: String) -> Never {
            if restored { exit(0) }
            restored = true
            note("restoring (\(reason))")
            let failures = gate.open()
            report(gate: gate, failures: failures)
        }

        var sources: [DispatchSourceProtocol] = []
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { restore("signal \(signalNumber)") }
            source.resume()
            sources.append(source)
        }
        note("rollback armed: signals, plus \(Int(awakeBudget))s of awake time")

        queue.async {
            do {
                try gate.close()
            } catch {
                note("FAILED to close the gate: \(error)")
                restore("close failed")
            }

            print("")
            if sleepNow {
                note("putting the machine to sleep in 3s — wake it when you are ready")
            } else {
                note("gate is closed. Put the machine to sleep now (close the lid, or "
                    + "run `pmset sleepnow` in another window), then wake it.")
            }
            print("")
        }

        if sleepNow {
            queue.asyncAfter(deadline: .now() + .seconds(3)) {
                // Not via `pmset`'s root path — this is the plain user-level
                // request, which is what closing the lid does too.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                process.arguments = ["sleepnow"]
                try? process.run()
            }
        }

        // A ticker rather than a deadline timer: dispatch timers are defined
        // against a clock whose behaviour across sleep is not something worth
        // depending on here, whereas CLOCK_UPTIME_RAW is documented not to
        // advance while asleep and can be checked explicitly.
        let ticker = DispatchSource.makeTimerSource(queue: queue)
        ticker.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        ticker.setEventHandler {
            if let slept = detector.sample() {
                // First tick after waking. Read the gate before anything else
                // has a chance to touch it.
                let payload = gate.read()
                let survived = payload == gate.primary.offBytes

                print("")
                print("─── result: gate across sleep ──────────────────────────")
                print(String(format: "  slept for:  %.0f seconds", slept))
                print("  gate reads: \(gate.describe())")
                if let snapshot = try? PowerReader.snapshot() {
                    print("  charging:   \(snapshot.isCharging), \(snapshot.amperage) mA")
                    print("  reason:     \(snapshot.notChargingReason.map(String.init(describing:)) ?? "-")")
                }
                print("")
                if survived {
                    print("  ✅ SURVIVED — the gate was still closed on wake.")
                    print("     Closing it before sleep is enough to hold the limit.")
                } else {
                    print("  ❌ CLEARED — the SMC reset the gate during sleep or on wake.")
                    print("     Closing it before sleep buys nothing; the battery charges")
                    print("     freely until the daemon runs again after waking.")
                }
                print("")
                restore("machine woke")
            }

            if Clocks.excludingSleep() - started > awakeBudget {
                print("")
                print("─── result: gate across sleep ──────────────────────────")
                print("  INCONCLUSIVE — the machine never slept within the budget.")
                print("")
                restore("awake budget exhausted")
            }
        }
        ticker.resume()
        sources.append(ticker)

        dispatchMain()
    }

    private static func report(gate: Gate, failures: [String]) -> Never {
        // The gate takes about seven seconds to act, in either direction.
        Thread.sleep(forTimeInterval: ChargeGateTiming.verificationWindow)

        print("  gate now:   \(gate.describe())")
        if let snapshot = try? PowerReader.snapshot() {
            print("  charging:   \(snapshot.isCharging), \(snapshot.amperage) mA")
        }
        if !failures.isEmpty {
            print("")
            print("  ⚠️  RESTORE FAILED — the gate may still be closed:")
            for failure in failures { print("      \(failure)") }
            print("      Reboot restores the SMC to defaults on Apple Silicon.")
            exit(2)
        }
        exit(gate.isOpen ? 0 : 2)
    }
}
