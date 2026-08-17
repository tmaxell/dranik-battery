import DranikCore
import Foundation

/// Three bugs of one shape lived in this rule while it was written inline: the
/// state file claiming a gate that never closed, the pre-sleep path believing a
/// write that failed as the machine went to sleep for the night, and the status
/// report presenting a suppressed write as applied. Each recorded the decision
/// instead of the result.
func runGateApplicationTests() {
    test("a write that happened is believed and recorded") {
        let outcome = GateApplication.resolve(
            requested: .closed, reason: "reached the limit",
            allowed: true, applied: true, actualGate: .closed
        )
        expectEqual(outcome.believedGate, .closed)
        expectEqual(outcome.record?.gateIsClosed, true)
        expectEqual(outcome.record?.reason, "reached the limit")
    }

    test("a write that failed is not believed") {
        // The gate is open because the write did not take. Believing "closed"
        // here is what makes the next decision conclude no write is needed, and
        // the limit is then never enforced again.
        let outcome = GateApplication.resolve(
            requested: .closed, reason: "reached the limit",
            allowed: true, applied: false, actualGate: .open
        )
        expectEqual(outcome.believedGate, .open)
        expectEqual(outcome.record?.gateIsClosed, false, "must record what the gate is, not what was asked")
    }

    test("a failed write says so in what it records") {
        let outcome = GateApplication.resolve(
            requested: .closed, reason: "reached the limit",
            allowed: true, applied: false, actualGate: .open
        )
        expectTrue(
            outcome.record?.reason.contains("not applied") == true,
            "the record must distinguish itself from a successful write"
        )
    }

    test("a suppressed write records nothing at all") {
        // Nothing was attempted, so there is nothing to say happened.
        let outcome = GateApplication.resolve(
            requested: .open, reason: "fell to the resume point",
            allowed: false, applied: false, actualGate: .closed
        )
        expectNil(outcome.record)
        expectEqual(outcome.believedGate, .closed, "the belief follows the hardware")
    }

    test("a suppressed write does not leave the requested position believed") {
        // The specific failure: believing the gate is where it was asked to be
        // means requiresWrite is false next time, and the suppressed move never
        // happens once the window expires.
        let outcome = GateApplication.resolve(
            requested: .closed, reason: "reached the limit",
            allowed: false, applied: false, actualGate: .open
        )
        expectNotEqual(outcome.believedGate, .closed)
    }

    test("an unreadable gate after a failure is believed unknown, not guessed") {
        let outcome = GateApplication.resolve(
            requested: .closed, reason: "reached the limit",
            allowed: true, applied: false, actualGate: nil
        )
        expectNil(outcome.believedGate)
        expectNil(outcome.record, "nothing is known, so nothing is recorded")
    }

    test("opening works the same way round") {
        let applied = GateApplication.resolve(
            requested: .open, reason: "below the floor",
            allowed: true, applied: true, actualGate: .open
        )
        expectEqual(applied.believedGate, .open)
        expectEqual(applied.record?.gateIsClosed, false)

        let failed = GateApplication.resolve(
            requested: .open, reason: "below the floor",
            allowed: true, applied: false, actualGate: .closed
        )
        expectEqual(failed.believedGate, .closed)
        expectEqual(failed.record?.gateIsClosed, true)
    }

    test("the requested position is believed only when the write happened") {
        // The rule in one assertion, over every combination.
        for requested in [GatePosition.open, .closed] {
            for allowed in [true, false] {
                for applied in [true, false] {
                    for actual in [GatePosition.open, .closed, nil] {
                        let outcome = GateApplication.resolve(
                            requested: requested, reason: "r",
                            allowed: allowed, applied: applied && allowed, actualGate: actual
                        )
                        if applied && allowed {
                            expectEqual(outcome.believedGate, requested)
                        } else {
                            expectEqual(
                                outcome.believedGate, actual,
                                "requested=\(requested) allowed=\(allowed) applied=\(applied)"
                            )
                        }
                    }
                }
            }
        }
    }
}
