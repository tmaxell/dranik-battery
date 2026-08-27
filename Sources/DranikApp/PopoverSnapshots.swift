import AppKit
import DranikCore
import SwiftUI

/// Renders the popover to PNG files without opening it.
///
/// The one part of this product a test cannot look at is the one people actually
/// use. `ImageRenderer` turns it back into something that can be looked at —
/// every state, both appearances, without waiting for the machine to get hot or
/// the gate to fail.
enum PopoverSnapshots {
    struct Case {
        let name: String
        let summary: MenuBarSummary
        let percentage: Int?
        let draftLimit: Double
    }

    static let cases: [Case] = [
        Case(
            name: "holding",
            summary: summary(
                headline: "Holding at 80 %", detail: nil, icon: .holding, tone: .normal,
                limiting: true, upper: 80, lower: 75
            ),
            percentage: 80, draftLimit: 80
        ),
        Case(
            name: "charging",
            summary: summary(
                headline: "Charging to 80 %", detail: nil, icon: .chargingToLimit,
                tone: .normal, limiting: true, upper: 80, lower: 75
            ),
            percentage: 62, draftLimit: 80
        ),
        Case(
            name: "on-battery",
            summary: summary(
                headline: "On battery — 3 h 20 min left", detail: nil, icon: .onBattery,
                tone: .normal, limiting: true, upper: 80, lower: 75
            ),
            percentage: 64, draftLimit: 80
        ),
        Case(
            name: "disagreement",
            summary: summary(
                headline: "Plugged in — not charging",
                detail: "Something else is holding charging back — check Optimized Battery Charging.",
                icon: .holding, tone: .normal, limiting: true, upper: 80, lower: 75
            ),
            percentage: 77, draftLimit: 80
        ),
        Case(
            name: "unlimited",
            summary: summary(
                headline: "Not limiting — charging to full", detail: nil, icon: .unlimited,
                tone: .normal, limiting: false, upper: 100, lower: 95
            ),
            percentage: 93, draftLimit: 80
        ),
        Case(
            name: "thermal",
            summary: summary(
                headline: "Paused — battery at 41.2 °C", detail: "Charging resumes once it cools.",
                icon: .holding, tone: .caution, limiting: true, upper: 80, lower: 75
            ),
            percentage: 71, draftLimit: 80
        ),
        Case(
            name: "untrusted-gate",
            summary: summary(
                headline: "Not limiting — the gate stopped responding",
                detail: "Charging is not being held back. Check why, then arm it again.",
                icon: .warning, tone: .alarm, limiting: true, upper: 80, lower: 75,
                rearm: true
            ),
            percentage: 88, draftLimit: 80
        ),
        Case(
            name: "no-daemon",
            summary: summary(
                headline: "Daemon not running", detail: "Charging is not being limited.",
                icon: .warning, tone: .caution, limiting: false, upper: 80, lower: 75,
                controls: false
            ),
            percentage: 80, draftLimit: 80
        ),
    ]

    @MainActor
    static func write(to directory: String) {
        let base = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        for (name, scheme) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for testCase in cases {
                guard let png = render(testCase, appearance: scheme) else {
                    FileHandle.standardError.write(Data("could not render \(testCase.name)\n".utf8))
                    continue
                }
                try? png.write(to: base.appendingPathComponent("\(testCase.name)-\(name).png"))
            }
        }
        print("wrote \(cases.count * 2) snapshots to \(directory)")
    }

    /// Hosted in a real off-screen window rather than run through `ImageRenderer`.
    ///
    /// `ImageRenderer` draws SwiftUI's own shapes and text but replaces anything
    /// backed by AppKit — the switch and the slider, which is to say both of the
    /// controls — with a placeholder. A window renders what the popover will
    /// actually look like, which is the only version worth checking.
    @MainActor
    private static func render(_ testCase: Case, appearance: NSAppearance.Name) -> Data? {
        // The popover itself paints no background — the menu bar window it lives
        // in provides one. A snapshot has no such window, so without this the
        // dark rendering is white text on nothing.
        let view = PopoverView(model: AppModel(previewing: testCase))
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func summary(
        headline: String,
        detail: String?,
        icon: MenuBarSummary.Icon,
        tone: MenuBarSummary.Tone,
        limiting: Bool,
        upper: Int,
        lower: Int,
        controls: Bool = true,
        rearm: Bool = false
    ) -> MenuBarSummary {
        MenuBarSummary(
            headline: headline, detail: detail, icon: icon, tone: tone,
            controlsAreEnabled: controls, isLimiting: limiting, needsRearming: rearm,
            upperLimit: upper, lowerLimit: lower
        )
    }
}
