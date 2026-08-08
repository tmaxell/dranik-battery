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
/// If that check ever fails the actuator stops trusting the gate entirely: it
/// opens it and refuses to close it again. A charge limit that silently does
/// nothing is worse than no charge limit, because it is believed.
public final class GateActuator {
    private let smc: SMCConnection
    private let specs: [SMCKeySpec]
    private let queue: DispatchQueue
    private let dryRun: Bool
    private let log = Logger(subsystem: "com.dranik.battery", category: "Gate")

    private(set) var isTrusted = true
    private var pendingVerification: DispatchWorkItem?

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
            log.error("refusing to close the gate: verification failed earlier")
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

        let work = DispatchWorkItem { [weak self] in
            self?.verify(position)
        }
        pendingVerification = work
        queue.asyncAfter(
            deadline: .now() + ChargeGateTiming.verificationWindow, execute: work
        )
    }

    private func verify(_ expected: GatePosition) {
        guard let snapshot = try? PowerReader.snapshot() else { return }

        // Only meaningful on AC. Off it, charging is stopped for the obvious
        // reason and the inhibit bit says nothing about the gate.
        guard snapshot.isExternalConnected else { return }

        let inhibited = snapshot.notChargingReason?.contains(.inhibited) ?? false

        switch expected {
        case .closed where !inhibited:
            // The machine is on AC, we asked it to stop charging some seconds
            // ago, and it does not report being inhibited. The gate is not
            // doing what it claims.
            distrust("gate reported closed but the charger is not inhibited")
        case .open where inhibited:
            distrust("gate reported open but the charger is still inhibited")
        default:
            log.debug("gate verified \(expected.rawValue, privacy: .public)")
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
