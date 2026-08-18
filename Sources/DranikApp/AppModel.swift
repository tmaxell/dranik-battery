import DranikCore
import DranikPower
import Foundation
import SwiftUI

/// Everything the popover needs, and nothing that decides what it means.
///
/// The split is the whole point: what to *say* is `MenuBarPresentation`, which is
/// pure and tested. This type only gathers the inputs, hands them over, and
/// publishes the answer.
@MainActor
final class AppModel: ObservableObject {
    /// What the popover and the status item show.
    @Published private(set) var summary: MenuBarSummary
    /// Current charge, for the bar. Not part of the summary because it is a
    /// number to draw, not a judgement to make.
    @Published private(set) var percentage: Int?
    /// Where the slider sits. Follows the daemon except while being dragged —
    /// otherwise a refresh landing mid-drag would yank it back.
    @Published var draftLimit: Double

    /// How often the daemon is asked while the popover is open.
    ///
    /// The gate moves on power events, which are observed directly, and on the
    /// daemon's own safety net every 60s. Five seconds is for the latter and for
    /// a limit changed from the CLI in another window.
    private static let pollInterval: TimeInterval = 5
    /// A ceiling on that polling, in ticks.
    ///
    /// `onDisappear` is not guaranteed to arrive for a menu bar window, and a
    /// timer that outlives the popover is exactly the cost this design exists to
    /// avoid. Two minutes of an open popover is already unusual; after that it
    /// stops, and reopening starts it again.
    private static let maximumPollTicks = 24

    private let socketPath: String
    private let work = DispatchQueue(label: "com.dranik.battery.app.client", qos: .userInitiated)
    private var monitor: PowerEventMonitor?
    private var pollTimer: DispatchSourceTimer?
    private var pollTicks = 0
    private var isDragging = false

    /// The last link state, reused when refreshing from the battery alone.
    private var lastLink: DaemonLink = .notRunning

    /// The limit to restore when limiting is switched back on.
    ///
    /// Kept here rather than asked of the daemon because the daemon does not
    /// remember it: turning limiting off means a limit of 100, and 100 is not a
    /// limit to come back to.
    private var rememberedLimit: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "rememberedLimit")
            return ChargeConfig.upperRange.contains(stored) && stored < 100
                ? stored
                : ChargeConfig.defaultUpper
        }
        set { UserDefaults.standard.set(newValue, forKey: "rememberedLimit") }
    }

    init(socketPath: String = ControlProtocol.defaultSocketPath) {
        self.socketPath = socketPath
        self.summary = MenuBarPresentation.summary(link: .notRunning, battery: nil)
        self.draftLimit = Double(ChargeConfig.defaultUpper)
        startWatchingPower()
        refresh()
    }

    // MARK: - Popover lifecycle

    func popoverAppeared() {
        refresh()
        startPolling()
    }

    func popoverDisappeared() {
        stopPolling()
    }

    // MARK: - Commands

    func sliderEditingChanged(_ editing: Bool) {
        isDragging = editing
        guard !editing else { return }
        // Sent on release, not per pixel: every `setLimit` rewrites the config
        // file and provokes a full re-evaluation in the daemon.
        let upper = Int(draftLimit.rounded())
        rememberedLimit = upper
        send(ControlRequest(command: .setLimit, upper: upper))
    }

    func setLimiting(_ on: Bool) {
        send(on
            ? ControlRequest(command: .setLimit, upper: rememberedLimit)
            : ControlRequest(command: .disable))
    }

    /// Where charging resumes, for the line under the slider.
    ///
    /// Derived from the band the daemon is actually using rather than from the
    /// default hysteresis, so a band widened from the CLI is shown as it is.
    var resumePoint: Int {
        let band = max(2, summary.upperLimit - summary.lowerLimit)
        return max(ChargeConfig.lowerFloor, Int(draftLimit.rounded()) - band)
    }

    // MARK: - Gathering

    /// Asks the daemon and reads the battery.
    private func refresh() {
        work.async { [weak self] in
            guard let self else { return }
            let facts = Self.readBattery()
            let link = Self.ask(self.socketPath)
            Task { @MainActor in
                self.lastLink = link
                self.apply(MenuBarPresentation.summary(link: link, battery: facts), facts)
            }
        }
    }

    /// Re-reads the battery without touching the socket.
    ///
    /// Used for the frequent event — the percentage changing — so that sitting
    /// idle with the popover closed costs no IPC at all. The cost is that a limit
    /// changed elsewhere is not noticed until the popover opens or the charger is
    /// plugged or unplugged, which is when the gate actually moves.
    private func refreshBatteryOnly() {
        let link = lastLink
        work.async { [weak self] in
            let facts = Self.readBattery()
            Task { @MainActor in
                self?.apply(MenuBarPresentation.summary(link: link, battery: facts), facts)
            }
        }
    }

    private func apply(_ new: MenuBarSummary, _ facts: BatteryFacts?) {
        summary = new
        percentage = facts?.percentage

        if new.isLimiting {
            rememberedLimit = new.upperLimit
        }
        guard !isDragging else { return }
        draftLimit = Double(new.isLimiting ? new.upperLimit : rememberedLimit)
    }

    /// One gather, rendered as text. See `--check` in `DranikApp`.
    nonisolated static func diagnose(
        socketPath: String = ControlProtocol.defaultSocketPath
    ) -> String {
        let facts = readBattery()
        let link = ask(socketPath)
        let summary = MenuBarPresentation.summary(link: link, battery: facts)

        let daemon: String
        switch link {
        case .connected(let report):
            daemon = "connected (version \(report.version), gate \(report.gate), "
                + "reason \(report.reasonCode))"
        case .notRunning: daemon = "not running"
        case .unreachable(let why): daemon = "unreachable — \(why)"
        }

        return """
          Daemon      \(daemon)
          Battery     \(facts.map { "\($0.percentage) %" } ?? "unreadable")
          Icon        \(summary.icon.rawValue)
          Headline    \(summary.headline)
          Detail      \(summary.detail ?? "-")
          Tone        \(summary.tone.rawValue)
          Limit       \(summary.isLimiting ? "\(summary.lowerLimit)–\(summary.upperLimit) %" : "off")
          Controls    \(summary.controlsAreEnabled ? "enabled" : "disabled")
        """
    }

    private nonisolated static func readBattery() -> BatteryFacts? {
        guard let snapshot = try? PowerReader.snapshot() else { return nil }
        return BatteryFacts(
            percentage: snapshot.percentage,
            isCharging: snapshot.isCharging,
            isExternalConnected: snapshot.isExternalConnected,
            temperature: snapshot.temperature,
            minutesRemaining: snapshot.timeRemaining
        )
    }

    /// Blocking, and therefore never on the main queue: a wedged daemon must cost
    /// a stale popover, not a frozen one. Two seconds rather than the CLI's five —
    /// in something a person is looking at, five is a hang.
    private nonisolated static func ask(_ path: String) -> DaemonLink {
        do {
            let response = try ControlClient.send(
                ControlRequest(command: .status), to: path, timeout: 2
            )
            if let report = response.report {
                return .connected(report)
            }
            return .unreachable(response.error ?? "the daemon sent no report")
        } catch ControlClient.Failure.notRunning {
            return .notRunning
        } catch {
            return .unreachable("\(error)")
        }
    }

    private func send(_ request: ControlRequest) {
        work.async { [weak self] in
            guard let self else { return }
            _ = try? ControlClient.send(request, to: self.socketPath, timeout: 3)
            Task { @MainActor in self.refresh() }
        }
    }

    // MARK: - Waking up when something happens

    private func startWatchingPower() {
        // The same mechanism the daemon uses, and for the same reason: no timer
        // is running while nothing is going on.
        let monitor = PowerEventMonitor(queue: work, observesSleep: false) { [weak self] event in
            Task { @MainActor in
                switch event {
                case .powerSourceChanged:
                    // Plugging in or out is when the gate actually moves, and it
                    // happens a few times a day. Worth a round trip.
                    self?.refresh()
                default:
                    self?.refreshBatteryOnly()
                }
            }
        }
        try? monitor.start()
        self.monitor = monitor
    }

    private func startPolling() {
        stopPolling()
        pollTicks = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            pollTicks += 1
            guard pollTicks <= Self.maximumPollTicks else {
                stopPolling()
                return
            }
            refresh()
        }
        timer.resume()
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }
}
