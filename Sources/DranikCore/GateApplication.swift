import Foundation

/// What a gate write attempt leaves behind: what to believe afterwards, and what
/// to record.
///
/// Small enough to have been written inline, and it was — which is how three
/// bugs of the same shape got in at once. Each one recorded the decision rather
/// than the result: `state.json` claiming a gate that had never closed, the
/// pre-sleep path believing a write that failed just as the machine went to
/// sleep for eight hours, and the status report presenting a suppressed write as
/// applied.
///
/// The rule is one sentence — *the requested position may only be believed if
/// the write actually happened, and otherwise the hardware is the answer* — and
/// it is worth having somewhere it can be checked rather than re-derived.
public struct GateApplication: Equatable, Sendable {
    public struct Record: Equatable, Sendable {
        public let gateIsClosed: Bool
        public let reason: String
    }

    /// What the controller should believe now.
    public let believedGate: GatePosition?
    /// What to write to the state file, or `nil` when there is nothing worth
    /// saying.
    public let record: Record?

    public static func resolve(
        requested: GatePosition,
        reason: String,
        allowed: Bool,
        applied: Bool,
        actualGate: GatePosition?
    ) -> GateApplication {
        // Held back by a suppression window. Nothing was attempted, so there is
        // nothing to record — but the belief must not keep the position the
        // controller asked for, or the next decision concludes no write is
        // needed and the gate is never moved at all.
        guard allowed else {
            return GateApplication(believedGate: actualGate, record: nil)
        }

        guard applied else {
            // Attempted and refused, or attempted and failed. Whatever the gate
            // is now, it is not what was decided.
            return GateApplication(
                believedGate: actualGate,
                record: actualGate.map {
                    Record(gateIsClosed: $0 == .closed, reason: "\(reason) — not applied")
                }
            )
        }

        return GateApplication(
            believedGate: requested,
            record: Record(gateIsClosed: requested == .closed, reason: reason)
        )
    }
}
