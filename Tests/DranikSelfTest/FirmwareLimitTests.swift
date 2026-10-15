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

func runFirmwareActivityTests() {
    test("current into the battery is charging") {
        expectEqual(
            FirmwareChargeActivity.from(
                isExternalConnected: true, isCharging: true, milliamps: 1800, isInhibited: false
            ),
            .charging
        )
        // `isCharging` can lag the current, so either is enough.
        expectEqual(
            FirmwareChargeActivity.from(
                isExternalConnected: true, isCharging: false, milliamps: 1800, isInhibited: false
            ),
            .charging
        )
    }

    test("inhibited and still is sitting at the limit") {
        expectEqual(
            FirmwareChargeActivity.from(
                isExternalConnected: true, isCharging: false, milliamps: 0, isInhibited: true
            ),
            .heldOff
        )
    }

    test("a few milliamps either way is not movement") {
        // The battery reports housekeeping current while sitting still, and
        // reading that as "coming down" would make a settled machine look busy.
        for current in [-40, -1, 0, 1, 40] {
            expectEqual(
                FirmwareChargeActivity.from(
                    isExternalConnected: true, isCharging: false,
                    milliamps: current, isInhibited: true
                ),
                .heldOff,
                "\(current) mA should read as still"
            )
        }
    }

    test("inhibited and supplying the machine is coming down to the corridor") {
        // Measured 2026-10-13: above its corridor this firmware runs the machine
        // off the battery rather than merely refusing to charge.
        expectEqual(
            FirmwareChargeActivity.from(
                isExternalConnected: true, isCharging: false, milliamps: -698, isInhibited: true
            ),
            .comingDown
        )
    }

    test("no mains outranks everything else") {
        expectEqual(
            FirmwareChargeActivity.from(
                isExternalConnected: false, isCharging: false, milliamps: -1200, isInhibited: true
            ),
            .onBattery
        )
    }

    test("discharging on mains without an inhibit is not blamed on the limit") {
        // A load the adapter cannot cover looks like `comingDown` if the inhibit
        // flag is ignored. Saying "above the limit" there would be a guess, and
        // a wrong one.
        expectEqual(
            FirmwareChargeActivity.from(
                isExternalConnected: true, isCharging: false, milliamps: -900, isInhibited: false
            ),
            .indeterminate
        )
    }
}

func runFirmwareLimitPolicyTests() {
    let config = ChargeConfig(upperLimit: 80, lowerLimit: 75)
    let held = FirmwareLimitState(isActive: true, upper: 80, lower: 75)

    test("a corridor already held needs no write") {
        // The steady state, and the whole reason this path is cheap: the
        // firmware keeps the corridor between decisions, so the daemon's normal
        // behaviour is to write nothing at all.
        let decision = FirmwareLimitPolicy.decide(
            config: config, observed: held, activity: .charging
        )
        expectFalse(decision.requiresWrite)
        expectEqual(decision.reason.code, "firmwareChargingToLimit")
    }

    test("a settled corridor is not reported as coming down") {
        // The defect this replaced. The firmware enforces against the battery
        // gauge's state of charge; macOS displays a smoothed figure a few points
        // higher — 79 against 83, measured 2026-10-15. Comparing the configured
        // 80 against the displayed 83 produced "above the limit — running on
        // battery until it comes down" while the current sat at 0 mA, and it
        // would have said so for as long as the machine stayed plugged in.
        let decision = FirmwareLimitPolicy.decide(
            config: config, observed: held, activity: .heldOff
        )
        expectEqual(decision.reason.code, "reachedUpper")
        expectFalse(decision.reason.description.contains("until it comes down"))
    }

    test("the limit's prose never quotes a charge percentage") {
        // Because there are two of them and they disagree. Naming either one
        // invites "but the menu bar says 83".
        for activity in [FirmwareChargeActivity.charging, .heldOff, .comingDown,
                         .onBattery, .indeterminate] {
            let decision = FirmwareLimitPolicy.decide(
                config: config, observed: held, activity: activity
            )
            expectFalse(
                decision.reason.description.contains("charge "),
                "\(activity) said: \(decision.reason.description)"
            )
        }
    }

    test("a corridor that drifted is put back") {
        let decision = FirmwareLimitPolicy.decide(
            config: config,
            observed: FirmwareLimitState(isActive: false, upper: 0, lower: 0),
            activity: .charging
        )
        expectTrue(decision.requiresWrite)
        expectEqual(decision.plan, .hold(lower: 75, upper: 80))
        expectEqual(decision.reason.code, "firmwareCorridorDrifted")
    }

    test("drift is repaired before anything is said about charging") {
        // Order matters: a corridor that is not the one asked for is not
        // enforcing the limit, whatever the charger happens to be doing.
        let decision = FirmwareLimitPolicy.decide(
            config: config,
            observed: FirmwareLimitState(isActive: true, upper: 90, lower: 85),
            activity: .heldOff
        )
        expectTrue(decision.requiresWrite)
        expectEqual(decision.reason.code, "firmwareCorridorDrifted")
    }

    test("an unreadable corridor is reported, not written over") {
        // Writing blindly would be refused by the guarded path anyway, which
        // reads the descriptor first. Claiming to have fixed it would not be.
        let decision = FirmwareLimitPolicy.decide(
            config: config, observed: nil, activity: .heldOff
        )
        expectFalse(decision.requiresWrite)
        expectEqual(decision.reason.code, "firmwareCorridorUnreadable")
        expectTrue(decision.reason.isFault)
    }

    test("coming down to the corridor is its own state") {
        let decision = FirmwareLimitPolicy.decide(
            config: config, observed: held, activity: .comingDown
        )
        expectEqual(decision.reason.code, "firmwareComingDown")
        expectFalse(decision.reason.isFault)
        expectTrue(decision.reason.description.contains("on battery"))
    }

    test("on battery, the limit says nothing about charging") {
        let decision = FirmwareLimitPolicy.decide(
            config: config, observed: held, activity: .onBattery
        )
        expectEqual(decision.reason.code, "onBattery")
        expectFalse(decision.requiresWrite)
    }

    test("a limit of 100 switches the corridor off rather than widening it") {
        let decision = FirmwareLimitPolicy.decide(
            config: ChargeConfig(upperLimit: 100),
            observed: held,
            activity: .charging
        )
        expectTrue(decision.requiresWrite)
        expectEqual(decision.plan, .off)
    }

    test("a corridor that is off and asked to be off is left alone") {
        let decision = FirmwareLimitPolicy.decide(
            config: ChargeConfig(upperLimit: 100),
            observed: FirmwareLimitState(isActive: false, upper: 80, lower: 75),
            activity: .charging
        )
        expectFalse(decision.requiresWrite)
        expectEqual(decision.reason.code, "limitingDisabled")
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
