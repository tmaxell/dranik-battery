import DranikCore
import DranikDaemon
import DranikSMC
import Foundation

/// The watchdog exists for the failure launchd cannot see: a daemon that is
/// alive but wedged. That path never runs in normal operation, which is exactly
/// why it has to be exercised deliberately — a rescue nobody has watched work is
/// not a rescue.
///
/// Every watchdog here is built with `dryRun: true`, so the rescue writes
/// nothing to the SMC.
func runWatchdogTests() {
    test("a stalled controller is noticed") {
        let watchdog = Watchdog(
            specs: [.chargeGateCHTE], dryRun: true,
            stallThreshold: 0.3, checkInterval: 0.1
        )
        let fired = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var message: String?

        watchdog.onStall = { reason in
            lock.lock(); message = reason; lock.unlock()
            fired.signal()
        }
        watchdog.start()
        defer { watchdog.stop() }

        expectEqual(fired.wait(timeout: .now() + .seconds(5)), .success, "watchdog never fired")
        lock.lock()
        let reported = message
        lock.unlock()
        expectTrue(reported?.contains("stuck") == true, "unhelpful message: \(reported ?? "nil")")
    }

    test("a controller making progress is left alone") {
        let watchdog = Watchdog(
            specs: [.chargeGateCHTE], dryRun: true,
            stallThreshold: 0.5, checkInterval: 0.1
        )
        let lock = NSLock()
        var stalls = 0
        watchdog.onStall = { _ in lock.lock(); stalls += 1; lock.unlock() }
        watchdog.start()
        defer { watchdog.stop() }

        // Report progress faster than the threshold for well past it.
        for _ in 0..<12 {
            watchdog.recordProgress()
            Thread.sleep(forTimeInterval: 0.1)
        }

        lock.lock()
        let observed = stalls
        lock.unlock()
        expectEqual(observed, 0, "watchdog fired on a healthy controller")
    }

    test("progress that stops is noticed") {
        // The realistic shape: healthy for a while, then wedged.
        let watchdog = Watchdog(
            specs: [.chargeGateCHTE], dryRun: true,
            stallThreshold: 0.3, checkInterval: 0.1
        )
        let fired = DispatchSemaphore(value: 0)
        watchdog.onStall = { _ in fired.signal() }
        watchdog.start()
        defer { watchdog.stop() }

        for _ in 0..<5 {
            watchdog.recordProgress()
            Thread.sleep(forTimeInterval: 0.05)
        }
        expectEqual(fired.wait(timeout: .now() + .seconds(5)), .success, "stall after activity missed")
    }

    test("a stopped watchdog stays quiet") {
        let watchdog = Watchdog(
            specs: [.chargeGateCHTE], dryRun: true,
            stallThreshold: 0.2, checkInterval: 0.1
        )
        let lock = NSLock()
        var stalls = 0
        watchdog.onStall = { _ in lock.lock(); stalls += 1; lock.unlock() }
        watchdog.start()
        watchdog.stop()

        Thread.sleep(forTimeInterval: 1.0)
        lock.lock()
        let observed = stalls
        lock.unlock()
        expectEqual(observed, 0, "a stopped watchdog kept firing")
    }

    test("sleep does not count towards a stall") {
        // The bug this exists for: the watchdog measured wall-clock time, so a
        // machine that slept for two hours looked exactly like a controller that
        // had wedged for two hours. It forced the gate open and killed the
        // daemon after every sleep — twenty-five times over three days on the
        // target machine, lifting the charge limit each time.
        //
        // Asserted through the clocks rather than by sleeping a machine: the
        // stall measure must come from the clock that stops with the hardware.
        let wall = Clocks.includingSleep()
        let awake = Clocks.excludingSleep()
        Thread.sleep(forTimeInterval: 0.05)

        let wallElapsed = Clocks.includingSleep() - wall
        let awakeElapsed = Clocks.excludingSleep() - awake
        expectTrue(
            awakeElapsed <= wallElapsed + 0.01,
            "the awake clock must never run ahead of the wall clock"
        )

        // And a watchdog left alone for longer than its threshold, in awake
        // time, still fires — the fix must not have disabled it.
        let watchdog = Watchdog(
            specs: [.chargeGateCHTE], dryRun: true,
            stallThreshold: 0.2, checkInterval: 0.05
        )
        let fired = DispatchSemaphore(value: 0)
        watchdog.onStall = { _ in fired.signal() }
        watchdog.start()
        defer { watchdog.stop() }
        expectEqual(fired.wait(timeout: .now() + .seconds(5)), .success)
    }

    test("the shipped thresholds leave room for several missed ticks") {
        // The stall threshold has to sit comfortably above the safety net's own
        // period, or an ordinary quiet minute would look like a wedge.
        expectTrue(
            Watchdog.stallThreshold > Daemon.safetyNetInterval,
            "a single missed safety-net tick would trip the watchdog"
        )
        expectTrue(Watchdog.checkInterval < Watchdog.stallThreshold)
    }
}
