import DranikCore
import DranikPower
import DranikSMC
import Foundation
import os

/// Moves the charge gate and then checks the machine agreed.
///
/// Writing the key is not the same as the machine acting on it. The key reads
/// back its new value immediately; the hardware takes about seven seconds, and
/// the only independent evidence is `NotChargingReason` gaining or losing its
/// inhibit bit. So every move is followed, some seconds later, by a check that
/// says whether the mechanism is actually working.
///
/// If that check fails twice running the actuator stops trusting the gate
/// entirely: it opens it and refuses to close it again. A charge limit that
/// silently does nothing is worse than no charge limit, because it is believed.
public final class GateActuator {
    private let smc: SMCConnection
    private let specs: [SMCKeySpec]
    private let queue: DispatchQueue
    private let dryRun: Bool
    private let log = Logger(subsystem: "com.dranik.battery", category: "Gate")

    private(set) public var isTrusted = true
    private var pendingVerification: DispatchWorkItem?
    private var failures = VerificationFailures()
    private var hasLoggedDistrust = false
    /// When the machine last woke, on the awake clock. `nil` until it does.
    ///
    /// A gate write issued on either side of a wake cannot be judged: the
    /// charger has its own recovery to do, and it takes longer than the
    /// verification window.
    private var lastWakeAt: TimeInterval?

    public init(smc: SMCConnection, specs: [SMCKeySpec], queue: DispatchQueue, dryRun: Bool) {
        self.smc = smc
        self.specs = specs
        self.queue = queue
        self.dryRun = dryRun
    }

    /// Arms the gate again after someone has looked at why it was disarmed.
    ///
    /// Deliberately a request and never automatic. The mechanism exists because
    /// a limit that silently does nothing is worse than no limit; re-arming on a
    /// timer would restore exactly that, only on a schedule. Returns false when
    /// there was nothing to restore.
    @discardableResult
    func restoreTrust() -> Bool {
        guard !isTrusted else { return false }
        isTrusted = true
        hasLoggedDistrust = false
        failures = VerificationFailures()
        log.notice("charge limiting re-armed on request")
        return true
    }

    /// Told by the daemon on every wake. See `lastWakeAt`.
    func noteWake() {
        lastWakeAt = Clocks.excludingSleep()
    }

    /// Where the gate actually is, read from the SMC. `nil` if it cannot be read
    /// — which callers must treat as "unknown", never as "open".
    func readPosition() -> GatePosition? {
        guard let spec = specs.first,
              let reading = (try? smc.read(spec.key)) ?? nil else { return nil }
        if reading.bytes == spec.onBytes { return .open }
        if reading.bytes == spec.offBytes { return .closed }
        // Neither payload. The key is being driven by something else, or its
        // meaning has moved. Refuse to guess.
        log.fault("gate key \(spec.key.description, privacy: .public) holds an unrecognised value")
        return nil
    }

    /// Moves the gate. Returns false if any write failed.
    @discardableResult
    func apply(_ position: GatePosition, reason: String) -> Bool {
        if position == .closed && !isTrusted {
            // Permanent for the life of the process, so say it once rather than
            // on every percentage change. `dranik daemon` reports it standing.
            if !hasLoggedDistrust {
                hasLoggedDistrust = true
                log.error("refusing to close the gate: verification failed earlier")
            }
            return false
        }

        var succeeded = true
        for spec in specs {
            let payload = position == .open ? spec.onBytes : spec.offBytes
            if dryRun {
                log.notice("""
                DRY RUN \(spec.key.description, privacy: .public) -> \
                \(payload.hexString, privacy: .public) (\(position.rawValue, privacy: .public), \
                \(reason, privacy: .public))
                """)
                continue
            }
            do {
                try smc.write(spec.key, bytes: payload, matching: spec.expectedInfo)
                log.notice("""
                \(spec.key.description, privacy: .public) -> \
                \(payload.hexString, privacy: .public) (\(position.rawValue, privacy: .public), \
                \(reason, privacy: .public))
                """)
            } catch {
                succeeded = false
                log.fault("""
                write to \(spec.key.description, privacy: .public) failed: \
                \(String(describing: error), privacy: .public)
                """)
            }
        }

        scheduleVerification(of: position)
        return succeeded
    }

    /// Opens the gate without any of the trust checks, for the paths that must
    /// work even when everything else has gone wrong: signals, shutdown, the
    /// watchdog.
    func forceOpen(reason: String) {
        pendingVerification?.cancel()
        for spec in specs {
            if dryRun {
                log.notice("DRY RUN force open \(spec.key.description, privacy: .public)")
                continue
            }
            do {
                try smc.write(spec.key, bytes: spec.onBytes, matching: spec.expectedInfo)
                log.notice("forced \(spec.key.description, privacy: .public) open (\(reason, privacy: .public))")
            } catch {
                log.fault("""
                COULD NOT OPEN \(spec.key.description, privacy: .public): \
                \(String(describing: error), privacy: .public). A reboot clears the SMC.
                """)
            }
        }
    }

    // MARK: - Verification

    private func scheduleVerification(of position: GatePosition) {
        guard !dryRun else { return }
        pendingVerification?.cancel()

        // Captured now, not read later: whether the charger was attached at the
        // moment of the write is what decides if the check can mean anything.
        let onACAtWrite = (try? PowerReader.snapshot())?.isExternalConnected ?? false
        // And a clock that stops with the machine, so the check can tell whether
        // its own window was spent running or asleep.
        let awakeAtWrite = Clocks.excludingSleep()

        let work = DispatchWorkItem { [weak self] in
            self?.verify(position, onACAtWrite: onACAtWrite, awakeAtWrite: awakeAtWrite)
        }
        pendingVerification = work
        queue.asyncAfter(
            deadline: .now() + ChargeGateTiming.verificationWindow, execute: work
        )
    }

    private func verify(_ expected: GatePosition, onACAtWrite: Bool, awakeAtWrite: TimeInterval) {
        guard let snapshot = try? PowerReader.snapshot() else { return }

        let awakeNow = Clocks.excludingSleep()
        // How much of the window the machine actually spent running. A window
        // mostly spent asleep gave the hardware no chance to act, and judging it
        // is judging nothing.
        let awakeElapsed = awakeNow - awakeAtWrite
        // And how long it had been awake when the write went out. Negative when
        // the wake came after it, which is how the 2026-08-19 failure happened:
        // the write landed one second before `kIOMessageSystemHasPoweredOn`.
        let awakeBeforeWrite = lastWakeAt.map { awakeAtWrite - $0 } ?? .greatestFiniteMagnitude

        let charger = snapshot.notChargingReason
        let verdict = GateVerification.judge(
            expected: expected,
            onACAtWrite: onACAtWrite,
            onACNow: snapshot.isExternalConnected,
            inhibitedNow: charger?.contains(.inhibited) ?? false,
            batteryFullNow: charger?.contains(.batteryFull) ?? false,
            awakeSecondsElapsed: awakeElapsed,
            awakeSecondsBeforeWrite: awakeBeforeWrite
        )

        switch verdict {
        case .confirmed:
            failures.confirmed()
            // `notice`, not `debug`: debug records are not persisted, so a
            // post-mortem could see the failures but not how many checks passed
            // — the difference between two failures out of two and two out of
            // fifty. `dranik soak` reports the ratio now.
            log.notice("gate verified \(expected.rawValue, privacy: .public)")
        case .inconclusive(let why):
            // Not evidence of anything. Leave the run alone.
            log.debug("gate check inconclusive: \(why, privacy: .public)")
        case .contradicted(let why):
            let enough = failures.contradicted(at: awakeNow)
            // The charger's own words, not just our reading of them. Without
            // this a post-mortem can say only "not inhibited", which leaves the
            // difference between a broken gate and a battery that had simply
            // finished charging unanswerable — as it was on 2026-08-19.
            log.error("""
            gate check failed (\(self.failures.count, privacy: .public)): \
            \(why, privacy: .public); charger says \
            \(charger.map(String.init(describing:)) ?? "nothing", privacy: .public)
            """)
            if enough {
                distrust(why)
            }
        }
    }

    private func distrust(_ reason: String) {
        guard isTrusted else { return }
        isTrusted = false
        log.fault("""
        \(reason, privacy: .public) — charge limiting disabled, opening the gate. \
        This build will not close it again until restarted.
        """)
        forceOpen(reason: "verification failed")
    }

}

/// Whether a gate write can be judged to have worked, and if so what the answer
/// is.
///
/// Separated out because getting this wrong is expensive in both directions. Too
/// eager and a working limit is switched off by a transient reading; too lax and
/// a limit that does nothing is believed indefinitely.
public enum GateVerification: Equatable, Sendable {
    /// The evidence says the gate did what was asked.
    case confirmed
    /// The evidence contradicts it.
    case contradicted(String)
    /// There is no evidence either way, and absence of it proves nothing.
    case inconclusive(String)

    /// - Parameters:
    ///   - expected: what the gate was set to.
    ///   - onACAtWrite: whether the charger was attached when it was written.
    ///   - onACNow: whether it still is.
    ///   - inhibitedNow: whether the charger reports the software inhibit.
    ///   - awakeSecondsElapsed: how much of the window was spent running rather
    ///     than asleep.
    ///   - batteryFullNow: whether the charger reports the battery as full.
    ///   - awakeSecondsBeforeWrite: how long the machine had been awake when the
    ///     write went out. Negative when the wake came afterwards.
    public static func judge(
        expected: GatePosition,
        onACAtWrite: Bool,
        onACNow: Bool,
        inhibitedNow: Bool,
        batteryFullNow: Bool = false,
        awakeSecondsElapsed: TimeInterval = .greatestFiniteMagnitude,
        awakeSecondsBeforeWrite: TimeInterval = .greatestFiniteMagnitude
    ) -> GateVerification {
        // A write issued next to a wake is judged against a charger that has not
        // caught up. Measured on 2026-08-19: the gate was opened one second
        // before the wake notification arrived, and forty-eight seconds later
        // the charger still reported the old inhibit — which read as proof the
        // mechanism was broken, and switched charge limiting off.
        //
        // The existing sleep guard below could not catch this. It asks how much
        // of the *window* was spent awake, and the whole window was; the sleep
        // was on the other side of the write.
        guard awakeSecondsBeforeWrite >= Daemon.postWakeSettle else {
            return .inconclusive(String(
                format: "the machine woke %.0fs either side of the write",
                abs(awakeSecondsBeforeWrite)
            ))
        }
        // The hardware needs several seconds of the machine actually running to
        // act on a gate write. A window spent asleep gave it none of them.
        //
        // Two failed checks in ten hours survived widening the window from 20s
        // to 45s, both clustered around sleeps — because the window is wall
        // time and sleep passes through it without the charger doing anything.
        guard awakeSecondsElapsed >= ChargeGateTiming.observedEffectLatency else {
            return .inconclusive(String(
                format: "only %.0fs of the window was spent awake", awakeSecondsElapsed
            ))
        }
        // The inhibit bit only means anything on AC. Off it the charger reports
        // `onBattery` and stops for its own reasons, which says nothing at all
        // about the gate.
        guard onACNow else {
            return .inconclusive("not on AC now")
        }
        // And the charger has to have had the whole window to react. A gate
        // closed while on battery, with the charger attached moments before this
        // check, has not yet had the seven seconds the hardware takes — the
        // charger is legitimately not inhibited yet, and reading that as a
        // broken mechanism is how a working limit gets switched off.
        guard onACAtWrite else {
            return .inconclusive("charger was attached after the write")
        }

        switch expected {
        case .closed:
            if inhibitedNow { return .confirmed }
            // A charger that has finished charging has stopped for its own
            // reason, and whether it also asserts the software inhibit says
            // nothing about the gate. Reading that as a broken mechanism is the
            // likeliest explanation of the second failure on 2026-08-19, which
            // came moments after the charge reached the limit.
            if batteryFullNow {
                return .inconclusive("the charger reports the battery full")
            }
            return .contradicted("gate set closed but the charger is not inhibited")
        case .open:
            return inhibitedNow
                ? .contradicted("gate set open but the charger is still inhibited")
                : .confirmed
        }
    }
}
