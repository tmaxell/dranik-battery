import DranikCore
import DranikSMC
import Foundation

/// Clearing the firmware corridor from outside a running daemon.
///
/// It exists because the corridor outlives the process on purpose, which leaves
/// exactly one job that nothing else can do: uninstalling has to take the limit
/// back off the hardware, or the machine goes on being limited by software that
/// is no longer there.
///
/// Reached through `dranikd --clear-firmware-limit` rather than through the CLI,
/// because `dranik` reads and never writes, and writes to the SMC belong to the
/// daemon binary.
public enum FirmwareLimitMaintenance {
    public enum Outcome: Equatable, Sendable {
        /// No firmware corridor on this machine. Nothing to do and nothing wrong.
        case notSupported
        /// There was one, and it was already off.
        case alreadyOff
        /// It was on, and now it is off.
        case cleared(lower: Int, upper: Int)
        /// It is still on. The caller must not go on to remove anything.
        case failed(String)

        public var isSafeToProceed: Bool {
            switch self {
            case .notSupported, .alreadyOff, .cleared: return true
            case .failed: return false
            }
        }

        public var description: String {
            switch self {
            case .notSupported:
                return "no firmware charge corridor on this machine"
            case .alreadyOff:
                return "the firmware charge corridor was already off"
            case .cleared(let lower, let upper):
                return "cleared the firmware charge corridor (was \(lower)–\(upper) %)"
            case .failed(let why):
                return "the firmware charge corridor is STILL SET: \(why)"
            }
        }
    }

    public static func clear(
        smc: SMCConnection, capabilities: Capabilities, dryRun: Bool
    ) -> Outcome {
        guard let spec = capabilities.firmwareLimit.spec else { return .notSupported }
        let actuator = FirmwareLimitActuator(smc: smc, spec: spec, dryRun: dryRun)

        guard let before = actuator.read() else {
            return .failed("its keys could not be read, so its state is unknown")
        }
        guard before.isActive else { return .alreadyOff }

        guard actuator.clear(reason: "uninstalling") else {
            return .failed("the write was refused")
        }

        if dryRun { return .cleared(lower: before.lower, upper: before.upper) }

        // Read it back from the firmware rather than trusting the write. Same
        // rule as everywhere else here, and this is the one call whose caller is
        // about to delete the only thing that could fix a wrong answer.
        guard let after = actuator.read() else {
            return .failed("it could not be read back after the write")
        }
        guard !after.isActive else {
            return .failed("it still reads active after being cleared")
        }
        return .cleared(lower: before.lower, upper: before.upper)
    }
}
