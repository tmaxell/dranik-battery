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
    /// How often the firmware path re-reads the corridor with nothing prompting
    /// it.
    ///
    /// Ten times the gate path's interval, and the gap is the difference between
    /// the two mechanisms. The gate needs re-deciding, so a missed event costs
    /// enforcement. The corridor needs nothing — measured holding for 2 days and
    /// 20 hours without being touched — and this timer exists only to notice
    /// something *else* writing those keys. Power events, wake and config
    /// changes already cover every moment someone is using the machine, so at a
    /// minute this would be 1440 checks a day for an event that happened zero
    /// times. Principle VII: a timer has to justify its own cost.
    public static let firmwareSafetyNetInterval: TimeInterval = 600
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
    /// What this process is entitled to do, decided once from what probing
    /// found. See `DaemonMode`.
    private let mode: DaemonMode
    private let actuator: GateActuator
    /// Present only when the firmware offers a corridor. Nil on the gate path,
    /// which is what keeps the two from ever both writing.
    private let firmwareActuator: FirmwareLimitActuator?
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
    private var lastReasonCode = "unknown"

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
        self.mode = DaemonMode.forHardware(
            firmwareLimitIsSupported: capabilities.firmwareLimit.isSupported,
            gateIsSupported: capabilities.chargeGate.isSupported
        )
        self.config = config
        self.dryRun = dryRun
        self.statePath = statePath
        self.configPath = configPath
        self.socketPath = socketPath
        self.actuator = GateActuator(
            smc: smc, specs: capabilities.chargeGate.specs, queue: queue, dryRun: dryRun
        )
        self.firmwareActuator = capabilities.firmwareLimit.spec.map {
            FirmwareLimitActuator(smc: smc, spec: $0, dryRun: dryRun)
        }
        self.watchdog = Watchdog(specs: capabilities.chargeGate.specs, dryRun: dryRun)
    }

    // MARK: - Lifecycle

    public func run() -> Never {
        switch mode {
        case .firmwareLimiting: runFirmwareLimiting()
        case .observing: runObserving()
        case .limiting: break
        }

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

    /// Runs on a machine where nothing was recognised that could limit charging.
    ///
    /// Exiting would be simpler, and that is what this used to do — with
    /// `EX_UNAVAILABLE`, which `KeepAlive { SuccessfulExit: false }` reads as a
    /// reason to try again. Ten seconds later, for five hours.
    ///
    /// Staying up is also the more useful answer. The socket is what tells the
    /// CLI and the app *why* nothing is being limited; without it they can only
    /// report that the daemon is missing, which sends someone looking in the
    /// wrong place entirely.
    private func runObserving() -> Never {
        // Banner first, and in the same words as the other two paths, so that
        // `dranik soak` can count starts on every path rather than only where
        // something is being limited. Without it an observing daemon restarting
        // in a loop reported zero starts — which is the exact failure of
        // 2026-10-12, seventeen hundred times over, invisible to the tool built
        // for finding it.
        log.notice("""
        dranikd running\(self.dryRun ? " (DRY RUN — no SMC writes)" : "", privacy: .public), \
        limit \(self.config.lowerLimit, privacy: .public)–\
        \(self.config.upperLimit, privacy: .public)%, observing only
        """)
        log.fault("""
        no charge-gate key on this machine matched its expected description. \
        Nothing here can limit charging, and nothing will be written. \
        Staying up to answer clients.
        """)
        if dryRun {
            print("\nNo charge gate on this machine. Observing only — nothing will be written.\n")
            fflush(stdout)
        }

        installSignalHandlers()
        lastReason = "no charge-gate key on this machine"

        // Events only keep the battery figure in the report current. No safety
        // net and no watchdog: there is nothing to re-decide and nothing to
        // guard, and a watchdog here would exit non-zero for want of decisions —
        // the restart loop again, at two minutes instead of ten seconds.
        do {
            let monitor = PowerEventMonitor(queue: queue) { [weak self] event in
                guard let self else { return }
                // Answered, never refused: observing must not delay a sleep.
                if case .canSleep(let acknowledgement) = event { acknowledgement.allow() }
                if case .willSleep(let acknowledgement) = event { acknowledgement.allow() }
                self.publishReport()
            }
            try monitor.start()
            self.monitor = monitor
        } catch {
            // Not fatal here. Without a gate the subscriptions were only keeping
            // a readout fresh, and answering a stale figure beats not answering.
            log.error("""
            could not subscribe to power events: \
            \(String(describing: error), privacy: .public) — the report will not refresh
            """)
        }

        startControlServer()

        withExtendedLifetime(signalSources) {
            dispatchMain()
        }
    }

    /// Runs on a machine whose firmware will hold the corridor itself.
    ///
    /// Shorter than the gate path by everything the gate needed: no hysteresis to
    /// run, no watchdog, no sleep policy, no trust to lose. The corridor is state
    /// the hardware keeps, so the work is to set it and then to notice if it
    /// stops saying what was asked for.
    ///
    /// The sleep handlers are answered and otherwise ignored on purpose. The
    /// whole reason `sleepPolicy` exists is that the gate's position is whatever
    /// the daemon left behind; a firmware corridor is enforced while the machine
    /// sleeps, so there is nothing to decide before sleeping.
    private func runFirmwareLimiting() -> Never {
        let keys = capabilities.firmwareLimit.keys.map(\.description).joined(separator: "+")
        if dryRun {
            print("""

            ┌─────────────────────────────────────────────────────────────┐
            │  DRY RUN — nothing is written to the SMC.                   │
            │  The firmware corridor is read but never set. The battery   │
            │  will charge past the limit; that is expected.              │
            │  To make it act, install it:  make install                  │
            └─────────────────────────────────────────────────────────────┘

            limit \(config.lowerLimit)–\(config.upperLimit)%, firmware corridor \(keys)

            """)
            fflush(stdout)
        }

        installSignalHandlers()
        queue.sync { evaluateFirmware(trigger: "startup") }

        do {
            let monitor = PowerEventMonitor(queue: queue) { [weak self] event in
                guard let self else { return }
                // Answered and then dropped. There is nothing to decide before
                // sleeping — the firmware enforces the corridor through it — and
                // three SMC reads while macOS waits on the acknowledgement is
                // work that can only delay a sleep.
                if case .canSleep(let acknowledgement) = event {
                    acknowledgement.allow()
                    return
                }
                if case .willSleep(let acknowledgement) = event {
                    acknowledgement.allow()
                    return
                }
                if case .didWake = event {
                    // Not to re-decide — the firmware held the corridor all
                    // night — but because a firmware update applies across a
                    // restart and this is the cheapest place to find out.
                    self.evaluateFirmware(trigger: "woke up")
                    return
                }
                // Charge and power-source changes do not change the corridor.
                // They change what the report should say about it, which is why
                // this is a republish rather than a decision.
                self.evaluateFirmware(trigger: "power event")
            }
            try monitor.start()
            self.monitor = monitor
        } catch {
            // Not fatal, and notably less serious than on the gate path: the
            // corridor goes on being enforced by the firmware with nobody
            // watching. What is lost is a fresh readout.
            log.error("""
            could not subscribe to power events: \
            \(String(describing: error), privacy: .public) — the report will not refresh
            """)
        }

        startFirmwareSafetyNet()
        startControlServer()

        log.notice("""
        dranikd running\(self.dryRun ? " (DRY RUN — no SMC writes)" : "", privacy: .public), \
        limit \(self.config.lowerLimit, privacy: .public)–\
        \(self.config.upperLimit, privacy: .public)%, \
        held by the firmware via \(keys, privacy: .public)
        """)

        withExtendedLifetime(signalSources) {
            dispatchMain()
        }
    }

    /// Re-reads the corridor on a long interval.
    ///
    /// Distinct from the gate's safety net, which exists because a decision may
    /// have been missed. Nothing here needs re-deciding; what this catches is
    /// the corridor being changed by something that is not us.
    private func startFirmwareSafetyNet() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.firmwareSafetyNetInterval,
            repeating: Self.firmwareSafetyNetInterval
        )
        timer.setEventHandler { [weak self] in
            self?.evaluateFirmware(trigger: "safety net")
        }
        timer.resume()
        safetyNet = timer
    }

    /// Brings the firmware's corridor to what the configuration asks for, and
    /// records what it found doing so.
    private func evaluateFirmware(trigger: String) {
        guard let firmwareActuator else { return }

        let snapshot = try? PowerReader.snapshot()
        let activity = Self.activity(from: snapshot)
        var decision = FirmwareLimitPolicy.decide(
            config: config, observed: firmwareActuator.read(), activity: activity
        )

        // Every decision line on this path carries the marker when nothing is
        // being written, because `dranik soak` reads these lines back and must
        // not count a rehearsal as something the machine did.
        let rehearsal = dryRun ? " [DRY RUN]" : ""

        if decision.requiresWrite {
            log.notice("""
            \(decision.reason.description, privacy: .public) \
            (\(trigger, privacy: .public))\(rehearsal, privacy: .public)
            """)
            if firmwareActuator.apply(decision.plan, reason: trigger) {
                // Decide again from what the firmware now reports, so the report
                // describes the settled corridor rather than the repair. The
                // firmware is the authority on its own state; a write that
                // returned success is not.
                decision = FirmwareLimitPolicy.decide(
                    config: config,
                    observed: firmwareActuator.read(),
                    activity: activity
                )
            } else {
                decision = FirmwareLimitDecision(
                    plan: decision.plan, requiresWrite: false, reason: .writeFailed
                )
            }
        }

        if decision.reason.code != lastReasonCode {
            if decision.reason.isFault {
                log.fault("""
                \(decision.reason.description, privacy: .public)\(rehearsal, privacy: .public)
                """)
            } else {
                log.notice("""
                \(decision.reason.description, privacy: .public) \
                (\(trigger, privacy: .public))\(rehearsal, privacy: .public)
                """)
            }
        }
        lastReason = decision.reason.description
        lastReasonCode = decision.reason.code

        // "Closed" here means what it means everywhere else in the report:
        // charging is being held off. Derived from the same hardware reading as
        // the reason, so the two lines cannot contradict each other.
        if snapshot == nil {
            controllerState.gate = nil
        } else {
            switch activity {
            case .heldOff, .comingDown: controllerState.gate = .closed
            case .charging, .onBattery, .indeterminate: controllerState.gate = .open
            }
        }

        publishReport()
    }

    /// Turns a battery reading into what the charger is doing.
    ///
    /// Kept here rather than in `DranikCore` only because `BatterySnapshot` is a
    /// `DranikPower` type; the decision itself is `FirmwareChargeActivity.from`,
    /// which is pure and tested.
    private static func activity(from snapshot: BatterySnapshot?) -> FirmwareChargeActivity {
        guard let snapshot else { return .indeterminate }
        return FirmwareChargeActivity.from(
            isExternalConnected: snapshot.isExternalConnected,
            isCharging: snapshot.isCharging,
            milliamps: snapshot.amperage,
            isInhibited: snapshot.notChargingReason?.contains(.inhibited) == true
                || (snapshot.chargerInhibitReason ?? 0) != 0
        )
    }

    private func startControlServer() {
        let server = ControlServer(
            path: socketPath,
            initialConfig: config,
            applyConfig: { [weak self] newConfig in
                guard let self else { return }
                self.queue.async {
                    // Kept whatever the mode: the configuration is what the
                    // person asked for, and it should survive a machine that
                    // cannot honour it today.
                    self.config = newConfig
                    try? ConfigStore.save(newConfig, to: self.configPath)
                    switch self.mode {
                    case .limiting:
                        self.evaluate(trigger: "limit changed")
                    case .firmwareLimiting:
                        self.evaluateFirmware(trigger: "limit changed")
                    case .observing:
                        // Nothing to decide. Republish so the new limits show
                        // and the waiting client is answered, but the gate goes
                        // on saying what is true: there isn't one.
                        self.publishReport()
                    }
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
                    switch self.mode {
                    case .limiting:
                        self.evaluate(trigger: "config reloaded")
                    case .firmwareLimiting:
                        self.evaluateFirmware(trigger: "config reloaded")
                    case .observing:
                        self.publishReport()
                    }
                }
            },
            restoreTrust: { [weak self] in
                guard let self else { return }
                self.queue.async {
                    // On the firmware path there is no trust to restore, but the
                    // intent behind the command — "make the limit work again" —
                    // still maps onto something: put the corridor back.
                    if self.mode == .firmwareLimiting {
                        self.evaluateFirmware(trigger: "asked to re-apply")
                        return
                    }
                    guard self.actuator.restoreTrust() else { return }
                    self.evaluate(trigger: "gate re-armed")
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

    private var heldBy: String {
        switch mode {
        case .firmwareLimiting: return DaemonReport.HeldBy.firmware
        case .limiting: return DaemonReport.HeldBy.daemon
        case .observing: return DaemonReport.HeldBy.nothing
        }
    }

    private func publishReport() {
        let chargerReason = (try? PowerReader.snapshot())?.notChargingReason
        control?.publish(
            DaemonReport(
                upperLimit: config.upperLimit,
                lowerLimit: config.lowerLimit,
                thermalCutoff: config.thermalCutoff,
                sleepPolicy: config.sleepPolicy.rawValue,
                gate: controllerState.gate?.rawValue ?? "unknown",
                reason: lastReason,
                gateIsTrusted: actuator.isTrusted,
                chargerReason: chargerReason.map(String.init(describing:)),
                reasonCode: lastReasonCode,
                limitingIsSupported: mode.mayWriteToSMC,
                preventIdleSleepWhileCharging: config.preventIdleSleepWhileCharging,
                heldBy: heldBy,
                decidedAt: Date()
            ),
            config: config
        )
    }

    private func shutDown(reason: String, code: Int32) -> Never {
        isShuttingDown = true
        control?.stop()
        watchdog.stop()
        safetyNet?.cancel()
        monitor?.stop()

        guard mode.restoresOnExit else {
            if mode == .firmwareLimiting {
                // Deliberately left alone. The corridor is the limit working,
                // and the firmware goes on enforcing it with nothing running —
                // which is the point. Clearing it here would mean charge
                // limiting lapsed on every restart, and `make install` restarts
                // the daemon. Uninstalling clears it.
                log.notice("""
                shutting down (\(reason, privacy: .public)) — \
                the firmware keeps the corridor
                """)
            } else {
                // Nothing was ever written, so there is nothing to put back.
                // Saying "opening the gate" here would be a lie in the log.
                log.notice("""
                shutting down (\(reason, privacy: .public)) — nothing was being limited
                """)
            }
            smc.close()
            exit(code)
        }

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

        // Nothing to do if the gate is already there. Writing the value a key
        // already holds is harmless but not free: it schedules another
        // verification, and every verification is a chance to misjudge a working
        // mechanism. Observed writing 01000000 over 01000000 on every sleep.
        if actuator.readPosition() == position {
            log.notice("gate is already \(position.rawValue, privacy: .public) — nothing to write")
            controllerState.gate = position
            if position == .closed {
                windows.suppressOpening(until: Date().addingTimeInterval(Self.preSleepBarrier))
            }
            return
        }

        // The belief must follow the outcome here more than anywhere else: the
        // machine is about to sleep for hours, and nothing will re-read the gate
        // until it wakes.
        guard actuator.apply(position, reason: "pre-sleep: \(transition.explanation)") else {
            log.error("pre-sleep gate write failed — sleeping with the gate as it is")
            controllerState.gate = actuator.readPosition()
            return
        }
        controllerState.gate = position
        persist(gateIsClosed: position == .closed, reason: "pre-sleep")
        publishReport()

        if position == .closed {
            // Do not let the safety net undo this during the half-minute macOS
            // waits before it actually sleeps.
            windows.suppressOpening(until: Date().addingTimeInterval(Self.preSleepBarrier))
        }
    }

    private func handleDidWake() {
        log.notice("woke — settling for \(Int(Self.postWakeSettle), privacy: .public)s")
        // Before anything else: a gate write on either side of this cannot be
        // judged, and the check for the last one may still be pending.
        actuator.noteWake()
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
        lastReasonCode = decision.reason.code
        // Unified logging drops debug records unless something is streaming, so
        // a dry run — whose whole purpose is to be watched — says it out loud.
        if dryRun {
            print("[\(Self.timestamp())] \(summary)")
            fflush(stdout)
        }

        if decision.requiresWrite {
            applyIfAllowed(decision.position, reason: String(describing: decision.reason))
        }
        // After acting, never before. Publishing the decision on its own would
        // report a gate position that a suppression window or a refused write
        // may have prevented — the same "believed but not true" shape that
        // already cost this project one silent failure.
        publishReport()
    }

    /// The two suppression windows, and why they point in opposite directions.
    ///
    /// After waking, readings are unreliable for a while, so nothing may be
    /// *closed* on the strength of them. After closing the gate for sleep,
    /// nothing may *open* it before the machine has actually gone under. Each
    /// window blocks one direction only, and neither can leave the gate shut for
    /// longer than the window itself.
    /// Moves the gate if the suppression windows allow it, and brings the
    /// controller's belief and the recorded state into line with what actually
    /// happened — not with what was asked for.
    ///
    /// A write can be prevented by a window or refused outright, and recording
    /// the intention in either case leaves `state.json` describing a machine
    /// that does not exist. Since that file exists precisely to say afterwards
    /// what a daemon was doing when it stopped, an optimistic entry is worse
    /// than none.
    @discardableResult
    private func applyIfAllowed(_ position: GatePosition, reason: String) -> Bool {
        let allowed = windows.allows(position, at: Date())
        if !allowed {
            let why = position == .closed ? "settling after wake" : "pre-sleep barrier"
            log.debug("holding off \(position.rawValue, privacy: .public): \(why, privacy: .public)")
        }

        let applied = allowed && actuator.apply(position, reason: reason)
        let outcome = GateApplication.resolve(
            requested: position,
            reason: reason,
            allowed: allowed,
            applied: applied,
            actualGate: applied ? position : actuator.readPosition()
        )

        controllerState.gate = outcome.believedGate
        if let record = outcome.record {
            persist(gateIsClosed: record.gateIsClosed, reason: record.reason)
        }
        return applied
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
