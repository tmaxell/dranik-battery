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
            if message.contains("dranikd running") { result.restarts += 1 }
            if message.contains("presumed stuck") { result.watchdogStalls += 1 }
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
