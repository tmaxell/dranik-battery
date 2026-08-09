import DranikCore
import DranikPower
import DranikSMC
import Foundation
import os

/// Ties the pieces together: events in, decisions out, gate moved.
///
/// Everything runs on one serial queue. The SMC user client is not safe to call
/// concurrently, and a single queue is a simpler guarantee than a lock around
/// every path that might reach it.
public final class Daemon {
    /// Re-checks the world even when nothing has been posted. A backstop for a
    /// notification that never arrives, not the primary mechanism — at a minute
    /// it would be a poor limiter on its own.
    public static let safetyNetInterval: TimeInterval = 60
    /// After waking, the machine reports transient nonsense for a while. Nothing
    /// is closed during this window; opening is still allowed.
    public static let postWakeSettle: TimeInterval = 30
    /// After closing the gate for sleep, do not reopen it during the half-minute
    /// macOS waits before actually sleeping.
    public static let preSleepBarrier: TimeInterval = 60

    private let queue = DispatchQueue(label: "com.dranik.battery.daemon")
    private let log = Logger(subsystem: "com.dranik.battery", category: "Daemon")

    private let smc: SMCConnection
    private let capabilities: Capabilities
    private let actuator: GateActuator
    private let watchdog: Watchdog
    private let dryRun: Bool
    private let statePath: String
    private let configPath: String
    private let socketPath: String

    private var config: ChargeConfig
    private var controllerState = ControllerState()
    private var monitor: PowerEventMonitor?
    private var safetyNet: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var sleepDetector = SleepDetector()
    private var lastReason = "starting up"

    private var windows = SuppressionWindows()
    private var isShuttingDown = false
    private var control: ControlServer?

    public init(
        smc: SMCConnection,
        capabilities: Capabilities,
        config: ChargeConfig,
        dryRun: Bool,
        statePath: String = StateStore.defaultPath,
        configPath: String = ConfigStore.defaultPath,
        socketPath: String = ControlProtocol.defaultSocketPath
    ) {
        self.smc = smc
        self.capabilities = capabilities
        self.config = config
        self.dryRun = dryRun
        self.statePath = statePath
        self.configPath = configPath
        self.socketPath = socketPath
        self.actuator = GateActuator(
            smc: smc, specs: capabilities.chargeGate.specs, queue: queue, dryRun: dryRun
        )
        self.watchdog = Watchdog(specs: capabilities.chargeGate.specs, dryRun: dryRun)
    }

    // MARK: - Lifecycle

    public func run() -> Never {
        let gateNames = capabilities.chargeGate.keys.map(\.description).joined(separator: "+")
        // Before anything else it might print. The first decision line appearing
        // above the banner was how someone came to read "(write)" as a write.
        if dryRun {
            print("""

            ┌─────────────────────────────────────────────────────────────┐
            │  DRY RUN — nothing is written to the SMC.                   │
            │  The battery will charge past the limit. That is expected:  │
            │  this shows what the daemon would decide, not what it does. │
            │  To make it act, install it:  make install                  │
            └─────────────────────────────────────────────────────────────┘

            limit \(config.lowerLimit)–\(config.upperLimit)%, gate \(gateNames), \
            policy \(config.sleepPolicy.rawValue)

            """)
            fflush(stdout)
        }

        installSignalHandlers()

        queue.sync {
            reconcile()
        }

        do {
            let monitor = PowerEventMonitor(queue: queue) { [weak self] event in
                self?.handle(event)
            }
            try monitor.start()
            self.monitor = monitor
        } catch {
            // Without events the daemon is blind, and a blind daemon holding the
            // gate shut is the failure this whole design exists to avoid.
            log.fault("could not subscribe to power events: \(String(describing: error), privacy: .public)")
            actuator.forceOpen(reason: "no power events")
            exit(EX_OSERR)
        }

        startSafetyNet()
        watchdog.start()
        startControlServer()

        log.notice("""
        dranikd running\(self.dryRun ? " (DRY RUN — no SMC writes)" : "", privacy: .public), \
        limit \(self.config.lowerLimit, privacy: .public)–\(self.config.upperLimit, privacy: .public)%, \
        gate \(gateNames, privacy: .public)
        """)

        withExtendedLifetime(signalSources) {
            dispatchMain()
        }
    }

    private func startControlServer() {
        let server = ControlServer(
            path: socketPath,
            applyConfig: { [weak self] newConfig in
                guard let self else { return }
                self.queue.async {
                    self.config = newConfig
                    try? ConfigStore.save(newConfig, to: self.configPath)
                    self.evaluate(trigger: "limit changed")
                }
            },
            reloadConfig: { [weak self] in
                guard let self else { return }
                self.queue.async {
                    let loaded = ConfigStore.load(from: self.configPath)
                    for problem in loaded.problems {
                        self.log.notice("config: \(problem, privacy: .public)")
                    }
                    self.config = loaded.config
                    self.evaluate(trigger: "config reloaded")
                }
            }
        )
        do {
            try server.start()
            control = server
            // Publish whatever the startup decision produced, so a client that
            // connects immediately gets an answer rather than "no decision yet".
            queue.async { self.publishReport() }
        } catch {
            // Not fatal. Losing the socket costs control, not safety, and a
            // daemon that quit over it would leave the gate wherever it was.
            log.error("control socket unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    private func publishReport() {
        let chargerReason = (try? PowerReader.snapshot())?.notChargingReason
        control?.publish(DaemonReport(
            upperLimit: config.upperLimit,
            lowerLimit: config.lowerLimit,
            thermalCutoff: config.thermalCutoff,
            sleepPolicy: config.sleepPolicy.rawValue,
            gate: controllerState.gate?.rawValue ?? "unknown",
            reason: lastReason,
            gateIsTrusted: actuator.isTrusted,
            chargerReason: chargerReason.map(String.init(describing:)),
            decidedAt: Date()
        ))
    }

    private func shutDown(reason: String, code: Int32) -> Never {
        isShuttingDown = true
        control?.stop()
        watchdog.stop()
        safetyNet?.cancel()
        monitor?.stop()

        log.notice("shutting down (\(reason, privacy: .public)) — opening the gate")
        if dryRun {
            print("\nstopping — this was a dry run, so the SMC was never touched.")
            fflush(stdout)
        }
        actuator.forceOpen(reason: reason)
        persist(gateIsClosed: false, reason: "shutdown: \(reason)")

        smc.close()
        exit(code)
    }

    // MARK: - Reconciliation

    /// Never trusts what a previous run believed. Reads the gate from the SMC,
    /// reads the battery, decides from scratch, and moves the gate to match —
    /// which is what repairs a gate left shut by a crash, a kill, or a panic.
    private func reconcile() {
        let observed = actuator.readPosition()
        if let stored = StateStore.load(from: statePath) {
            log.debug("""
            previous run left state: closed=\(stored.gateIsClosed, privacy: .public) \
            (\(stored.reason, privacy: .public))
            """)
        }

        if let observed {
            log.notice("gate found \(observed.rawValue, privacy: .public) at startup")
            controllerState.gate = observed
        } else {
            log.error("gate position unreadable at startup — treating as unknown")
            controllerState.gate = nil
        }

        // hasDecided stays false, so a charge level inside the band charges up to
        // the limit rather than being held wherever the boot left it.
        controllerState.hasDecided = false
        evaluate(trigger: "startup")
    }

    // MARK: - Events

    private func handle(_ event: PowerEvent) {
        guard !isShuttingDown else {
            if case .canSleep(let ack) = event { ack.allow() }
            if case .willSleep(let ack) = event { ack.allow() }
            return
        }

        switch event {
        case .powerSourceChanged:
            evaluate(trigger: "power source changed")
        case .percentageChanged:
            evaluate(trigger: "percentage changed")
        case .canSleep(let acknowledgement):
            handleCanSleep(acknowledgement)
        case .willSleep(let acknowledgement):
            handleWillSleep(acknowledgement)
        case .didWake:
            handleDidWake()
        }
    }

    private func handleCanSleep(_ acknowledgement: SleepAcknowledgement) {
        guard let snapshot = try? PowerReader.snapshot(),
              SleepPolicyDecision.shouldPreventIdleSleep(
                  config: config,
                  isExternalConnected: snapshot.isExternalConnected,
                  percentage: snapshot.percentage
              )
        else {
            acknowledgement.allow()
            return
        }
        log.notice("holding off idle sleep: still charging towards the limit")
        acknowledgement.deny()
    }

    private func handleWillSleep(_ acknowledgement: SleepAcknowledgement) {
        defer { acknowledgement.allow() }

        let percentage = (try? PowerReader.snapshot())?.percentage ?? 100
        let transition = SleepPolicyDecision.onWillSleep(config: config, percentage: percentage)
        log.notice("sleeping: \(transition.explanation, privacy: .public)")

        guard let position = transition.position else { return }

        actuator.apply(position, reason: "pre-sleep: \(transition.explanation)")
        controllerState.gate = position
        persist(gateIsClosed: position == .closed, reason: "pre-sleep")

        if position == .closed {
            // Do not let the safety net undo this during the half-minute macOS
            // waits before it actually sleeps.
            windows.suppressOpening(until: Date().addingTimeInterval(Self.preSleepBarrier))
        }
    }

    private func handleDidWake() {
        log.notice("woke — settling for \(Int(Self.postWakeSettle), privacy: .public)s")
        _ = sleepDetector.sample()
        windows.clearOpeningSuppression()
        windows.suppressClosing(until: Date().addingTimeInterval(Self.postWakeSettle))
        evaluate(trigger: "wake")

        queue.asyncAfter(deadline: .now() + Self.postWakeSettle) { [weak self] in
            self?.windows.clearClosingSuppression()
            self?.evaluate(trigger: "post-wake settle")
        }
    }

    // MARK: - Deciding

    private func startSafetyNet() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.safetyNetInterval, repeating: Self.safetyNetInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // macOS does not always deliver a sleep notification. Two clocks
            // drifting apart is proof it slept whether or not it said so.
            if let slept = self.sleepDetector.sample() {
                self.log.notice("""
                detected \(Int(slept), privacy: .public)s of unannounced sleep
                """)
                self.handleDidWake()
                return
            }
            self.evaluate(trigger: "safety net")
        }
        timer.resume()
        safetyNet = timer
    }

    private func evaluate(trigger: String) {
        defer { watchdog.recordProgress() }

        guard let snapshot = try? PowerReader.snapshot() else {
            // No reading at all. Fail open: the gate must not stay shut on the
            // strength of something we cannot see.
            log.error("battery unreadable (\(trigger, privacy: .public)) — opening the gate")
            applyIfAllowed(.open, reason: "battery unreadable")
            return
        }

        // Read where the gate actually is rather than carrying a belief forward.
        //
        // The belief and the hardware can part company in more ways than are
        // worth enumerating: a write that failed, a verification that reopened
        // the gate, anything else on the machine touching the key. Every one of
        // them ends the same way — the controller thinks the gate is already
        // where it wants it, decides no write is needed, and quietly stops
        // limiting anything. Re-reading costs one SMC read per decision and
        // removes the whole category.
        if let actual = actuator.readPosition(), actual != controllerState.gate {
            let believed = controllerState.gate?.rawValue ?? "unknown"
            log.notice("""
            gate is \(actual.rawValue, privacy: .public) but was believed \
            \(believed, privacy: .public) — trusting the hardware
            """)
            controllerState.gate = actual
        }

        let input = ControllerInput(
            percentage: snapshot.percentage,
            isExternalConnected: snapshot.isExternalConnected,
            temperature: snapshot.temperature
        )
        let outcome = ChargeController.decide(
            input: input, config: config, state: controllerState
        )
        controllerState = outcome.state

        let decision = outcome.decision
        let summary = """
        \(trigger): \(snapshot.percentage)% ac=\(snapshot.isExternalConnected) \
        -> \(decision.position.rawValue)\(Self.writeNote(decision.requiresWrite, dryRun: dryRun)) \
        — \(decision.reason)
        """
        log.debug("\(summary, privacy: .public)")
        lastReason = String(describing: decision.reason)
        publishReport()
        // Unified logging drops debug records unless something is streaming, so
        // a dry run — whose whole purpose is to be watched — says it out loud.
        if dryRun {
            print("[\(Self.timestamp())] \(summary)")
            fflush(stdout)
        }

        guard decision.requiresWrite else { return }
        applyIfAllowed(decision.position, reason: String(describing: decision.reason))
    }

    /// The two suppression windows, and why they point in opposite directions.
    ///
    /// After waking, readings are unreliable for a while, so nothing may be
    /// *closed* on the strength of them. After closing the gate for sleep,
    /// nothing may *open* it before the machine has actually gone under. Each
    /// window blocks one direction only, and neither can leave the gate shut for
    /// longer than the window itself.
    private func applyIfAllowed(_ position: GatePosition, reason: String) {
        guard windows.allows(position, at: Date()) else {
            let why = position == .closed ? "settling after wake" : "pre-sleep barrier"
            log.debug("holding off \(position.rawValue, privacy: .public): \(why, privacy: .public)")
            if position == .closed {
                // The controller now believes the gate is where it asked for.
                // Put its belief back in step with the hardware, or the next
                // decision will conclude no write is needed.
                controllerState.gate = actuator.readPosition()
            }
            return
        }

        actuator.apply(position, reason: reason)
        persist(gateIsClosed: position == .closed, reason: reason)
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// A dry run must never be mistakable for a real one. "(write)" on a line
    /// that wrote nothing reads as though the gate moved, which is exactly the
    /// wrong impression to leave with someone watching a limit not being applied.
    private static func writeNote(_ requiresWrite: Bool, dryRun: Bool) -> String {
        guard requiresWrite else { return "" }
        return dryRun ? " (WOULD write — dry run)" : " (write)"
    }

    private func persist(gateIsClosed: Bool, reason: String) {
        guard !dryRun else { return }
        try? StateStore.save(
            DaemonState(gateIsClosed: gateIsClosed, reason: reason), to: statePath
        )
    }

    // MARK: - Signals

    private func installSignalHandlers() {
        // Retained for the life of the process. A dispatch signal source stops
        // delivering when it is deallocated, and because installing one requires
        // SIG_IGN first, losing it makes the process ignore the signal outright
        // rather than fall back to the default — which here would mean SIGTERM
        // never reopening the gate.
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                self?.shutDown(reason: "signal \(number)", code: 0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
