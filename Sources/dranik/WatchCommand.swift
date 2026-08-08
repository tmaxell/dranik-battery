import DranikPower
import DranikSMC
import Foundation

/// Prints power events as they arrive, so the subscriptions the daemon will be
/// built on can be watched working before there is a daemon.
///
/// Reads only. Sleep transitions are always allowed through — this observes, it
/// does not interfere, so leaving it running cannot stop a machine sleeping.
enum WatchCommand {
    static func run() -> Never {
        let queue = DispatchQueue(label: "com.dranik.battery.watch")
        var eventCount = 0
        let started = Date()

        print("""
        Watching power events. Ctrl-C to stop.

        Try: unplug and replug the charger, or close the lid and reopen it.
        Percentage changes arrive on their own every minute or two.

        """)
        // Redirected to a file, stdout is fully buffered and nothing appears
        // until the process exits — which is exactly when it is least useful.
        fflush(stdout)

        let monitor = PowerEventMonitor(queue: queue) { event in
            eventCount += 1
            let elapsed = String(format: "%7.1fs", Date().timeIntervalSince(started))

            switch event {
            case .powerSourceChanged:
                report(elapsed, "powerSourceChanged")
            case .percentageChanged:
                report(elapsed, "percentageChanged")
            case .canSleep(let acknowledgement):
                report(elapsed, "canSleep — allowing")
                acknowledgement.allow()
            case .willSleep(let acknowledgement):
                report(elapsed, "willSleep — allowing")
                acknowledgement.allow()
            case .didWake:
                report(elapsed, "didWake")
            }
        }

        do {
            try monitor.start()
        } catch {
            FileHandle.standardError.write(Data("dranik: \(error)\n".utf8))
            exit(1)
        }

        // These must outlive this function. A dispatch signal source stops
        // delivering the moment it is deallocated, and since installing one
        // requires setting the signal to SIG_IGN first, losing it does not fall
        // back to the default handler — it makes the process ignore the signal
        // outright. Ctrl-C then does nothing at all.
        var signalSources: [DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler {
                monitor.stop()
                print("\n\(eventCount) events in "
                    + String(format: "%.0f", Date().timeIntervalSince(started)) + "s")
                fflush(stdout)
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        withExtendedLifetime(signalSources) {
            dispatchMain()
        }
    }

    private static func report(_ elapsed: String, _ name: String) {
        var line = "\(elapsed)  \(name.padding(toLength: 22, withPad: " ", startingAt: 0))"
        if let snapshot = try? PowerReader.snapshot() {
            line += "\(snapshot.percentage)%  charging=\(snapshot.isCharging)  "
                + "ac=\(snapshot.isExternalConnected)  \(snapshot.amperage) mA"
            if let reason = snapshot.notChargingReason, !reason.isEmpty {
                line += "  \(reason)"
            }
        }
        print(line)
        fflush(stdout)
    }
}
