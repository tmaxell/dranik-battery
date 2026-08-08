import Foundation

/// Two clocks that differ in exactly one respect.
public enum Clocks {
    /// Seconds since an arbitrary point, **including** time spent asleep.
    public static func includingSleep() -> TimeInterval {
        seconds(CLOCK_MONOTONIC)
    }

    /// Seconds since an arbitrary point, **excluding** time spent asleep.
    ///
    /// `CLOCK_UPTIME_RAW` is documented as not incrementing while the system is
    /// asleep, which is the entire basis of `SleepDetector`.
    public static func excludingSleep() -> TimeInterval {
        seconds(CLOCK_UPTIME_RAW)
    }

    private static func seconds(_ clock: clockid_t) -> TimeInterval {
        var time = timespec()
        clock_gettime(clock, &time)
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
    }
}

/// Notices that the machine has been asleep, by watching two clocks drift apart.
///
/// A process does not run while the machine sleeps, so when it resumes it has no
/// direct way of knowing whether a moment or eight hours passed. Comparing a
/// clock that counts sleep against one that does not gives the answer without
/// subscribing to any power notification — which matters here, because this has
/// to work in a plain command-line tool with no run loop.
///
/// Deliberately takes its readings as arguments rather than calling the clocks
/// itself, so the whole thing is testable without sleeping anything.
public struct SleepDetector: Equatable, Sendable {
    /// Below this the difference is measurement noise, not sleep.
    public static let threshold: TimeInterval = 2

    private var lastIncludingSleep: TimeInterval
    private var lastExcludingSleep: TimeInterval

    public init(includingSleep: TimeInterval, excludingSleep: TimeInterval) {
        self.lastIncludingSleep = includingSleep
        self.lastExcludingSleep = excludingSleep
    }

    public init() {
        self.init(
            includingSleep: Clocks.includingSleep(),
            excludingSleep: Clocks.excludingSleep()
        )
    }

    /// How long the machine slept between this sample and the previous one, or
    /// `nil` if it did not.
    public mutating func sample(
        includingSleep: TimeInterval,
        excludingSleep: TimeInterval
    ) -> TimeInterval? {
        let wall = includingSleep - lastIncludingSleep
        let awake = excludingSleep - lastExcludingSleep
        lastIncludingSleep = includingSleep
        lastExcludingSleep = excludingSleep

        let slept = wall - awake
        return slept >= Self.threshold ? slept : nil
    }

    public mutating func sample() -> TimeInterval? {
        sample(
            includingSleep: Clocks.includingSleep(),
            excludingSleep: Clocks.excludingSleep()
        )
    }
}
