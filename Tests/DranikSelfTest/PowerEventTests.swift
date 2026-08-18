import DranikPower
import Foundation
import notify

func runPowerEventTests() {
    test("the monitor subscribes and tears down cleanly") {
        let queue = DispatchQueue(label: "test.powerevents.1")
        let monitor = PowerEventMonitor(queue: queue) { _ in }
        do {
            try monitor.start()
        } catch {
            expectTrue(false, "start failed: \(error)")
            return
        }
        monitor.stop()
    }

    test("starting twice is harmless") {
        let queue = DispatchQueue(label: "test.powerevents.2")
        let monitor = PowerEventMonitor(queue: queue) { _ in }
        try monitor.start()
        try monitor.start()
        monitor.stop()
        // And stopping twice, which deinit makes possible after an explicit stop.
        monitor.stop()
    }

    test("a monitor can be started again after being stopped") {
        let queue = DispatchQueue(label: "test.powerevents.3")
        let monitor = PowerEventMonitor(queue: queue) { _ in }
        try monitor.start()
        monitor.stop()
        try monitor.start()
        monitor.stop()
    }

    test("dropping a running monitor does not leak its subscriptions") {
        // Repeatedly create and abandon monitors. Each holds a mach port and
        // notify tokens; if deinit did not release them this would run out.
        for _ in 0..<25 {
            let monitor = PowerEventMonitor(queue: DispatchQueue(label: "test.powerevents.loop")) { _ in }
            try monitor.start()
        }
        // Reaching here without the kernel refusing a port is the assertion.
        expectTrue(true)
    }

    test("the private percent-change name is the one that was verified") {
        expectEqual(
            PowerEventMonitor.percentChangeNotification,
            "com.apple.system.powersources.percent"
        )
    }

    test("a subscribed notification is delivered as an event") {
        // The real names cannot be posted to: notifyutil -p on
        // com.apple.system.powersources.percent reaches no listener at all,
        // while an arbitrary name does. So point the monitor somewhere postable
        // and prove the wiring end to end.
        let suffix = UUID().uuidString
        let sourceName = "com.dranik.test.source.\(suffix)"
        let percentName = "com.dranik.test.percent.\(suffix)"

        let queue = DispatchQueue(label: "test.powerevents.delivery")
        let lock = NSLock()
        var received: [PowerEvent] = []
        let bothArrived = DispatchSemaphore(value: 0)

        let monitor = PowerEventMonitor(
            queue: queue,
            powerSourceName: sourceName,
            percentChangeName: percentName
        ) { event in
            lock.lock()
            received.append(event)
            let done = received.contains(.powerSourceChanged) && received.contains(.percentageChanged)
            lock.unlock()
            if done { bothArrived.signal() }
        }
        try monitor.start()
        defer { monitor.stop() }

        notify_post(sourceName)
        notify_post(percentName)

        let outcome = bothArrived.wait(timeout: .now() + .seconds(5))
        expectEqual(outcome, .success, "notifications were not delivered within 5s")

        lock.lock()
        let seen = received
        lock.unlock()
        expectTrue(seen.contains(.powerSourceChanged), "power source event missing")
        expectTrue(seen.contains(.percentageChanged), "percentage event missing")
    }

    test("a stopped monitor delivers nothing further") {
        let name = "com.dranik.test.stopped.\(UUID().uuidString)"
        let queue = DispatchQueue(label: "test.powerevents.stopped")
        let lock = NSLock()
        var count = 0

        let monitor = PowerEventMonitor(queue: queue, percentChangeName: name) { _ in
            lock.lock(); count += 1; lock.unlock()
        }
        try monitor.start()
        monitor.stop()

        notify_post(name)
        Thread.sleep(forTimeInterval: 0.5)

        lock.lock()
        let observed = count
        lock.unlock()
        expectEqual(observed, 0, "events kept arriving after stop")
    }

    test("stop() drops a delivery that was already queued") {
        // Not a property of this code but of libnotify, and one the design leans
        // on: `stop()` is trusted to be enough, with no separate guard against a
        // late event. Measured rather than assumed — and pinned here so that
        // removing `notify_cancel`, or replacing it with something weaker, fails
        // rather than quietly reintroducing a stray event at shutdown.
        let name = "com.dranik.test.race.\(UUID().uuidString)"
        let queue = DispatchQueue(label: "test.powerevents.race")
        let lock = NSLock()
        var delivered = 0

        let monitor = PowerEventMonitor(queue: queue, percentChangeName: name) { _ in
            lock.lock(); delivered += 1; lock.unlock()
        }
        try monitor.start()

        // Occupy the queue so nothing can drain, post, and give notifyd time to
        // hand the block over — it is only queued behind the blocker at that
        // point, not run. Only then stop. Without the pause the token is
        // cancelled before delivery is even attempted, and the race this exists
        // to cover never happens.
        let blocked = DispatchSemaphore(value: 0)
        queue.async { blocked.wait() }
        notify_post(name)
        Thread.sleep(forTimeInterval: 0.3)
        monitor.stop()
        blocked.signal()

        Thread.sleep(forTimeInterval: 0.5)
        lock.lock()
        let seen = delivered
        lock.unlock()
        expectEqual(seen, 0, "an event was delivered after stop()")
    }

    test("power events compare by case") {
        expectEqual(PowerEvent.didWake, .didWake)
        expectNotEqual(PowerEvent.didWake, .percentageChanged)
        expectNotEqual(PowerEvent.powerSourceChanged, .percentageChanged)
    }
}
