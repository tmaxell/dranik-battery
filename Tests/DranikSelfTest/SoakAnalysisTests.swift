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

/// Failures are only meaningful against the checks that passed.
func runSoakRatioTests() {
    test("passed checks are counted, not just failed ones") {
        let records = [
            DaemonLogRecord(timestamp: Date(), category: "Gate", message: "gate verified closed"),
            DaemonLogRecord(timestamp: Date(), category: "Gate", message: "gate verified open"),
            DaemonLogRecord(
                timestamp: Date(), category: "Gate",
                message: "gate check failed (1): gate set closed but the charger is not inhibited"
            ),
        ]
        let analysis = SoakAnalysis.analyse(records)
        expectEqual(analysis.verificationsConfirmed, 2)
        expectEqual(analysis.verificationFailures, 1)
        // The point of counting both: this reads as weather, not a broken gate.
        expectTrue(
            analysis.concerns.allSatisfy { $0.severity != .serious },
            "one failure among three checks is not serious"
        )
    }
}

/// `soak` handed out a clean bill of health to a machine that had not limited
/// anything for six weeks: "nothing to report — the gate moved when it should",
/// on hardware with no gate at all.
func runSoakLimitingTests() {
    test("a window where nothing could be limited is not a healthy window") {
        let records = [
            DaemonLogRecord(
                timestamp: Date(), category: "Daemon",
                message: "no charge-gate key on this machine matched its expected description."
                    + " Nothing here can limit charging, and nothing will be written."
            ),
        ]
        let analysis = SoakAnalysis.analyse(records)
        expectTrue(analysis.limitingUnavailable)
        expectFalse(analysis.isHealthy, "no gate means no verdict about the gate")
        expectTrue(
            analysis.concerns.contains { $0.severity == .serious },
            "and it is serious: the battery is unprotected"
        )
    }

    test("the gate figures stay quiet about a window with no gate") {
        // Zero movements used to read as "it moved when it should". The concern
        // has to come first so the zeros are never the whole story.
        let records = [
            DaemonLogRecord(
                timestamp: Date(), category: "Daemon",
                message: "no charge-gate key on this machine"
            ),
        ]
        let analysis = SoakAnalysis.analyse(records)
        expectEqual(analysis.gateClosures, 0)
        expectEqual(analysis.gateOpens, 0)
        expectFalse(analysis.concerns.isEmpty, "zeros must not be reported as calm")
    }

    test("an ordinary window is still healthy") {
        let records = [
            DaemonLogRecord(timestamp: Date(), category: "Gate", message: "gate verified closed"),
            DaemonLogRecord(timestamp: Date(), category: "SMC", message: "SMC write CHTE: 00000000 -> 01000000"),
        ]
        let analysis = SoakAnalysis.analyse(records)
        expectFalse(analysis.limitingUnavailable)
        expectTrue(analysis.isHealthy)
    }
}

func runSoakFirmwareTests() {
    /// The one line the firmware path writes when it starts, as the daemon
    /// actually writes it.
    let banner = DaemonLogRecord(
        timestamp: Date(), category: "Daemon",
        message: "dranikd running, limit 75–80%, held by the firmware via bfF0+bfD0+bfE0"
    )

    test("a quiet firmware window is recognised as the firmware path, not as idleness") {
        // Everything else this analysis counts is a gate event, and the firmware
        // path produces none. Without knowing which path was in force, silence
        // would read as "nothing happened" on a machine where the hardware was
        // holding the limit the entire time.
        let analysis = SoakAnalysis.analyse([banner])
        expectTrue(analysis.firmwareLimiting)
        expectFalse(analysis.limitingUnavailable, "the firmware path is not an absent one")
        expectTrue(analysis.isHealthy)
        expectEqual(analysis.gateClosures, 0)
        expectEqual(analysis.verificationsConfirmed, 0)
    }

    test("a firmware that refuses the corridor is serious") {
        let analysis = SoakAnalysis.analyse([
            banner,
            DaemonLogRecord(
                timestamp: Date(), category: "Daemon",
                message: "the firmware refused the corridor — charging is not being limited"
            ),
        ])
        expectEqual(analysis.corridorRefusals, 1)
        expectFalse(analysis.isHealthy)
        expectTrue(analysis.concerns.contains { $0.severity == .serious })
    }

    test("a corridor that had to be rewritten is worth noting") {
        // It is meant to stay put: it held for 2 days 20 hours untouched when
        // measured. A repair means something else writes those keys, which is
        // worth knowing before trusting the mechanism further.
        let analysis = SoakAnalysis.analyse([
            banner,
            DaemonLogRecord(
                timestamp: Date(), category: "Daemon",
                message: "firmware corridor is off, not the 75–80% asked for — putting it back"
            ),
        ])
        expectEqual(analysis.corridorRepairs, 1)
        expectTrue(analysis.isHealthy, "it was repaired, so the limit held")
        expectTrue(analysis.concerns.contains { $0.severity == .worthNoting })
    }

    test("a corridor that could not be read is reported rather than assumed well") {
        let analysis = SoakAnalysis.analyse([
            banner,
            DaemonLogRecord(
                timestamp: Date(), category: "FirmwareLimit",
                message: "firmware corridor could not be read"
            ),
        ])
        expectEqual(analysis.corridorUnreadable, 1)
        expectFalse(analysis.concerns.isEmpty)
    }

    test("a window spanning both mechanisms says so instead of condemning all of it") {
        // What a real window looks like across an install that starts
        // recognising the corridor: the old daemon logging no gate, the new one
        // logging the firmware. "Nothing was limited for any of this window" is
        // false for the half that was.
        let analysis = SoakAnalysis.analyse([
            DaemonLogRecord(
                timestamp: Date(), category: "Daemon",
                message: "no charge-gate key on this machine matched its expected description."
            ),
            banner,
        ])
        expectTrue(analysis.limitingUnavailable)
        expectTrue(analysis.firmwareLimiting)
        expectTrue(analysis.isHealthy, "a change of mechanism is not a failure")
        expectTrue(analysis.concerns.contains { $0.text.contains("mechanism changed") })
    }

    test("an observing daemon's starts are counted too") {
        // They were not, because the observing path logged no banner. A daemon
        // restarting in a loop with nothing to limit then showed zero starts —
        // the shape of 2026-10-12, invisible to the tool meant to catch it.
        let analysis = SoakAnalysis.analyse([
            DaemonLogRecord(
                timestamp: Date(), category: "Daemon",
                message: "dranikd running, limit 75–80%, observing only"
            ),
            DaemonLogRecord(
                timestamp: Date(), category: "Daemon",
                message: "dranikd running, limit 75–80%, observing only"
            ),
            DaemonLogRecord(
                timestamp: Date(), category: "Daemon",
                message: "no charge-gate key on this machine matched its expected description."
            ),
        ])
        expectEqual(analysis.restarts, 2)
        expectTrue(analysis.limitingUnavailable)
        expectFalse(analysis.firmwareLimiting)
        expectFalse(analysis.isHealthy)
    }

    test("a dry run is not counted as the service restarting") {
        // `make daemon-dry-run` used to add a restart each time, which then read
        // as "something else is ending it".
        let analysis = SoakAnalysis.analyse([
            banner,
            DaemonLogRecord(
                timestamp: Date(), category: "Daemon",
                message: "dranikd running (DRY RUN — no SMC writes), limit 75–80%,"
                    + " held by the firmware via bfF0+bfD0+bfE0"
            ),
        ])
        expectEqual(analysis.restarts, 1, "only the real one counts")
        expectTrue(analysis.isHealthy)
    }

    test("gate records and firmware records do not count as each other") {
        let analysis = SoakAnalysis.analyse([
            DaemonLogRecord(
                timestamp: Date(), category: "Daemon",
                message: "dranikd running, limit 75–80%, gate CHTE"
            ),
            DaemonLogRecord(timestamp: Date(), category: "Gate", message: "gate verified closed"),
        ])
        expectFalse(analysis.firmwareLimiting)
        expectEqual(analysis.corridorRepairs, 0)
        expectEqual(analysis.verificationsConfirmed, 1)
    }
}
