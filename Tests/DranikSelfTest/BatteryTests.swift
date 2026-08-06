import DranikPower
import Foundation

/// Values captured from the target machine, so `healthFraction` is pinned to a
/// figure that was cross-checked by hand: 4670 / 5103 = 91.5 %.
private func makeSnapshot(
    percentage: Int = 91,
    rawMaxCapacity: Int = 4670,
    designCapacity: Int = 5103,
    voltage: Int = 12897,
    amperage: Int = 1167
) -> BatterySnapshot {
    BatterySnapshot(
        percentage: percentage,
        isCharging: true,
        isExternalConnected: true,
        isFullyCharged: false,
        rawCurrentCapacity: 4204,
        rawMaxCapacity: rawMaxCapacity,
        designCapacity: designCapacity,
        cycleCount: 170,
        temperature: 30.43,
        voltage: voltage,
        amperage: amperage,
        timeRemaining: 42,
        notChargingReason: 0,
        chargerInhibitReason: 0,
        chargingCurrent: 1153,
        chargingVoltage: 4320
    )
}

func runBatterySnapshotTests() {
    test("health uses raw capacity, not the normalised MaxCapacity") {
        let health = try expectNotNil(makeSnapshot().healthFraction)
        expectClose(health, 0.915, accuracy: 0.001)
    }

    test("health is nil without a design capacity") {
        // Better to report nothing than to fabricate a plausible 100 %.
        expectNil(makeSnapshot(designCapacity: 0).healthFraction)
    }

    test("power is positive while charging") {
        expectClose(makeSnapshot().powerWatts, 15.05, accuracy: 0.01)
    }

    test("power is negative while discharging") {
        expectClose(makeSnapshot(amperage: -1500).powerWatts, -19.35, accuracy: 0.01)
    }
}

func runLivePowerReaderTests() {
    func snapshot() throws -> BatterySnapshot {
        do {
            return try PowerReader.snapshot()
        } catch {
            try skip("AppleSmartBattery unavailable: \(error)")
        }
    }

    test("live snapshot is internally consistent") {
        let snapshot = try snapshot()

        expectInRange(snapshot.percentage, 0...100)
        expectTrue(snapshot.designCapacity > 0, "design capacity")
        expectTrue(snapshot.rawMaxCapacity > 0, "raw max capacity")
        expectTrue(snapshot.voltage > 0, "voltage")
        expectTrue(snapshot.cycleCount >= 0, "cycle count")

        let health = try expectNotNil(snapshot.healthFraction)
        expectInRange(health, 0.3...1.2, "implausible health")

        // A temperature well outside this range means the scaling is wrong.
        expectInRange(snapshot.temperature, 0.0...60.0, "implausible temperature")

        expectTrue(
            snapshot.rawCurrentCapacity <= snapshot.rawMaxCapacity,
            "present capacity exceeds full-charge capacity"
        )
    }

    test("reported percentage tracks raw capacity below the smoothed top") {
        let snapshot = try snapshot()

        // macOS smooths the reported percentage near the top of the range: it was
        // observed reporting 100 against a raw 4465/4718 = 94.6 %, with
        // isFullyCharged already back to false — so no flag predicts it. Below
        // that region the two track closely, and checking there still catches a
        // gross unit or field mix-up.
        guard snapshot.percentage < 95 else {
            try skip("battery is in the smoothed top-of-charge region (\(snapshot.percentage) %)")
        }

        let derived = Double(snapshot.rawCurrentCapacity) / Double(snapshot.rawMaxCapacity) * 100
        expectClose(derived, Double(snapshot.percentage), accuracy: 3.0)
    }

    test("charging implies external power") {
        let snapshot = try snapshot()
        if snapshot.isCharging {
            expectTrue(snapshot.isExternalConnected)
        }
    }
}
