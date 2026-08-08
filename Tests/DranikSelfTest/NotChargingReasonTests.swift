import DranikPower
import DranikSMC
import Foundation

/// The two values in here are not invented: both were read off the target
/// machine, one while running on battery and one while the charge gate was
/// closed by `dranik-gate-experiment`.
func runNotChargingReasonTests() {
    test("the value seen while the gate was closed decodes to inhibited") {
        // 36028797018963968 == 1 << 55, observed for exactly as long as CHTE
        // held 01 00 00 00, and gone the moment it was restored.
        let reason = NotChargingReason(36_028_797_018_963_968)
        expectTrue(reason.contains(.inhibited))
        expectFalse(reason.contains(.onBattery))
        expectEqual(reason.unrecognisedBits, 0)
        expectEqual(reason.description, "inhibited")
    }

    test("the value seen on battery decodes to onBattery") {
        // 128 == 1 << 7, observed with no charger attached.
        let reason = NotChargingReason(128)
        expectTrue(reason.contains(.onBattery))
        expectFalse(reason.contains(.inhibited))
        expectEqual(reason.unrecognisedBits, 0)
        expectEqual(reason.description, "onBattery")
    }

    test("onBattery alone is not evidence the gate is holding") {
        // The distinction this whole type exists for. A plain non-zero test
        // would have called this a successful gate close.
        expectFalse(NotChargingReason(128).contains(.inhibited))
    }

    test("zero means charging is unobstructed") {
        expectTrue(NotChargingReason(0).isEmpty)
        expectEqual(NotChargingReason(0).description, "none")
        expectFalse(NotChargingReason(0).contains(.inhibited))
    }

    test("bits are combined, not exclusive") {
        let both = NotChargingReason(rawValue: (1 << 7) | (1 << 55))
        expectTrue(both.contains(.onBattery))
        expectTrue(both.contains(.inhibited))
        expectEqual(both.description, "onBattery+inhibited")
    }

    test("unknown bits are surfaced, not silently dropped") {
        // A firmware revision setting a bit this project has never seen must not
        // read as "no reason at all".
        let reason = NotChargingReason(rawValue: (1 << 55) | (1 << 3))
        expectTrue(reason.contains(.inhibited))
        expectEqual(reason.unrecognisedBits, 1 << 3)
        expectEqual(reason.description, "inhibited+unknown(bits 3)")
    }

    test("gate timings reflect what was measured, not what was assumed") {
        // Charging carried on for six seconds after the gate was closed and only
        // stopped at the seventh, so nothing may conclude failure sooner.
        expectTrue(ChargeGateTiming.observedEffectLatency >= 7)
        expectTrue(
            ChargeGateTiming.verificationWindow > ChargeGateTiming.observedEffectLatency,
            "the verification window must outlast the latency it exists to tolerate"
        )
    }
}
