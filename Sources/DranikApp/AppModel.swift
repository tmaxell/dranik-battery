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

    private let socketPath: String
    private let work = DispatchQueue(label: "com.dranik.battery.app.client", qos: .userInitiated)
    private var monitor: PowerEventMonitor?
    private var pollTimer: DispatchSourceTimer?
    private var cadence = PollCadence()
    private var isDragging = false
    private var isPreview = false

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
        startPolling()
        refresh()
    }

    /// A model frozen in one state, for `--snapshot`. Talks to nothing.
    init(previewing testCase: PopoverSnapshots.Case) {
        self.socketPath = ""
        self.summary = testCase.summary
        self.percentage = testCase.percentage
        self.draftLimit = testCase.draftLimit
        self.isPreview = true
    }

    // MARK: - Popover lifecycle

    func popoverAppeared() {
        guard !isPreview else { return }
        cadence.popoverOpened()
        startPolling()
        refresh()
    }

    func popoverDisappeared() {
        guard !isPreview else { return }
        cadence.popoverClosed()
        startPolling()
    }

    // MARK: - Commands

    func sliderEditingChanged(_ editing: Bool) {
        isDragging = editing
        guard !editing else { return }
        // Sent on release, not per pixel: every `setLimit` rewrites the config
        // file and provokes a full re-evaluation in the daemon.
        let upper = Int(draftLimit.rounded())
        // Snap to the whole number that was sent, so the slider does not sit
        // fractionally away from the limit now in force.
        draftLimit = Double(upper)
        // 100 means "stop limiting", which is not a limit to come back to.
        // Storing it would make the switch restore 80 out of nowhere.
        if upper < 100 { rememberedLimit = upper }
        send(ControlRequest(command: .setLimit, upper: upper))
    }

    /// Arms the gate again after a failed verification disarmed it.
    ///
    /// A button rather than something the daemon does on a timer: the mechanism
    /// exists because a limit that silently does nothing is worse than none, and
    /// re-arming unattended would restore exactly that.
    func rearm() {
        send(ControlRequest(command: .retrust))
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
                self.apply(MenuBarPresentation.summary(link: link, battery: facts), facts)
            }
        }
    }

    /// Assigns only what actually changed.
    ///
    /// Refreshes are frequent and almost always produce the same answer as the
    /// last one — the charge moves a percent, nothing else does. Every
    /// assignment to a `@Published` property republishes whether or not the
    /// value differs, which redraws the status item and the popover for nothing.
    /// Three cheap comparisons remove that.
    private func apply(_ new: MenuBarSummary, _ facts: BatteryFacts?) {
        if summary != new { summary = new }
        if percentage != facts?.percentage { percentage = facts?.percentage }

        if new.isLimiting && rememberedLimit != new.upperLimit {
            rememberedLimit = new.upperLimit
        }
        guard !isDragging else { return }
        let wanted = Double(new.isLimiting ? new.upperLimit : rememberedLimit)
        if draftLimit != wanted { draftLimit = wanted }
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
        // Every event gets a full refresh. The cheaper path — re-reading the
        // battery and reusing the last report — was its own way of being wrong:
        // it rendered a fresh charge against a gate position that had since
        // moved. A round trip on a socket the daemon already has open costs
        // less than being confidently out of date.
        let monitor = PowerEventMonitor(queue: work, observesSleep: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        try? monitor.start()
        self.monitor = monitor
    }

    /// Runs for the life of the app, only changing pace. See `PollCadence` for
    /// why it may never stop: the events this used to rely on do not fire when
    /// charging starts or stops at the limit.
    private func startPolling() {
        pollTimer?.cancel()
        let interval = cadence.interval
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if cadence.tick() {
                startPolling()
            }
            refresh()
        }
        timer.resume()
        pollTimer = timer
    }
}
