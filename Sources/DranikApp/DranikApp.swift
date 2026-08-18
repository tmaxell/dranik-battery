import DranikCore
import SwiftUI

/// A menu bar item and one popover. There is deliberately nothing else — no
/// window, no settings pane, no tabs.
///
/// `.window` and not the default `.menu` style: a menu is an `NSMenu`, it blocks
/// the run loop while open, and controls that are not buttons misbehave inside
/// it. A slider in a menu is the single most complained-about part of the app
/// this one is an alternative to.
@main
struct DranikApp: App {
    @StateObject private var model = AppModel()

    init() {
        // `--check` prints exactly what the popover would show and exits.
        //
        // Worth having in the product rather than in a test: the one thing a
        // test cannot look at is the screen, and this reduces "does the app see
        // the right thing" to a question with a text answer. It is also the only
        // way to check the app against a real daemon over the real socket.
        if CommandLine.arguments.contains("--check") {
            print(AppModel.diagnose(socketPath: Self.socketArgument()))
            exit(0)
        }
    }

    /// `--socket` points the app at a different daemon.
    ///
    /// It exists for the drill: the states worth being sure about are the ones a
    /// healthy daemon will not produce on demand, and the only way to see them is
    /// to talk to one that produces them deliberately.
    private static func socketArgument() -> String {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--socket"),
              index + 1 < arguments.count else {
            return ControlProtocol.defaultSocketPath
        }
        return arguments[index + 1]
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            Image(systemName: model.summary.icon.symbolName)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
    }
}

extension MenuBarSummary.Icon {
    /// The only place a state is turned into a picture. The names in
    /// `MenuBarSummary.Icon` describe the situation, so the artwork can be
    /// changed here without touching anything that decides.
    var symbolName: String {
        switch self {
        case .unlimited: return "battery.100percent"
        case .chargingToLimit: return "battery.100percent.bolt"
        case .holding: return "battery.75percent"
        case .onBattery: return "battery.50percent"
        case .warning: return "exclamationmark.triangle"
        }
    }
}
