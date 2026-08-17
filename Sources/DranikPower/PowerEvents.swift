import CDranikPower
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import notify
import os

/// Something the daemon needs to react to.
public enum PowerEvent: Equatable, Sendable {
    /// The active power source changed — the charger was plugged in or out.
    case powerSourceChanged
    /// The reported battery percentage changed.
    case percentageChanged
    /// Idle sleep is about to begin and can still be refused.
    ///
    /// The system waits up to 30 seconds for an answer, then sleeps anyway, so
    /// the acknowledgement is not optional.
    case canSleep(SleepAcknowledgement)
    /// Sleep is happening. It cannot be refused; not acknowledging only delays
    /// it by 30 seconds. This is the last chance to touch the SMC.
    case willSleep(SleepAcknowledgement)
    /// The machine is awake again.
    case didWake

    public static func == (lhs: PowerEvent, rhs: PowerEvent) -> Bool {
        switch (lhs, rhs) {
        case (.powerSourceChanged, .powerSourceChanged),
             (.percentageChanged, .percentageChanged),
             (.didWake, .didWake):
            return true
        case (.canSleep, .canSleep), (.willSleep, .willSleep):
            return true
        default:
            return false
        }
    }
}

/// A pending sleep transition that has to be answered.
///
/// Every `canSleep` and `willSleep` must be answered exactly once. Failing to
/// answer does not prevent sleep — it just stalls the machine for 30 seconds
/// first, which users notice.
public struct SleepAcknowledgement: Sendable {
    private let rootPort: io_connect_t
    private let notificationID: Int

    init(rootPort: io_connect_t, notificationID: Int) {
        self.rootPort = rootPort
        self.notificationID = notificationID
    }

    /// Let the transition proceed.
    public func allow() {
        IOAllowPowerChange(rootPort, notificationID)
    }

    /// Refuse it. Only meaningful for `canSleep`: refusing `willSleep` returns
    /// success but the machine sleeps regardless.
    public func deny() {
        IOCancelPowerChange(rootPort, notificationID)
    }
}

/// Delivers power events onto a dispatch queue.
///
/// No polling loop and no run loop. Battery state changes arrive through
/// `notify(3)`, and sleep transitions through IOKit with its notification port
/// bound to the same queue, so a daemon built on this sits idle until the kernel
/// has something to say. That is the difference between waking a few times a
/// minute and spinning a timer every ten seconds forever.
public final class PowerEventMonitor {
    private let queue: DispatchQueue
    private let handler: (PowerEvent) -> Void
    private let log = Logger(subsystem: "com.dranik.battery", category: "PowerEvents")

    private var tokens: [Int32] = []
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var isRunning = false

    /// Posted when the reported battery percentage changes.
    ///
    /// Not in the public SDK — `IOPowerSources.h` declares its siblings but not
    /// this one. The string is stable and Battery-Toolkit uses it too. Verified
    /// firing on the target machine.
    public static let percentChangeNotification = "com.apple.system.powersources.percent"

    private let powerSourceName: String
    private let percentChangeName: String

    /// The notification names are parameters purely so the subscription path can
    /// be tested. `com.apple.system.powersources.*` reject posts from anything
    /// unprivileged — verified: `notifyutil -p` on those names reaches no
    /// listener at all, while an arbitrary name does — so the only way to prove
    /// this code delivers what it subscribes to is to point it somewhere a test
    /// can post to.
    public init(
        queue: DispatchQueue,
        powerSourceName: String = kIOPSNotifyPowerSource,
        percentChangeName: String = PowerEventMonitor.percentChangeNotification,
        handler: @escaping (PowerEvent) -> Void
    ) {
        self.queue = queue
        self.powerSourceName = powerSourceName
        self.percentChangeName = percentChangeName
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// Subscribes to everything. Throws if any subscription fails, having undone
    /// the ones that succeeded — half a subscription is worse than none, because
    /// a daemon that hears about sleep but not about charge level would hold the
    /// gate shut on stale information.
    public func start() throws {
        guard !isRunning else { return }

        do {
            try subscribeNotify(powerSourceName) { [weak self] in
                self?.handler(.powerSourceChanged)
            }
            try subscribeNotify(percentChangeName) { [weak self] in
                self?.handler(.percentageChanged)
            }
            try subscribeSystemPower()
        } catch {
            stop()
            throw error
        }

        isRunning = true
    }

    public func stop() {
        for token in tokens {
            notify_cancel(token)
        }
        tokens = []

        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
            notifier = 0
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
        isRunning = false
    }

    // MARK: - notify(3)

    private func subscribeNotify(_ name: String, _ body: @escaping () -> Void) throws {
        var token: Int32 = 0
        // No guard against delivery after `stop()` is needed: `notify_cancel`
        // drops a block that is already queued, not only future ones. Measured —
        // a handler posted onto a deliberately blocked queue and then cancelled
        // never ran, over repeated trials. `stop()` alone is sufficient, and the
        // test below pins that rather than leaving it an assumption.
        let status = notify_register_dispatch(name, &token, queue) { _ in body() }
        guard status == NOTIFY_STATUS_OK else {
            throw PowerEventError.subscriptionFailed(name: name, status: status)
        }
        tokens.append(token)
        log.debug("subscribed to \(name, privacy: .public)")
    }

    // MARK: - Sleep and wake

    private func subscribeSystemPower() throws {
        let context = Unmanaged.passUnretained(self).toOpaque()
        var port: IONotificationPortRef?
        var notifierObject: io_object_t = 0

        let connection = IORegisterForSystemPower(
            context, &port, systemPowerCallback, &notifierObject
        )
        guard connection != MACH_PORT_NULL, let port else {
            throw PowerEventError.systemPowerRegistrationFailed
        }

        // Route the port to our queue instead of a run loop, so this works in a
        // plain daemon with no CFRunLoop anywhere.
        IONotificationPortSetDispatchQueue(port, queue)

        rootPort = connection
        notifyPort = port
        notifier = notifierObject
        log.debug("subscribed to system power notifications")
    }

    fileprivate func handleSystemPower(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let notificationID = Int(bitPattern: argument)
        let acknowledgement = SleepAcknowledgement(
            rootPort: rootPort, notificationID: notificationID
        )

        switch messageType {
        case kDRMessageCanSystemSleep:
            handler(.canSleep(acknowledgement))
        case kDRMessageSystemWillSleep:
            handler(.willSleep(acknowledgement))
        case kDRMessageSystemHasPoweredOn:
            handler(.didWake)
        default:
            // kDRMessageSystemWillPowerOn and anything else: nothing to answer
            // and nothing to do.
            break
        }
    }
}

public enum PowerEventError: Error, CustomStringConvertible {
    case subscriptionFailed(name: String, status: UInt32)
    case systemPowerRegistrationFailed

    public var description: String {
        switch self {
        case .subscriptionFailed(let name, let status):
            return "could not subscribe to '\(name)': notify status \(status)"
        case .systemPowerRegistrationFailed:
            return "IORegisterForSystemPower failed"
        }
    }
}

/// C callbacks carry no context, so the monitor arrives through `refcon`.
private func systemPowerCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ service: io_service_t,
    _ messageType: UInt32,
    _ messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let monitor = Unmanaged<PowerEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
    monitor.handleSystemPower(messageType: messageType, argument: messageArgument)
}
