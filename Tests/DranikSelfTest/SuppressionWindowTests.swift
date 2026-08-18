import DranikCore
import DranikDaemon
import Foundation

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

func runSuppressionWindowTests() {
    test("with no window set, both directions pass") {
        let windows = SuppressionWindows()
        expectTrue(windows.allows(.open, at: t0))
        expectTrue(windows.allows(.closed, at: t0))
    }

    test("the post-wake window blocks closing and never blocks opening") {
        // Opening is the direction that fails safe. If waking could block it,
        // a machine that woke needing charge would sit there not taking it.
        var windows = SuppressionWindows()
        windows.suppressClosing(until: t0.addingTimeInterval(30))

        expectFalse(windows.allows(.closed, at: t0))
        expectTrue(windows.allows(.open, at: t0), "opening must never be suppressed after waking")
    }

    test("the pre-sleep window blocks opening and never blocks closing") {
        var windows = SuppressionWindows()
        windows.suppressOpening(until: t0.addingTimeInterval(60))

        expectFalse(windows.allows(.open, at: t0))
        expectTrue(windows.allows(.closed, at: t0))
    }

    test("windows expire") {
        var windows = SuppressionWindows()
        windows.suppressClosing(until: t0.addingTimeInterval(30))
        windows.suppressOpening(until: t0.addingTimeInterval(60))

        expectFalse(windows.allows(.closed, at: t0.addingTimeInterval(29)))
        expectTrue(windows.allows(.closed, at: t0.addingTimeInterval(30)))

        expectFalse(windows.allows(.open, at: t0.addingTimeInterval(59)))
        expectTrue(windows.allows(.open, at: t0.addingTimeInterval(60)))
    }

    test("clearing a window takes effect immediately") {
        var windows = SuppressionWindows()
        windows.suppressOpening(until: t0.addingTimeInterval(3600))
        expectFalse(windows.allows(.open, at: t0))

        windows.clearOpeningSuppression()
        expectTrue(windows.allows(.open, at: t0))
    }

    test("waking clears the pre-sleep barrier rather than waiting it out") {
        // The sequence the daemon actually runs: close for sleep, sleep, wake.
        // If the opening barrier survived the wake, the gate would stay shut for
        // up to a minute after the machine came back with nothing enforcing it.
        var windows = SuppressionWindows()
        windows.suppressOpening(until: t0.addingTimeInterval(60))

        // ...machine sleeps and wakes two seconds later, as far as the clock
        // this code sees is concerned.
        windows.clearOpeningSuppression()
        windows.suppressClosing(until: t0.addingTimeInterval(32))

        expectTrue(windows.allows(.open, at: t0.addingTimeInterval(2)), "wake must release the barrier")
        expectFalse(windows.allows(.closed, at: t0.addingTimeInterval(2)))
    }

    test("both windows at once still leave opening available after a wake") {
        // Belt and braces: even if a stale pre-sleep barrier somehow survived,
        // assert the combination that would be dangerous is the one blocked.
        var windows = SuppressionWindows()
        windows.suppressClosing(until: t0.addingTimeInterval(30))
        windows.suppressOpening(until: t0.addingTimeInterval(30))

        // Both blocked is the one state where the gate cannot move at all. It
        // must be brief: neither window outlasts a minute.
        expectFalse(windows.allows(.open, at: t0))
        expectFalse(windows.allows(.closed, at: t0))
        expectTrue(windows.allows(.open, at: t0.addingTimeInterval(30)))
    }

    test("the shipped windows are shorter than the watchdog's patience") {
        // A suppression window must never be long enough for the watchdog to
        // mistake a deliberate hold for a wedge.
        expectTrue(Daemon.postWakeSettle < Watchdog.stallThreshold)
        expectTrue(Daemon.preSleepBarrier < Watchdog.stallThreshold)
    }
}
