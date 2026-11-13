import DranikCore
import DranikPower
import Foundation
import os

/// Native upper-target mode. Apple owns sleep behaviour and hysteresis; this
/// daemon never toggles adapter power or installs a powerd policy archive.
public final class NativeDaemon {
    private let queue = DispatchQueue(label: "com.dranik.battery.native")
    private let log = Logger(subsystem: "com.dranik.battery", category: "Native")
    private let controller: NativeChargeController
    private let dryRun: Bool
    private let configPath: String
    private let socketPath: String
    private var config: ChargeConfig
    private var server: ControlServer?
    private var monitor: PowerEventMonitor?
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var lastCode = ""
    private var lastReason = ""

    public init(config: ChargeConfig, controller: NativeChargeController,
                dryRun: Bool, configPath: String, socketPath: String) {
        self.config = config; self.controller = controller; self.dryRun = dryRun
        self.configPath = configPath; self.socketPath = socketPath
    }

    public func run() -> Never {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { exit(0) }
                self.server?.stop(); self.monitor?.stop(); self.timer?.cancel()
                // Keep the target through normal upgrades/restarts. Explicit
                // off releases it; uninstall restores the captured original.
                self.log.notice("stopping — macOS retains its native policy; uninstall restores the original")
                exit(0)
            }
            source.resume(); signals.append(source)
        }
        let server = ControlServer(path: socketPath, initialConfig: config, applyConfig: { [weak self] newConfig in
            guard let self else { return }
            self.queue.async {
                do {
                    if !self.dryRun { try ConfigStore.save(newConfig, to: self.configPath) }
                    self.config = newConfig
                    self.evaluate()
                } catch {
                    self.publishFailure("cannot save the requested limit: \(error)")
                }
            }
        }, reloadConfig: { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.config = ConfigStore.load(from: self.configPath).config
                self.evaluate()
            }
        })
        self.server = server
        queue.sync { evaluate() }
        do { try server.start() }
        catch {
            log.fault("native control socket unavailable: \(String(describing: error), privacy: .public)")
            exit(EX_OSERR)
        }
        do {
            let monitor = PowerEventMonitor(queue: queue) { [weak self] event in
                if case .canSleep(let acknowledgement) = event { acknowledgement.allow(); return }
                if case .willSleep(let acknowledgement) = event { acknowledgement.allow(); return }
                self?.evaluate()
            }
            try monitor.start(); self.monitor = monitor
        } catch {
            log.error("native power events unavailable; timer remains active: \(String(describing: error), privacy: .public)")
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 12, repeating: .seconds(60), leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.evaluate() }
        timer.resume(); self.timer = timer
        log.notice("dranikd running, native macOS upper target \(self.config.upperLimit, privacy: .public)%; no daemon hysteresis")
        withExtendedLifetime(signals) { dispatchMain() }
    }

    private func evaluate() {
        let battery = try? PowerReader.snapshot()
        let facts = battery.map {
            BatteryFacts(percentage: $0.percentage, isCharging: $0.isCharging,
                         isExternalConnected: $0.isExternalConnected, temperature: $0.temperature)
        }
        let decision = controller.reconcile(target: config.upperLimit, dryRun: dryRun,
                                            battery: facts, milliamps: battery?.amperage)
        if decision.reasonCode != lastCode || decision.reason != lastReason {
            if decision.state == "error" { log.error("\(decision.reason, privacy: .public)") }
            else { log.notice("\(decision.reason, privacy: .public)") }
            lastCode = decision.reasonCode; lastReason = decision.reason
        }
        if dryRun { print("DRY RUN: \(decision.reason)"); fflush(stdout) }
        publish(decision, battery: battery)
    }

    private func publishFailure(_ message: String) {
        publish(NativeChargeDecision(state: "error", reasonCode: "nativeError", reason: message, registeredLimit: nil),
                battery: try? PowerReader.snapshot())
    }
    private func publish(_ decision: NativeChargeDecision, battery: BatterySnapshot?) {
        let physicalGate = battery.map { $0.isCharging ? "open" : "closed" } ?? "unknown"
        server?.publish(DaemonReport(
            upperLimit: config.upperLimit, lowerLimit: config.lowerLimit,
            thermalCutoff: config.thermalCutoff, sleepPolicy: config.sleepPolicy.rawValue,
            gate: physicalGate, reason: decision.reason, gateIsTrusted: true,
            chargerReason: battery?.notChargingReason.map(String.init(describing:)),
            reasonCode: decision.reasonCode, limitingIsSupported: true,
            heldBy: DaemonReport.HeldBy.native,
            nativeState: decision.state,
            nativeAgentLimit: controller.observation.map { $0.enabled ? $0.limit : 100 },
            nativeRegisteredLimit: decision.registeredLimit,
            decidedAt: Date()), config: config)
    }
}
