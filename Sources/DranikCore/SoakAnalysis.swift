import Foundation

/// One line the daemon wrote to the unified log.
public struct DaemonLogRecord: Equatable, Sendable {
    public let timestamp: Date
    public let category: String
    public let message: String

    public init(timestamp: Date, category: String, message: String) {
        self.timestamp = timestamp
        self.category = category
        self.message = message
    }
}

/// Reads a stretch of the daemon's own log and says whether it behaved.
///
/// The alternative was reading three days of records by hand, which is how the
/// watchdog was found forcing the gate open after every sleep — twenty-five
/// times, invisible from any single moment's status. A limiter is a thing that
/// has to keep working, and "keeps working" is only visible over time.
///
/// Deliberately pure: it takes records rather than fetching them, so the
/// judgement can be checked against transcripts of things that actually
/// happened.
public struct SoakAnalysis: Equatable, Sendable {
    public var restarts = 0
    public var watchdogStalls = 0
    /// True when the daemon spent the window unable to limit anything.
    ///
    /// Without this the report read "nothing to report — the gate moved when it
    /// should" on a machine that has no gate, while the battery sat at 100 %
    /// for six weeks. Silence from a daemon with nothing to do is not health.
    public var limitingUnavailable = false
    /// True when the daemon spent the window handing the corridor to the
    /// firmware rather than driving a gate itself.
    ///
    /// Everything else here counts gate events, and on the firmware path there
    /// are none — no closures, no verifications, no watchdog. Without knowing
    /// which path was in force, a window of complete silence reads as "nothing
    /// happened" when in fact nothing *needed* to: the corridor was being held
    /// by the hardware the whole time. That is the healthy state, and it has to
    /// be told apart from a daemon that did nothing because it could not.
    public var firmwareLimiting = false
    /// Times the corridor was found saying something other than what was asked
    /// and had to be written again.
    ///
    /// Expected to be zero. The corridor held for 2 days 20 hours untouched when
    /// this was measured, so anything else means something other than this
    /// daemon is writing those keys.
    public var corridorRepairs = 0
    /// Times the firmware refused the corridor outright.
    public var corridorRefusals = 0
    /// Times the corridor could not be read, so whether the limit held was not
    /// knowable.
    public var corridorUnreadable = 0
    public var verificationFailures = 0
    /// Checks that confirmed the gate did what was asked.
    ///
    /// Counted so that failures can be read as a rate rather than a tally. Two
    /// failures out of two checks is a broken mechanism; two out of fifty is
    /// weather — and on 2026-08-19 nothing could tell the two apart, because
    /// confirmations were logged at `debug`, which is not persisted.
    public var verificationsConfirmed = 0
    public var distrusts = 0
    public var gateClosures = 0
    public var gateOpens = 0
    public var sleeps = 0
    public var wakes = 0
    public var unannouncedSleeps = 0
    public var writeFailures = 0
    public var firstAt: Date?
    public var lastAt: Date?

    public init() {}

    public static func analyse(_ records: [DaemonLogRecord]) -> SoakAnalysis {
        var result = SoakAnalysis()
        for record in records {
            if result.firstAt == nil { result.firstAt = record.timestamp }
            result.lastAt = record.timestamp

            let message = record.message
            // A dry run is somebody watching the daemon decide, not launchd
            // bringing the service back. Counting it produced "something else is
            // ending it" for every `make daemon-dry-run`.
            if message.contains("dranikd running") && !message.contains("DRY RUN") {
                result.restarts += 1
            }
            if message.contains("presumed stuck") { result.watchdogStalls += 1 }
            if message.contains("no charge-gate key") { result.limitingUnavailable = true }
            if message.contains("held by the firmware") { result.firmwareLimiting = true }
            if message.contains("putting it back") { result.corridorRepairs += 1 }
            if message.contains("the firmware refused the corridor") { result.corridorRefusals += 1 }
            if message.contains("firmware corridor could not be read") {
                result.corridorUnreadable += 1
            }
            if message.contains("gate check failed") { result.verificationFailures += 1 }
            if message.contains("gate verified") { result.verificationsConfirmed += 1 }
            if message.contains("charge limiting disabled") { result.distrusts += 1 }
            if message.contains("COULD NOT OPEN") || message.contains("not applied") {
                result.writeFailures += 1
            }
            if message.contains("sleeping:") { result.sleeps += 1 }
            if message.contains("woke —") { result.wakes += 1 }
            if message.contains("unannounced sleep") { result.unannouncedSleeps += 1 }
            // Gate movement, from the actuator's own record of what it wrote.
            if message.contains("-> 01000000") { result.gateClosures += 1 }
            if message.contains("-> 00000000") { result.gateOpens += 1 }
        }
        return result
    }

    public var duration: TimeInterval? {
        guard let firstAt, let lastAt else { return nil }
        return lastAt.timeIntervalSince(firstAt)
    }

    /// Something that should not have happened, in the order it matters.
    public struct Concern: Equatable, Sendable {
        public let severity: Severity
        public let text: String
        public enum Severity: String, Equatable, Sendable { case serious, worthNoting }
    }

    public var concerns: [Concern] {
        var found: [Concern] = []

        // First, because every verdict below is about how well some mechanism was
        // driven, and here there was none to drive.
        if limitingUnavailable && firmwareLimiting {
            // Both in one window means the mechanism changed part-way — a
            // firmware update, or an install picking up a build that recognises
            // the corridor. Saying "nothing was limited for any of this window"
            // would then be false for the half that was.
            found.append(Concern(
                severity: .worthNoting,
                text: """
                the mechanism changed during this window: part of it had no charge \
                gate at all, and part had the corridor held by the firmware. The \
                figures above mix the two — narrow the window to read either
                """
            ))
        } else if limitingUnavailable {
            found.append(Concern(
                severity: .serious,
                text: """
                no charge gate was recognised on this machine, so nothing was \
                being limited for any of this window — whatever the figures \
                above say
                """
            ))
        }

        if corridorRefusals > 0 {
            found.append(Concern(
                severity: .serious,
                text: """
                the firmware refused the charge corridor \(corridorRefusals) time(s) — \
                each one is a stretch with no limit in force
                """
            ))
        }

        if corridorUnreadable > 0 {
            found.append(Concern(
                severity: .worthNoting,
                text: """
                the corridor could not be read \(corridorUnreadable) time(s), so whether \
                the limit held then is not knowable from this window
                """
            ))
        }

        if corridorRepairs > 0 {
            // Not a failure of ours: the corridor was put back. But it should
            // never have moved, so a nonzero count means something else writes
            // these keys — worth knowing before trusting the mechanism further.
            found.append(Concern(
                severity: .worthNoting,
                text: """
                the corridor had to be written again \(corridorRepairs) time(s) — \
                it is meant to stay put, so something else is changing it
                """
            ))
        }

        if distrusts > 0 {
            found.append(Concern(
                severity: .serious,
                text: """
                the daemon stopped trusting the charge gate \(distrusts) time(s) — \
                after that it refuses to close it, so nothing is being limited
                """
            ))
        }

        if watchdogStalls > 0 {
            // The watchdog forces the gate open and exits, so every firing is a
            // window with no limit at all. One is a symptom; a pattern following
            // sleeps is the wall-clock bug that caused twenty-five of them.
            found.append(Concern(
                severity: .serious,
                text: """
                the watchdog fired \(watchdogStalls) time(s), each forcing the gate open \
                and restarting the daemon\(watchdogStalls >= wakes && wakes > 0
                    ? " — roughly once per wake, which is the shape of a clock bug"
                    : "")
                """
            ))
        }

        if writeFailures > 0 {
            found.append(Concern(
                severity: .serious,
                text: "\(writeFailures) gate write(s) did not take effect"
            ))
        }

        if verificationFailures > 0 {
            found.append(Concern(
                severity: .worthNoting,
                text: """
                \(verificationFailures) of \(verificationFailures + verificationsConfirmed) \
                verification(s) contradicted a write. It takes two close together to \
                disable limiting — but a rising share means the check is too tight
                """
            ))
        }

        // Restarts beyond the first are launchd bringing the daemon back, which
        // it only does after a non-zero exit.
        if restarts > 1 && watchdogStalls == 0 {
            found.append(Concern(
                severity: .worthNoting,
                text: "the daemon started \(restarts) times with no watchdog firing — something else is ending it"
            ))
        }

        return found
    }

    public var isHealthy: Bool {
        concerns.allSatisfy { $0.severity != .serious }
    }
}
