import DranikCore
import DranikSMC
import Foundation
import os

/// Reads and writes the firmware's charge corridor.
///
/// The counterpart of `GateActuator`, and much the smaller of the two, because
/// the thing it drives keeps its own state. There is no position to remember, no
/// write to verify against a clock and no trust to lose: a corridor either reads
/// back as what was asked for or it does not, and the answer is available at any
/// moment for the cost of three reads.
///
/// One rule is inverted from the gate, and deliberately. The gate must be opened
/// on every exit — a shut gate left behind stops the battery charging. The
/// corridor must be *left alone* on exit: it is the limit working, and clearing
/// it on shutdown would mean charge limiting lapses every time the daemon
/// restarts. Clearing it is uninstalling's job.
final class FirmwareLimitActuator {
    private let smc: SMCConnection
    private let spec: FirmwareLimitSpec
    private let dryRun: Bool
    private let log = Logger(subsystem: "com.dranik.battery", category: "FirmwareLimit")

    init(smc: SMCConnection, spec: FirmwareLimitSpec, dryRun: Bool) {
        self.smc = smc
        self.spec = spec
        self.dryRun = dryRun
    }

    /// What the firmware says the corridor is, or `nil` if any of the three keys
    /// could not be read.
    ///
    /// All three or nothing: two out of three describes no corridor, and a
    /// partial reading compared against a plan would produce a confident wrong
    /// answer about whether to write.
    func read() -> FirmwareLimitState? {
        guard let activation = try? smc.read(spec.activation),
              let upper = try? smc.read(spec.upper),
              let lower = try? smc.read(spec.lower),
              let activationByte = activation.bytes.first
        else {
            log.error("could not read the firmware corridor")
            return nil
        }
        return FirmwareLimitState(
            isActive: activationByte == FirmwareLimitSpec.activeByte,
            upper: FirmwareLimitSpec.percent(from: upper.bytes),
            lower: FirmwareLimitSpec.percent(from: lower.bytes)
        )
    }

    /// Hands `plan` to the firmware, in the order the firmware requires.
    ///
    /// Deactivate first, then the bounds, then activate: the corridor is never
    /// live while half-written. A failure part-way leaves the mechanism switched
    /// off rather than enforcing a corridor nobody asked for, which is the right
    /// way round — charging unrestricted is the recoverable state.
    @discardableResult
    func apply(_ plan: FirmwareLimitPlan, reason: String) -> Bool {
        switch plan {
        case .off:
            return write(spec.activation, [FirmwareLimitSpec.inactiveByte], spec.activationInfo,
                         what: "corridor off (\(reason))")
        case .hold(let lower, let upper):
            let steps: [(SMCKey, [UInt8], SMCKeyInfo, String)] = [
                (spec.activation, [FirmwareLimitSpec.inactiveByte], spec.activationInfo,
                 "deactivate before writing bounds"),
                (spec.upper, FirmwareLimitSpec.percentBytes(upper), spec.upperInfo,
                 "upper \(upper)%"),
                (spec.lower, FirmwareLimitSpec.percentBytes(lower), spec.lowerInfo,
                 "lower \(lower)%"),
                (spec.activation, [FirmwareLimitSpec.activeByte], spec.activationInfo,
                 "activate"),
            ]
            log.notice("""
            setting the firmware corridor to \(lower, privacy: .public)–\
            \(upper, privacy: .public)% (\(reason, privacy: .public))
            """)
            for (key, bytes, info, what) in steps {
                guard write(key, bytes, info, what: what) else {
                    // Whatever failed, do not leave bounds armed behind it.
                    _ = write(spec.activation, [FirmwareLimitSpec.inactiveByte],
                              spec.activationInfo, what: "backing out a failed corridor write")
                    return false
                }
            }
            return true
        }
    }

    /// Takes the corridor back, so charging is unrestricted again.
    func clear(reason: String) -> Bool {
        apply(.off, reason: reason)
    }

    private func write(
        _ key: SMCKey, _ bytes: [UInt8], _ info: SMCKeyInfo, what: String
    ) -> Bool {
        if dryRun {
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            log.notice("""
            DRY RUN — would write \(key.description, privacy: .public) = \
            \(hex, privacy: .public) (\(what, privacy: .public))
            """)
            return true
        }
        do {
            try smc.write(key, bytes: bytes, matching: info)
            return true
        } catch {
            log.fault("""
            writing \(key.description, privacy: .public) (\(what, privacy: .public)) failed: \
            \(String(describing: error), privacy: .public)
            """)
            return false
        }
    }
}
