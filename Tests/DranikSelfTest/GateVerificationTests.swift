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

    test("a window spent asleep is inconclusive, however it looks") {
        // Ten hours of running produced two failed checks even after the window
        // was widened from 20s to 45s, both clustered around sleeps. Widening
        // could never have fixed it: the window is wall time, and sleep passes
        // through it while the charger does nothing at all.
        for inhibited in [true, false] {
            guard case .inconclusive = GateVerification.judge(
                expected: .closed, onACAtWrite: true, onACNow: true,
                inhibitedNow: inhibited, awakeSecondsElapsed: 2
            ) else {
                return expectTrue(false, "a window spent asleep proves nothing")
            }
        }
    }

    test("a window that was actually spent running still judges") {
        // The fix must not have made every check inconclusive.
        guard case .contradicted = GateVerification.judge(
            expected: .closed, onACAtWrite: true, onACNow: true,
            inhibitedNow: false, awakeSecondsElapsed: 45
        ) else {
            return expectTrue(false, "a genuine failure must still be caught")
        }
    }

    test("the awake threshold is the measured hardware latency, not a guess") {
        // Just under the seven seconds the hardware was measured to need.
        guard case .inconclusive = GateVerification.judge(
            expected: .closed, onACAtWrite: true, onACNow: true,
            inhibitedNow: false, awakeSecondsElapsed: 6.9
        ) else {
            return expectTrue(false, "below the measured latency nothing can be concluded")
        }
        guard case .contradicted = GateVerification.judge(
            expected: .closed, onACAtWrite: true, onACNow: true,
            inhibitedNow: false, awakeSecondsElapsed: 7.1
        ) else {
            return expectTrue(false, "above it, a contradiction is real")
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

/// The second time this mechanism switched itself off, on 2026-08-19, and
/// stayed off for two days with the battery sitting at 100 %.
///
/// Two contradicted checks eighteen minutes apart did it. Neither was evidence
/// of a broken gate: the first was judged across a wake that arrived one second
/// after the write, and the second came moments after the charge reached the
/// limit, when the charger had stopped of its own accord.
func runGateTrustTests() {
    test("a write judged across a wake is inconclusive, not a contradiction") {
        // The wake landed after the write, so the time awake before it is
        // negative. The old sleep guard could not see this: the whole window
        // was spent awake, because the sleep was on the other side of the write.
        guard case .inconclusive = GateVerification.judge(
            expected: .open, onACAtWrite: true, onACNow: true, inhibitedNow: true,
            awakeSecondsElapsed: 48, awakeSecondsBeforeWrite: -1
        ) else {
            return expectTrue(false, "a wake beside the write must not be judged")
        }
    }

    test("a write moments after a wake is inconclusive too") {
        guard case .inconclusive = GateVerification.judge(
            expected: .closed, onACAtWrite: true, onACNow: true, inhibitedNow: false,
            awakeSecondsElapsed: 48, awakeSecondsBeforeWrite: 5
        ) else {
            return expectTrue(false, "the charger has its own recovery to do")
        }
    }

    test("a settled machine is still judged normally") {
        expectEqual(
            GateVerification.judge(
                expected: .closed, onACAtWrite: true, onACNow: true, inhibitedNow: true,
                awakeSecondsElapsed: 48, awakeSecondsBeforeWrite: 600
            ),
            .confirmed
        )
    }

    test("a full battery explains a missing inhibit, so the check cannot judge") {
        guard case .inconclusive = GateVerification.judge(
            expected: .closed, onACAtWrite: true, onACNow: true,
            inhibitedNow: false, batteryFullNow: true
        ) else {
            return expectTrue(false, "a charger that stopped on its own proves nothing")
        }
    }

    test("a full battery does not excuse a gate that should be open") {
        // Asked to open, still inhibited: fullness is no explanation for that,
        // and loosening it here would be loosening it everywhere.
        guard case .contradicted = GateVerification.judge(
            expected: .open, onACAtWrite: true, onACNow: true,
            inhibitedNow: true, batteryFullNow: true
        ) else {
            return expectTrue(false, "an open gate still holding the inhibit is wrong")
        }
    }

    // MARK: - How long a run of failures stays a run

    test("two contradictions close together still disable the gate") {
        var failures = VerificationFailures()
        expectFalse(failures.contradicted(at: 1_000), "one is never enough")
        expectTrue(failures.contradicted(at: 1_060), "two a minute apart is the case this is for")
    }

    test("two contradictions far apart are two accidents, not a broken gate") {
        // The 2026-08-19 sequence: eighteen minutes is inside the window, but a
        // pair of unrelated hiccups hours or days apart must not add up. Checks
        // happen only when the gate moves — about five times in two days — so
        // without this an unbounded counter means "twice, ever".
        var failures = VerificationFailures()
        expectFalse(failures.contradicted(at: 1_000))
        expectFalse(
            failures.contradicted(at: 1_000 + VerificationFailures.sameFaultWindow + 1),
            "a failure this far from the last one starts a new run"
        )
        expectEqual(failures.count, 1)
    }

    test("a confirmation clears the run") {
        var failures = VerificationFailures()
        expectFalse(failures.contradicted(at: 1_000))
        failures.confirmed()
        expectFalse(failures.contradicted(at: 1_010), "the previous run is over")
        expectEqual(failures.count, 1)
    }

    test("a new run can still reach the threshold") {
        var failures = VerificationFailures()
        expectFalse(failures.contradicted(at: 1_000))
        let later = 1_000 + VerificationFailures.sameFaultWindow + 1
        expectFalse(failures.contradicted(at: later))
        expectTrue(failures.contradicted(at: later + 10), "a real fault still gets caught")
    }
}
