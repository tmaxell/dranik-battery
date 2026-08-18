import DranikCore
import Foundation

func runSleepDetectorTests() {
    test("no sleep between samples") {
        // Both clocks advanced together: the machine was awake throughout.
        var detector = SleepDetector(includingSleep: 100, excludingSleep: 100)
        expectNil(detector.sample(includingSleep: 105, excludingSleep: 105))
    }

    test("sleep shows up as the gap between the two clocks") {
        var detector = SleepDetector(includingSleep: 100, excludingSleep: 100)
        // One second of running, 3600 of wall time: an hour asleep.
        let slept = detector.sample(includingSleep: 3701, excludingSleep: 101)
        expectEqual(slept, 3600)
    }

    test("small discrepancies are noise, not sleep") {
        // Scheduling jitter must not be reported as a wake-up, or the test would
        // read the gate at a moment that proves nothing.
        var detector = SleepDetector(includingSleep: 100, excludingSleep: 100)
        expectNil(detector.sample(includingSleep: 101.5, excludingSleep: 101.0))
        expectNil(detector.sample(includingSleep: 103.4, excludingSleep: 103.0))
    }

    test("the threshold is where it says it is") {
        var below = SleepDetector(includingSleep: 0, excludingSleep: 0)
        expectNil(below.sample(includingSleep: 1.99, excludingSleep: 0))

        var atThreshold = SleepDetector(includingSleep: 0, excludingSleep: 0)
        expectEqual(atThreshold.sample(includingSleep: 2.0, excludingSleep: 0), 2.0)
    }

    test("each sample is measured against the previous one, not the start") {
        var detector = SleepDetector(includingSleep: 0, excludingSleep: 0)
        expectEqual(detector.sample(includingSleep: 100, excludingSleep: 10), 90)
        // Awake again: the earlier sleep must not be reported a second time.
        expectNil(detector.sample(includingSleep: 101, excludingSleep: 11))
        expectEqual(detector.sample(includingSleep: 201, excludingSleep: 12), 99)
    }

    test("the real clocks behave the way the detector assumes") {
        // Both must advance while awake, and CLOCK_UPTIME_RAW must not run ahead
        // of the clock that also counts sleep.
        let firstIncluding = Clocks.includingSleep()
        let firstExcluding = Clocks.excludingSleep()
        Thread.sleep(forTimeInterval: 0.05)
        let secondIncluding = Clocks.includingSleep()
        let secondExcluding = Clocks.excludingSleep()

        expectTrue(secondIncluding > firstIncluding, "including-sleep clock did not advance")
        expectTrue(secondExcluding > firstExcluding, "excluding-sleep clock did not advance")

        let including = secondIncluding - firstIncluding
        let excluding = secondExcluding - firstExcluding
        expectTrue(
            excluding <= including + 0.01,
            "the excluding-sleep clock ran ahead — the detector's premise is wrong"
        )

        // And no sleep is detected across a plain pause.
        var detector = SleepDetector(includingSleep: firstIncluding, excludingSleep: firstExcluding)
        expectNil(detector.sample(includingSleep: secondIncluding, excludingSleep: secondExcluding))
    }
}
