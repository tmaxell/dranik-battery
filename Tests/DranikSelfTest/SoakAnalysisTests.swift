import DranikCore
import Foundation

private func record(_ message: String, at offset: TimeInterval = 0) -> DaemonLogRecord {
    DaemonLogRecord(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000 + offset),
        category: "Daemon", message: message
    )
}

func runSoakAnalysisTests() {
    test("a quiet stretch reports nothing") {
        let analysis = SoakAnalysis.analyse([
            record("dranikd running, limit 75–80%, gate CHTE"),
            record("CHTE -> 01000000 (closed, charge 80% reached the 80% limit)", at: 60),
            record("gate verified closed", at: 80),
        ])
        expectTrue(analysis.concerns.isEmpty, "\(analysis.concerns)")
        expectTrue(analysis.isHealthy)
        expectEqual(analysis.gateClosures, 1)
    }

    test("the watchdog firing is serious, because each one lifts the limit") {
        let analysis = SoakAnalysis.analyse([
            record("controller has not made a decision in 9020s — presumed stuck"),
            record("watchdog opened CHTE", at: 1),
        ])
        expectEqual(analysis.watchdogStalls, 1)
        expectFalse(analysis.isHealthy)
        expectTrue(analysis.concerns.contains { $0.severity == .serious })
    }

    test("watchdog firings tracking wakes are named as a clock bug") {
        // The real transcript: twenty-five firings, one per wake. That pattern
        // is what distinguishes a genuine wedge from time being measured on the
        // wrong clock, and saying so is the difference between a number and a
        // diagnosis.
        var records: [DaemonLogRecord] = []
        for index in 0..<5 {
            records.append(record("woke — settling for 30s", at: Double(index) * 100))
            records.append(record("controller has not made a decision in 6000s — presumed stuck",
                                  at: Double(index) * 100 + 1))
        }
        let analysis = SoakAnalysis.analyse(records)
        let text = analysis.concerns.map(\.text).joined()
        expectTrue(text.contains("clock bug"), "should recognise the pattern: \(text)")
    }

    test("losing trust in the gate is the most serious finding") {
        let analysis = SoakAnalysis.analyse([
            record("gate check failed (1): gate set closed but the charger is not inhibited"),
            record("gate check failed (2): gate set closed but the charger is not inhibited", at: 45),
            record("charge limiting disabled, opening the gate", at: 46),
        ])
        expectEqual(analysis.distrusts, 1)
        expectFalse(analysis.isHealthy)
        expectTrue(analysis.concerns.first?.text.contains("nothing is being limited") == true)
    }

    test("isolated failed checks are noted but not called failures") {
        // Four of these over three days did not disable anything, because it
        // takes two in a row. Reporting them as a failure would be crying wolf;
        // not reporting them would hide a window that is getting too tight.
        let analysis = SoakAnalysis.analyse([
            record("gate check failed (1): gate set open but the charger is still inhibited"),
        ])
        expectEqual(analysis.verificationFailures, 1)
        expectTrue(analysis.isHealthy, "one failed check must not read as broken")
        expectEqual(analysis.concerns.count, 1)
        expectEqual(analysis.concerns.first?.severity, .worthNoting)
    }

    test("restarts with no watchdog firing point elsewhere") {
        let analysis = SoakAnalysis.analyse([
            record("dranikd running, limit 75–80%, gate CHTE"),
            record("dranikd running, limit 75–80%, gate CHTE", at: 600),
            record("dranikd running, limit 75–80%, gate CHTE", at: 1200),
        ])
        expectEqual(analysis.restarts, 3)
        expectTrue(analysis.concerns.contains { $0.text.contains("something else is ending it") })
    }

    test("a single start is not a restart problem") {
        let analysis = SoakAnalysis.analyse([record("dranikd running, limit 75–80%, gate CHTE")])
        expectTrue(analysis.concerns.isEmpty)
    }

    test("unannounced sleeps are counted but are not a fault") {
        // macOS does not always send the notification; catching it anyway is the
        // detector working, not a problem.
        let analysis = SoakAnalysis.analyse([
            record("detected 4107s of unannounced sleep"),
            record("woke — settling for 30s", at: 1),
        ])
        expectEqual(analysis.unannouncedSleeps, 1)
        expectTrue(analysis.isHealthy)
    }

    test("the span covered is reported from the records themselves") {
        let analysis = SoakAnalysis.analyse([
            record("dranikd running", at: 0),
            record("woke — settling for 30s", at: 7200),
        ])
        expectEqual(analysis.duration, 7200)
    }

    test("an empty stretch yields no findings and no false confidence") {
        let analysis = SoakAnalysis.analyse([])
        expectNil(analysis.duration)
        expectTrue(analysis.concerns.isEmpty)
    }
}
