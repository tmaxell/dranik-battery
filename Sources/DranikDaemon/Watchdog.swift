import DranikCore
import DranikSMC
import Foundation
import os

/// Catches the failure launchd cannot see: a daemon that is alive but stuck.
///
/// `KeepAlive` restarts a process that exits. It does nothing for one whose queue
/// is wedged — blocked inside an SMC call, deadlocked, waiting on something that
/// will not come. From launchd's side that daemon is healthy. From the battery's
/// side the gate is shut and nothing is going to reopen it.
///
/// So the watchdog runs on its own queue with its **own** connection to the SMC.
/// Sharing one would defeat the point: if the main queue is blocked inside
/// `IOConnectCallStructMethod`, a rescue attempt through the same connection
/// would block in exactly the same place.
public final class Watchdog {
    /// How long the controller may go without reaching a decision before it is
    /// presumed stuck. Generous next to the ordinary event rate — several
    /// missed safety-net ticks, not one.
    public static let stallThreshold: TimeInterval = 120
    public static let checkInterval: TimeInterval = 30

    private let queue = DispatchQueue(label: "com.dranik.battery.watchdog")
    private let specs: [SMCKeySpec]
    private let dryRun: Bool
    private let stallThreshold: TimeInterval
    private let checkInterval: TimeInterval
    private let log = Logger(subsystem: "com.dranik.battery", category: "Watchdog")

    private let lock = NSLock()
    /// Measured in awake seconds, not wall-clock ones.
    ///
    /// This used `Date()`, and the result was that every sleep looked like a
    /// wedge: the machine slept for two hours, the clock advanced two hours, the
    /// controller had made no decision because nothing was running, and the
    /// watchdog forced the gate open and killed the daemon. Twenty-five times in
    /// three days, each one lifting the charge limit until launchd restarted it.
    ///
    /// A wedged controller and a sleeping machine are indistinguishable on a
    /// wall clock and trivially distinguishable on a clock that stops with the
    /// machine, which is what `CLOCK_UPTIME_RAW` is.
    private var lastProgress = Clocks.excludingSleep()
    private var timer: DispatchSourceTimer?

    /// Called instead of exiting, so the behaviour can be observed in a test.
    public var onStall: ((String) -> Void)?

    /// The intervals are parameters so the stall path can actually be exercised.
    /// A safety mechanism that only ever runs on a two-minute timer in
    /// production is a safety mechanism nobody has watched work.
    public init(
        specs: [SMCKeySpec],
        dryRun: Bool,
        stallThreshold: TimeInterval = Watchdog.stallThreshold,
        checkInterval: TimeInterval = Watchdog.checkInterval
    ) {
        self.specs = specs
        self.dryRun = dryRun
        self.stallThreshold = stallThreshold
        self.checkInterval = checkInterval
    }

    /// Called by the controller every time it completes a decision.
    public func recordProgress() {
        lock.lock()
        lastProgress = Clocks.excludingSleep()
        lock.unlock()
    }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + checkInterval, repeating: checkInterval
        )
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func check() {
        lock.lock()
        let idle = Clocks.excludingSleep() - lastProgress
        lock.unlock()

        guard idle > stallThreshold else { return }

        let message = String(
            format: "controller has not made a decision in %.0fs of running time — presumed stuck",
            idle
        )
        log.fault("\(message, privacy: .public)")

        rescue()

        if let onStall {
            onStall(message)
        } else {
            // Non-zero so launchd restarts us; the fresh process reconciles from
            // the SMC and picks up where this one failed to.
            exit(EX_SOFTWARE)
        }
    }

    /// Opens the gate through a connection this object owns exclusively.
    private func rescue() {
        guard !dryRun else {
            log.notice("DRY RUN — would force the gate open")
            return
        }
        do {
            let rescueConnection = try SMCConnection()
            defer { rescueConnection.close() }
            for spec in specs {
                try rescueConnection.write(
                    spec.key, bytes: spec.onBytes, matching: spec.expectedInfo
                )
                log.notice("watchdog opened \(spec.key.description, privacy: .public)")
            }
        } catch {
            log.fault("""
            watchdog could not open the gate: \(String(describing: error), privacy: .public). \
            A reboot clears the SMC.
            """)
        }
    }
}
