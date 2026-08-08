import DranikCore
import Foundation

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func input(
    _ percentage: Int,
    onAC: Bool = true,
    temperature: Double = 30,
    age: TimeInterval = 0
) -> ControllerInput {
    ControllerInput(
        percentage: percentage,
        isExternalConnected: onAC,
        temperature: temperature,
        observedAt: epoch,
        now: epoch.addingTimeInterval(age)
    )
}

private func settled(_ gate: GatePosition, thermallyHeld: Bool = false) -> ControllerState {
    ControllerState(gate: gate, isThermallyHeld: thermallyHeld, hasDecided: true)
}

func runChargeConfigTests() {
    test("defaults are the documented ones") {
        let config = ChargeConfig()
        expectEqual(config.upperLimit, 80)
        expectEqual(config.lowerLimit, 75)
        expectEqual(config.thermalCutoff, 40.0)
        expectTrue(config.corrections.isEmpty)
    }

    test("an absurd upper limit is replaced, not honoured") {
        // The failure this prevents is a laptop that refuses to charge past 3 %.
        for absurd in [3, 0, -10, 49, 101, 1000] {
            let config = ChargeConfig(upperLimit: absurd)
            expectEqual(config.upperLimit, 80, "upper \(absurd)")
            expectFalse(config.corrections.isEmpty, "upper \(absurd) should be reported")
        }
    }

    test("upper limits at the edges of the allowed range are kept") {
        expectEqual(ChargeConfig(upperLimit: 50).upperLimit, 50)
        expectEqual(ChargeConfig(upperLimit: 100).upperLimit, 100)
    }

    test("the lower limit is forced below the upper one") {
        // A band that is not a band would make the gate flap on every reading.
        let config = ChargeConfig(upperLimit: 80, lowerLimit: 95)
        expectTrue(config.lowerLimit < config.upperLimit)
        expectFalse(config.corrections.isEmpty)

        expectEqual(ChargeConfig(upperLimit: 80, lowerLimit: 79).lowerLimit, 75)
        expectEqual(ChargeConfig(upperLimit: 80, lowerLimit: 10).lowerLimit, 75)
        expectEqual(ChargeConfig(upperLimit: 80, lowerLimit: 60).lowerLimit, 60)
    }

    test("a tight but legal band is respected") {
        let config = ChargeConfig(upperLimit: 60, lowerLimit: 58)
        expectEqual(config.lowerLimit, 58)
        expectTrue(config.corrections.isEmpty)
    }

    test("thermal cutoff is clamped") {
        expectEqual(ChargeConfig(thermalCutoff: 5).thermalCutoff, 40.0)
        expectEqual(ChargeConfig(thermalCutoff: 200).thermalCutoff, 40.0)
        expectEqual(ChargeConfig(thermalCutoff: 35).thermalCutoff, 35.0)
    }

    test("100 means limiting is off") {
        expectTrue(ChargeConfig(upperLimit: 100).isLimitingDisabled)
        expectFalse(ChargeConfig(upperLimit: 99).isLimitingDisabled)
    }
}

func runChargeControllerTests() {
    let config = ChargeConfig(upperLimit: 80, lowerLimit: 75)

    func decide(
        _ in_: ControllerInput,
        _ state: ControllerState = ControllerState(),
        config configOverride: ChargeConfig? = nil
    ) -> (decision: ChargeDecision, state: ControllerState) {
        ChargeController.decide(input: in_, config: configOverride ?? config, state: state)
    }

    // MARK: - The two rules above all others

    test("a stale reading opens the gate") {
        // An old reading is indistinguishable from no reading. Holding the gate
        // shut on one is exactly how a machine ends up not charging.
        let result = decide(input(90, age: 120), settled(.closed))
        expectEqual(result.decision.position, .open)
        expectEqual(result.decision.reason, .staleReading(120))
        expectTrue(result.decision.requiresWrite)
    }

    test("a fresh reading is trusted right up to the limit") {
        let result = decide(input(90, age: 89), settled(.closed))
        expectEqual(result.decision.position, .closed)
    }

    test("the emergency floor beats the charge limit") {
        let result = decide(input(15), settled(.closed))
        expectEqual(result.decision.position, .open)
        expectEqual(result.decision.reason, .emergencyFloor(percentage: 15))
    }

    test("the emergency floor beats a thermal hold") {
        // A hot battery is a problem. A flat laptop that will not charge is worse.
        let result = decide(input(15, temperature: 55), settled(.closed, thermallyHeld: true))
        expectEqual(result.decision.position, .open)
        expectEqual(result.decision.reason, .emergencyFloor(percentage: 15))
        expectFalse(result.state.isThermallyHeld, "the hold must be released, not merely bypassed")
    }

    test("the floor releases exactly at 20") {
        // Isolated on battery, where every other rule says "closed" — otherwise
        // the ordinary lower-limit rule opens the gate too and proves nothing.
        expectEqual(decide(input(19, onAC: false), settled(.closed)).decision.position, .open)
        expectEqual(decide(input(20, onAC: false), settled(.closed)).decision.position, .closed)
    }

    // MARK: - Hysteresis

    test("charging stops on reaching the upper limit") {
        let result = decide(input(80), settled(.open))
        expectEqual(result.decision.position, .closed)
        expectEqual(result.decision.reason, .reachedUpper(percentage: 80, upper: 80))
        expectTrue(result.decision.requiresWrite)
    }

    test("charging resumes on falling to the lower limit") {
        let result = decide(input(75), settled(.closed))
        expectEqual(result.decision.position, .open)
        expectEqual(result.decision.reason, .fellToLower(percentage: 75, lower: 75))
    }

    test("inside the band the gate does not move") {
        // This is the whole point of the band: no write, either way.
        let held = decide(input(78), settled(.closed))
        expectEqual(held.decision.position, .closed)
        expectFalse(held.decision.requiresWrite)

        let charging = decide(input(78), settled(.open))
        expectEqual(charging.decision.position, .open)
        expectFalse(charging.decision.requiresWrite)
    }

    test("a full charge-and-hold cycle does not flap") {
        var state = ControllerState()
        var writes = 0
        // Climb 70 → 82, drift back to 74, climb again.
        let track = Array(70...82) + Array((74...81).reversed()) + Array(75...82)
        for percentage in track {
            let result = decide(input(percentage), state)
            if result.decision.requiresWrite { writes += 1 }
            state = result.state
        }
        // Open at 70, shut at 80, open at 74, shut at 80 again. Anything more
        // means the band is not doing its job.
        expectEqual(writes, 4, "gate moved more often than the band allows")
    }

    // MARK: - First decision

    test("the first decision inside the band charges up rather than stalling") {
        // On boot the SMC is back to its default, so the gate is open and the
        // battery has already been charging. Holding here would strand it
        // mid-band, never reaching the limit that was asked for.
        let result = decide(input(78), ControllerState())
        expectEqual(result.decision.position, .open)
        expectEqual(result.decision.reason, .initialTopUp(percentage: 78, upper: 80))
    }

    test("the first decision still respects the upper limit") {
        let result = decide(input(85), ControllerState())
        expectEqual(result.decision.position, .closed)
        expectEqual(result.decision.reason, .reachedUpper(percentage: 85, upper: 80))
    }

    test("an unknown gate position inside the band charges up") {
        // Reconciliation on start: hasDecided is set but the SMC was unreadable.
        let unknown = ControllerState(gate: nil, isThermallyHeld: false, hasDecided: true)
        expectEqual(decide(input(78), unknown).decision.position, .open)
    }

    // MARK: - Adapter

    test("the gate is held shut on battery") {
        // So that plugging in cannot start a burst of charging before the
        // controller has had a chance to decide.
        let result = decide(input(50, onAC: false), settled(.open))
        expectEqual(result.decision.position, .closed)
        expectEqual(result.decision.reason, .onBattery)
    }

    test("on battery below the floor the gate still opens") {
        let result = decide(input(10, onAC: false), settled(.closed))
        expectEqual(result.decision.position, .open)
    }

    test("plugging in below the band resumes charging immediately") {
        let onBattery = decide(input(60, onAC: false), settled(.open))
        expectEqual(onBattery.decision.position, .closed)

        let pluggedIn = decide(input(60, onAC: true), onBattery.state)
        expectEqual(pluggedIn.decision.position, .open)
        expectEqual(pluggedIn.decision.reason, .fellToLower(percentage: 60, lower: 75))
    }

    // MARK: - Thermal

    test("charging stops above the cutoff") {
        let result = decide(input(60, temperature: 45), settled(.open))
        expectEqual(result.decision.position, .closed)
        expectEqual(result.decision.reason, .tooHot(temperature: 45, cutoff: 40))
        expectTrue(result.state.isThermallyHeld)
    }

    test("the thermal hold outlasts the threshold it was set at") {
        // Releasing the instant the reading dips below the cutoff would chatter.
        let hot = decide(input(60, temperature: 45), settled(.open))
        let barelyCooler = decide(input(60, temperature: 39.5), hot.state)
        expectEqual(barelyCooler.decision.position, .closed)
        expectEqual(barelyCooler.decision.reason, .coolingDown(temperature: 39.5, recoversAt: 38))
        expectTrue(barelyCooler.state.isThermallyHeld)
    }

    test("the thermal hold releases once properly cool") {
        let hot = decide(input(60, temperature: 45), settled(.open))
        let cool = decide(input(60, temperature: 37), hot.state)
        expectFalse(cool.state.isThermallyHeld)
        expectEqual(cool.decision.position, .open)
    }

    test("a battery cooling off on battery power still clears the hold") {
        // Otherwise unplugging while hot would leave the flag set indefinitely
        // and the next plug-in would refuse to charge for no reason.
        let hot = decide(input(60, temperature: 45), settled(.open))
        let unplugged = decide(input(60, onAC: false, temperature: 30), hot.state)
        expectFalse(unplugged.state.isThermallyHeld)
        expectEqual(unplugged.decision.position, .closed, "on battery the gate stays shut")

        let pluggedIn = decide(input(60, temperature: 30), unplugged.state)
        expectEqual(pluggedIn.decision.position, .open)
    }

    test("heat beats the charge limit but not the floor") {
        let hot = decide(input(60, temperature: 45), settled(.open))
        expectEqual(hot.decision.position, .closed)
        let hotAndFlat = decide(input(10, temperature: 45), settled(.open))
        expectEqual(hotAndFlat.decision.position, .open)
    }

    // MARK: - Limiting disabled

    test("a limit of 100 opens the gate and keeps it open") {
        let unlimited = ChargeConfig(upperLimit: 100)
        let result = decide(input(99), settled(.closed), config: unlimited)
        expectEqual(result.decision.position, .open)
        expectEqual(result.decision.reason, .limitingDisabled)
        expectTrue(result.decision.requiresWrite)
    }

    test("a limit of 100 does not override heat or the adapter") {
        let unlimited = ChargeConfig(upperLimit: 100)
        expectEqual(
            decide(input(99, temperature: 45), settled(.open), config: unlimited).decision.position,
            .closed
        )
        expectEqual(
            decide(input(99, onAC: false), settled(.open), config: unlimited).decision.position,
            .closed
        )
    }

    // MARK: - Bookkeeping

    test("the decision records where the gate now is") {
        let result = decide(input(80), settled(.open))
        expectEqual(result.state.gate, .closed)
        expectTrue(result.state.hasDecided)
    }

    test("no write is asked for when the gate is already right") {
        expectFalse(decide(input(80), settled(.closed)).decision.requiresWrite)
        expectFalse(decide(input(60), settled(.open)).decision.requiresWrite)
    }

    test("every reachable percentage yields a decision, and low ones open") {
        // A blunt sweep: the branch that strands a battery is the untested one.
        for percentage in 0...100 {
            for onAC in [true, false] {
                for temperature in [20.0, 45.0] {
                    for gate in [GatePosition.open, .closed] {
                        let result = decide(
                            input(percentage, onAC: onAC, temperature: temperature),
                            settled(gate)
                        )
                        if percentage < ChargeConfig.emergencyFloor {
                            expectEqual(
                                result.decision.position, .open,
                                "\(percentage)% onAC=\(onAC) \(temperature)°C must charge"
                            )
                        }
                    }
                }
            }
        }
    }
}
