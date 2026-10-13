import DranikCore
import DranikSMC
import Foundation

func runFirmwareLimitPlanTests() {
    test("a limit below 100 becomes a corridor for the firmware to hold") {
        let plan = FirmwareLimitPlan.forConfig(ChargeConfig(upperLimit: 80, lowerLimit: 75))
        expectEqual(plan, .hold(lower: 75, upper: 80))
    }

    test("a limit of 100 means the firmware holds nothing") {
        // The same meaning `upperLimit == 100` has everywhere else: not a
        // corridor at the top of the range, but no corridor at all.
        expectEqual(FirmwareLimitPlan.forConfig(ChargeConfig(upperLimit: 100)), .off)
        expectFalse(FirmwareLimitPlan.off.isLimiting)
    }

    test("the corridor never asks the firmware to hold below the emergency floor") {
        // Principle II, as a second barrier. `ChargeConfig` clamps too, so this
        // only fires if that ever stops being true — which is the point of
        // having it here as well.
        let plan = FirmwareLimitPlan.forConfig(ChargeConfig(upperLimit: 50, lowerLimit: 5))
        guard case .hold(let lower, let upper) = plan else {
            return expectTrue(false, "expected a corridor, got \(plan)")
        }
        expectTrue(lower >= ChargeConfig.emergencyFloor)
        expectTrue(lower < upper)
    }

    test("a corridor is satisfied only by exactly itself") {
        let plan = FirmwareLimitPlan.hold(lower: 75, upper: 80)
        expectTrue(plan.isSatisfied(by: FirmwareLimitState(isActive: true, upper: 80, lower: 75)))
        // Inactive with the right numbers is the state right after a reboot that
        // kept the bounds but dropped the activation. It enforces nothing.
        expectFalse(plan.isSatisfied(by: FirmwareLimitState(isActive: false, upper: 80, lower: 75)))
        expectFalse(plan.isSatisfied(by: FirmwareLimitState(isActive: true, upper: 90, lower: 75)))
        expectFalse(plan.isSatisfied(by: FirmwareLimitState(isActive: true, upper: 80, lower: 70)))
    }

    test("off is satisfied by an inactive corridor whatever its bounds") {
        // The bounds are meaningless while the activation byte is clear, so
        // demanding zeroes would mean a pointless write every pass.
        expectTrue(FirmwareLimitPlan.off.isSatisfied(
            by: FirmwareLimitState(isActive: false, upper: 80, lower: 75)
        ))
        expectFalse(FirmwareLimitPlan.off.isSatisfied(
            by: FirmwareLimitState(isActive: true, upper: 80, lower: 75)
        ))
    }
}

func runFirmwareLimitPolicyTests() {
    let config = ChargeConfig(upperLimit: 80, lowerLimit: 75)

    test("a corridor already held needs no write") {
        // The steady state, and the whole reason this path is cheap: the
        // firmware keeps the corridor between decisions, so the daemon's normal
        // behaviour is to write nothing at all.
        let decision = FirmwareLimitPolicy.decide(
            config: config,
            observed: FirmwareLimitState(isActive: true, upper: 80, lower: 75),
            percentage: 78
        )
        expectFalse(decision.requiresWrite)
        expectEqual(decision.reason.code, "firmwareHoldingBelow")
    }

    test("a corridor that drifted is put back") {
        let decision = FirmwareLimitPolicy.decide(
            config: config,
            observed: FirmwareLimitState(isActive: false, upper: 0, lower: 0),
            percentage: 78
        )
        expectTrue(decision.requiresWrite)
        expectEqual(decision.plan, .hold(lower: 75, upper: 80))
        expectEqual(decision.reason.code, "firmwareCorridorDrifted")
    }

    test("an unreadable corridor is reported, not written over") {
        // Writing blindly would be refused by the guarded path anyway, which
        // reads the descriptor first. Claiming to have fixed it would not be.
        let decision = FirmwareLimitPolicy.decide(
            config: config, observed: nil, percentage: 78
        )
        expectFalse(decision.requiresWrite)
        expectEqual(decision.reason.code, "firmwareCorridorUnreadable")
        expectTrue(decision.reason.isFault)
    }

    test("being above the corridor is its own state, not holding at the limit") {
        // Measured 2026-10-13: above the corridor the firmware runs the machine
        // off the battery to bring it down. Reporting that as "holding at 80 %"
        // while the figure says 100 % is how a working limit reads as a bug.
        let decision = FirmwareLimitPolicy.decide(
            config: config,
            observed: FirmwareLimitState(isActive: true, upper: 80, lower: 75),
            percentage: 100
        )
        expectEqual(decision.reason.code, "firmwareAboveCorridor")
        expectFalse(decision.reason.isFault)
        expectTrue(decision.reason.description.contains("on battery"))
    }

    test("sitting exactly on the limit reads as having reached it") {
        let decision = FirmwareLimitPolicy.decide(
            config: config,
            observed: FirmwareLimitState(isActive: true, upper: 80, lower: 75),
            percentage: 80
        )
        // Shares `reachedUpper` with the gate path on purpose: a client showing
        // an icon for "at the limit" should not need to know which mechanism got
        // it there.
        expectEqual(decision.reason.code, "reachedUpper")
    }

    test("an unreadable charge does not become a charge of zero") {
        let decision = FirmwareLimitPolicy.decide(
            config: config,
            observed: FirmwareLimitState(isActive: true, upper: 80, lower: 75),
            percentage: nil
        )
        expectEqual(decision.reason.code, "firmwareHoldingUnknownCharge")
        // The bug this guards against is a missing reading becoming the sentence
        // "charge 0% is charging towards it", which reads as a flat battery.
        expectFalse(decision.reason.description.contains("charge 0"))
        expectTrue(decision.reason.description.contains("not readable"))
    }

    test("a limit of 100 switches the corridor off rather than widening it") {
        let decision = FirmwareLimitPolicy.decide(
            config: ChargeConfig(upperLimit: 100),
            observed: FirmwareLimitState(isActive: true, upper: 80, lower: 75),
            percentage: 90
        )
        expectTrue(decision.requiresWrite)
        expectEqual(decision.plan, .off)
    }
}

func runFirmwareModeTests() {
    test("a firmware corridor is preferred over a software gate") {
        // Principle VI in practice: chosen by what the hardware offers, never by
        // the OS version. Where both exist the firmware wins, because its
        // corridor survives sleep, restarts and crashes.
        expectEqual(
            DaemonMode.forHardware(firmwareLimitIsSupported: true, gateIsSupported: true),
            .firmwareLimiting
        )
        expectEqual(
            DaemonMode.forHardware(firmwareLimitIsSupported: true, gateIsSupported: false),
            .firmwareLimiting
        )
        expectEqual(
            DaemonMode.forHardware(firmwareLimitIsSupported: false, gateIsSupported: true),
            .limiting
        )
        expectEqual(
            DaemonMode.forHardware(firmwareLimitIsSupported: false, gateIsSupported: false),
            .observing
        )
    }

    test("the firmware corridor is deliberately left behind on exit") {
        // The inversion that matters most in this change. A gate left closed
        // stops the battery charging, so it must be opened on the way out. A
        // corridor left set *is* the limit working — clearing it on exit would
        // mean charge limiting lapsed on every restart, and `make install`
        // restarts the daemon.
        expectFalse(DaemonMode.firmwareLimiting.restoresOnExit)
        expectTrue(DaemonMode.limiting.restoresOnExit)
        expectFalse(DaemonMode.observing.restoresOnExit)
    }

    test("the firmware path runs no watchdog but keeps a safety net") {
        // Nothing to guard: there is no gate to get stuck and no decision to
        // stall. The safety net stays for a different reason — the corridor is
        // state something else could overwrite.
        expectFalse(DaemonMode.firmwareLimiting.runsWatchdog)
        expectTrue(DaemonMode.firmwareLimiting.runsSafetyNet)
        expectTrue(DaemonMode.firmwareLimiting.mayWriteToSMC)
    }
}

func runFirmwareLimitEncodingTests() {
    test("percentages go to the firmware little-endian") {
        // Fact 4 of the project: raw SMC bytes on Apple Silicon are
        // little-endian. `batt` reverses its own because its codec is
        // big-endian; copying that would write 80 as 0x50000000.
        expectEqual(FirmwareLimitSpec.percentBytes(80), [0x50, 0x00, 0x00, 0x00])
        expectEqual(FirmwareLimitSpec.percentBytes(75), [0x4B, 0x00, 0x00, 0x00])
        expectEqual(FirmwareLimitSpec.percentBytes(100), [0x64, 0x00, 0x00, 0x00])
    }

    test("a percentage survives the round trip") {
        for value in [0, 1, 20, 75, 80, 99, 100] {
            expectEqual(FirmwareLimitSpec.percent(from: FirmwareLimitSpec.percentBytes(value)), value)
        }
    }

    test("a percentage out of range is clamped rather than truncated") {
        // `UInt32(…)` on a negative number traps, and a limit of 240 would
        // otherwise reach the firmware as one byte of nonsense.
        expectEqual(FirmwareLimitSpec.percentBytes(-5), [0x00, 0x00, 0x00, 0x00])
        expectEqual(FirmwareLimitSpec.percentBytes(240), [0x64, 0x00, 0x00, 0x00])
    }

    test("the activation bytes are the two the firmware recognises") {
        expectEqual(FirmwareLimitSpec.activeByte, 0x02)
        expectEqual(FirmwareLimitSpec.inactiveByte, 0x00)
    }

    test("the corridor's keys are the three measured ones, in write order") {
        expectEqual(
            FirmwareLimitSpec.bf0.keys.map(\.description),
            ["bfF0", "bfD0", "bfE0"]
        )
    }
}

/// Reads this machine's SMC. Skips where the firmware offers no corridor, which
/// is every Mac on firmware older than mBoot-20457.
func runLiveFirmwareLimitTests() {
    test("the firmware corridor is detected, or this machine genuinely has none") {
        guard let smc = try? SMCConnection() else {
            throw Harness.Skip(reason: "AppleSMC is not available")
        }
        defer { smc.close() }
        guard let capabilities = try? Capabilities.detect(using: smc) else {
            throw Harness.Skip(reason: "capabilities could not be probed")
        }

        // Distinguishes "no corridor here" from "the corridor is here and
        // probing failed to see it", which is the failure worth catching.
        let anyKeyExists = FirmwareLimitSpec.bf0.keys.contains { key in
            ((try? smc.keyInfo(key)) ?? nil) != nil
        }
        guard anyKeyExists else {
            throw Harness.Skip(reason: "no firmware corridor keys exist on this machine")
        }
        expectTrue(
            capabilities.firmwareLimit.isSupported,
            "the corridor keys exist but probing did not recognise them"
        )
    }

    test("a corridor and a gate are never both driven") {
        // The two mechanisms write different keys to mean the same thing, and
        // principle III allows exactly one writer. The mode is what enforces it.
        guard let smc = try? SMCConnection() else {
            throw Harness.Skip(reason: "AppleSMC is not available")
        }
        defer { smc.close() }
        guard let capabilities = try? Capabilities.detect(using: smc) else {
            throw Harness.Skip(reason: "capabilities could not be probed")
        }
        let mode = DaemonMode.forHardware(
            firmwareLimitIsSupported: capabilities.firmwareLimit.isSupported,
            gateIsSupported: capabilities.chargeGate.isSupported
        )
        if capabilities.firmwareLimit.isSupported {
            expectEqual(mode, .firmwareLimiting)
        } else if capabilities.chargeGate.isSupported {
            expectEqual(mode, .limiting)
        } else {
            expectEqual(mode, .observing)
        }
    }
}
