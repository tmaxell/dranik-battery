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
        notChargingReason: .none,
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

    test("reported percentage is in the same league as raw capacity") {
        let snapshot = try snapshot()

        // The tolerance is deliberately wide. The reported percentage is not a
        // ratio of any capacity pair macOS exposes: measured against
        // AppleRawCurrentCapacity/AppleRawMaxCapacity the offset was +1.0 points
        // on one reading and +5.1 on another, and the other denominators are
        // further off still (NominalChargeCapacity +7.4, DesignCapacity +11.4).
        // macOS applies its own smoothing, and the gap moves with charge history.
        //
        // So this cannot assert agreement — only that the two are the same kind
        // of quantity. That is still worth checking: reading the wrong field or
        // mistaking mAh for percent lands orders of magnitude away, not points.
        let derived = Double(snapshot.rawCurrentCapacity) / Double(snapshot.rawMaxCapacity) * 100
        expectClose(derived, Double(snapshot.percentage), accuracy: 20.0)
    }

    test("charging implies external power") {
        let snapshot = try snapshot()
        if snapshot.isCharging {
            expectTrue(snapshot.isExternalConnected)
        }
    }
}
