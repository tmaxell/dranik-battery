import DranikCore
import Foundation

/// Sleep is the hardest part of this to observe: it happens once a night, the
/// machine is not running while it matters, and the only evidence is a
/// percentage the next morning. So every combination is checked here instead.
func runSleepPolicyTests() {
    // MARK: - holdLimit

    test("holdLimit closes the gate whatever the level") {
        // Unconditional on purpose. The gate state survives sleep, so this is
        // what makes the limit hold overnight — and at a low level it costs
        // nothing that waking does not immediately undo.
        for percentage in [21, 50, 75, 79, 80, 100] {
            let config = ChargeConfig(upperLimit: 80, lowerLimit: 75, sleepPolicy: .holdLimit)
            expectEqual(
                SleepPolicyDecision.onWillSleep(config: config, percentage: percentage).position,
                .closed,
                "at \(percentage)%"
            )
        }
    }

    // MARK: - allowCharge

    test("allowCharge opens the gate whatever the level") {
        for percentage in [21, 50, 79, 100] {
            let config = ChargeConfig(upperLimit: 80, lowerLimit: 75, sleepPolicy: .allowCharge)
            expectEqual(
                SleepPolicyDecision.onWillSleep(config: config, percentage: percentage).position,
                .open,
                "at \(percentage)%"
            )
        }
    }

    // MARK: - chargeIfLow

    test("chargeIfLow opens below the resume point and closes above it") {
        let config = ChargeConfig(upperLimit: 80, lowerLimit: 75, sleepPolicy: .chargeIfLow)
        expectEqual(SleepPolicyDecision.onWillSleep(config: config, percentage: 40).position, .open)
        expectEqual(SleepPolicyDecision.onWillSleep(config: config, percentage: 74).position, .open)
        // At the resume point exactly: charging would resume anyway, so open.
        expectEqual(SleepPolicyDecision.onWillSleep(config: config, percentage: 75).position, .open)
        expectEqual(SleepPolicyDecision.onWillSleep(config: config, percentage: 76).position, .closed)
        expectEqual(SleepPolicyDecision.onWillSleep(config: config, percentage: 100).position, .closed)
    }

    test("chargeIfLow follows the configured resume point, not a fixed number") {
        let low = ChargeConfig(upperLimit: 60, lowerLimit: 50, sleepPolicy: .chargeIfLow)
        expectEqual(SleepPolicyDecision.onWillSleep(config: low, percentage: 50).position, .open)
        expectEqual(SleepPolicyDecision.onWillSleep(config: low, percentage: 55).position, .closed)
    }

    test("every transition explains itself") {
        // The morning after is the wrong time to be guessing why.
        for policy in [SleepPolicy.holdLimit, .allowCharge, .chargeIfLow] {
            let config = ChargeConfig(upperLimit: 80, lowerLimit: 75, sleepPolicy: policy)
            let transition = SleepPolicyDecision.onWillSleep(config: config, percentage: 60)
            expectFalse(transition.explanation.isEmpty, "\(policy)")
        }
    }

    // MARK: - Limiting off

    test("with limiting off, sleep touches nothing at all") {
        // Not "open it" — leave it. Nothing here should be writing to the SMC
        // on behalf of a feature its owner has turned off.
        for policy in [SleepPolicy.holdLimit, .allowCharge, .chargeIfLow] {
            let config = ChargeConfig(upperLimit: 100, sleepPolicy: policy)
            let transition = SleepPolicyDecision.onWillSleep(config: config, percentage: 50)
            expectNil(transition.position, "\(policy) should leave the gate alone")
        }
    }

    // MARK: - Idle sleep

    test("idle sleep is allowed unless the option is on") {
        let config = ChargeConfig(upperLimit: 80, lowerLimit: 75)
        expectFalse(config.preventIdleSleepWhileCharging, "must be off by default")
        expectFalse(SleepPolicyDecision.shouldPreventIdleSleep(
            config: config, isExternalConnected: true, percentage: 50
        ))
    }

    test("with the option on, idle sleep is held off only while charging up") {
        let config = ChargeConfig(
            upperLimit: 80, lowerLimit: 75, preventIdleSleepWhileCharging: true
        )
        expectTrue(SleepPolicyDecision.shouldPreventIdleSleep(
            config: config, isExternalConnected: true, percentage: 50
        ))
        // Reached the limit: nothing left to wait for.
        expectFalse(SleepPolicyDecision.shouldPreventIdleSleep(
            config: config, isExternalConnected: true, percentage: 80
        ))
        // On battery there is nothing to charge from.
        expectFalse(SleepPolicyDecision.shouldPreventIdleSleep(
            config: config, isExternalConnected: false, percentage: 50
        ))
        // And a machine with no limit has nothing to charge towards.
        expectFalse(SleepPolicyDecision.shouldPreventIdleSleep(
            config: ChargeConfig(upperLimit: 100, preventIdleSleepWhileCharging: true),
            isExternalConnected: true, percentage: 50
        ))
    }

    // MARK: - Round trip

    test("all three policies survive the configuration file") {
        for policy in [SleepPolicy.holdLimit, .allowCharge, .chargeIfLow] {
            let path = NSTemporaryDirectory() + "dranik-sleep-\(UUID().uuidString).json"
            defer { try? FileManager.default.removeItem(atPath: path) }
            try ConfigStore.save(
                ChargeConfig(upperLimit: 80, lowerLimit: 75, sleepPolicy: policy), to: path
            )
            expectEqual(ConfigStore.load(from: path).config.sleepPolicy, policy)
        }
    }

    test("the default is the one that always honours the stated limit") {
        // Whichever is most convenient, the default should be the one that does
        // what the limit says it does.
        expectEqual(ChargeConfig().sleepPolicy, .holdLimit)
    }
}
