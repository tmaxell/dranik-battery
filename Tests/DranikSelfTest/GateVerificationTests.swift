import DranikCore
import DranikDaemon
import Foundation

/// The first real installation switched its own charge limiting off within
/// twenty seconds, and these are the cases that let it.
///
/// What happened: the daemon started while the machine was on battery, closed
/// the gate to keep a later reconnection from micro-charging, and scheduled a
/// check. The charger was plugged in a few seconds before that check ran. By
/// then the machine was on AC — so the check considered itself entitled to
/// judge — but the hardware had not yet had the seven seconds it takes to act,
/// so the charger was not reporting the inhibit. The check called the mechanism
/// broken, reopened the gate, and refused to close it again.
func runGateVerificationTests() {
    test("closed and inhibited on AC throughout is confirmed") {
        expectEqual(
            GateVerification.judge(
                expected: .closed, onACAtWrite: true, onACNow: true, inhibitedNow: true
            ),
            .confirmed
        )
    }

    test("closed but not inhibited, on AC throughout, is a real contradiction") {
        // The case the check exists for: nothing changed, the window elapsed,
        // and the charger is not inhibited. That is a limit doing nothing.
        guard case .contradicted = GateVerification.judge(
            expected: .closed, onACAtWrite: true, onACNow: true, inhibitedNow: false
        ) else {
            return expectTrue(false, "a genuine failure must still be caught")
        }
    }

    test("the charger arriving after the write makes the check inconclusive") {
        // This is the exact sequence that disabled charge limiting on the first
        // real install.
        guard case .inconclusive = GateVerification.judge(
            expected: .closed, onACAtWrite: false, onACNow: true, inhibitedNow: false
        ) else {
            return expectTrue(false, "a charger attached mid-window must not count as evidence")
        }
    }

    test("no charger at check time is inconclusive, whatever was asked") {
        for expected in [GatePosition.open, .closed] {
            for inhibited in [true, false] {
                guard case .inconclusive = GateVerification.judge(
                    expected: expected, onACAtWrite: true,
                    onACNow: false, inhibitedNow: inhibited
                ) else {
                    return expectTrue(false, "\(expected)/\(inhibited) should be inconclusive")
                }
            }
        }
    }

    test("open and not inhibited is confirmed") {
        expectEqual(
            GateVerification.judge(
                expected: .open, onACAtWrite: true, onACNow: true, inhibitedNow: false
            ),
            .confirmed
        )
    }

    test("open but still inhibited is a contradiction") {
        guard case .contradicted = GateVerification.judge(
            expected: .open, onACAtWrite: true, onACNow: true, inhibitedNow: true
        ) else {
            return expectTrue(false, "a gate that will not reopen must be caught")
        }
    }

    test("every inconclusive case names why") {
        // A silent skip is indistinguishable from a check that never ran.
        let cases: [(Bool, Bool)] = [(false, true), (true, false), (false, false)]
        for (atWrite, now) in cases {
            let verdict = GateVerification.judge(
                expected: .closed, onACAtWrite: atWrite, onACNow: now, inhibitedNow: false
            )
            if case .inconclusive(let why) = verdict {
                expectFalse(why.isEmpty, "reason missing for \(atWrite)/\(now)")
            }
        }
    }

    test("only the on-AC-throughout cases are ever conclusive") {
        // Sweep the whole space and assert the rule directly, so a future edit
        // cannot widen what counts as evidence without failing here.
        for atWrite in [true, false] {
            for now in [true, false] {
                for inhibited in [true, false] {
                    let verdict = GateVerification.judge(
                        expected: .closed, onACAtWrite: atWrite,
                        onACNow: now, inhibitedNow: inhibited
                    )
                    let conclusive: Bool
                    switch verdict {
                    case .inconclusive: conclusive = false
                    default: conclusive = true
                    }
                    expectEqual(
                        conclusive, atWrite && now,
                        "atWrite=\(atWrite) now=\(now) inhibited=\(inhibited)"
                    )
                }
            }
        }
    }
}
