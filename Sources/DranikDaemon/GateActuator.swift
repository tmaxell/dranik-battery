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
    private var consecutiveFailures = 0
    private var hasLoggedDistrust = false

    public init(smc: SMCConnection, specs: [SMCKeySpec], queue: DispatchQueue, dryRun: Bool) {
        self.smc = smc
        self.specs = specs
        self.queue = queue
        self.dryRun = dryRun
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
                \(Self.hex(payload), privacy: .public) (\(position.rawValue, privacy: .public), \
                \(reason, privacy: .public))
                """)
                continue
            }
            do {
                try smc.write(spec.key, bytes: payload, matching: spec.expectedInfo)
                log.notice("""
                \(spec.key.description, privacy: .public) -> \
                \(Self.hex(payload), privacy: .public) (\(position.rawValue, privacy: .public), \
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

        let work = DispatchWorkItem { [weak self] in
            self?.verify(position, onACAtWrite: onACAtWrite)
        }
        pendingVerification = work
        queue.asyncAfter(
            deadline: .now() + ChargeGateTiming.verificationWindow, execute: work
        )
    }

    private func verify(_ expected: GatePosition, onACAtWrite: Bool) {
        guard let snapshot = try? PowerReader.snapshot() else { return }

        let verdict = GateVerification.judge(
            expected: expected,
            onACAtWrite: onACAtWrite,
            onACNow: snapshot.isExternalConnected,
            inhibitedNow: snapshot.notChargingReason?.contains(.inhibited) ?? false
        )

        switch verdict {
        case .confirmed:
            consecutiveFailures = 0
            log.debug("gate verified \(expected.rawValue, privacy: .public)")
        case .inconclusive(let why):
            // Not evidence of anything. Leave the failure count alone.
            log.debug("gate check inconclusive: \(why, privacy: .public)")
        case .contradicted(let why):
            consecutiveFailures += 1
            log.error("""
            gate check failed (\(self.consecutiveFailures, privacy: .public)): \
            \(why, privacy: .public)
            """)
            // One contradicted check is not enough to switch the feature off.
            // Two in a row, both conclusive, is.
            if consecutiveFailures >= 2 {
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

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
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
    public static func judge(
        expected: GatePosition,
        onACAtWrite: Bool,
        onACNow: Bool,
        inhibitedNow: Bool
    ) -> GateVerification {
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
            return inhibitedNow
                ? .confirmed
                : .contradicted("gate set closed but the charger is not inhibited")
        case .open:
            return inhibitedNow
                ? .contradicted("gate set open but the charger is still inhibited")
                : .confirmed
        }
    }
}
