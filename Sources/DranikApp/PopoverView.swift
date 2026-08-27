import AppKit
import DranikCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            state
            Divider().padding(.vertical, 12)
            controls
            Divider().padding(.vertical, 10)
            MenuRow(title: "Quit Dranik", shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 280)
        .animation(.easeInOut(duration: 0.2), value: model.summary)
        .animation(.easeInOut(duration: 0.35), value: model.percentage)
        .onAppear { model.popoverAppeared() }
        .onDisappear { model.popoverDisappeared() }
    }

    /// The part people open the popover for: is it charging, and if not, why not.
    private var state: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.percentage.map { "\($0) %" } ?? "— %")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let symbol = toneSymbol {
                    Image(systemName: symbol)
                        .font(.caption)
                        .foregroundStyle(toneColor)
                }
                Text(model.summary.headline)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(toneColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let detail = model.summary.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The only state in the popover with something to do about it.
            if model.summary.needsRearming {
                Button("Arm charge limiting again") { model.rearm() }
                    .controlSize(.small)
                    .padding(.top, 2)
            }

            ChargeBar(
                percentage: model.percentage,
                limit: model.summary.isLimiting ? model.summary.upperLimit : nil,
                resumesAt: model.summary.isLimiting ? model.summary.lowerLimit : nil
            )
            .padding(.top, 4)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Limit charging", isOn: Binding(
                get: { model.summary.isLimiting },
                set: { model.setLimiting($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!model.summary.controlsAreEnabled)
            // The one thing about this product that surprises people, put where
            // they will be looking when it matters. It is a measured property of
            // the hardware rather than a defect, and discovering it in the
            // morning is the worst way to discover it.
            .help(
                "Charging stops at the limit. With the default sleep policy, "
                + "a lidded Mac on a charger will not charge overnight."
            )

            VStack(spacing: 2) {
                HStack {
                    Text("Limit")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(model.draftLimit.rounded())) %")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .font(.subheadline)

                // No `step:`. A stepped slider on macOS draws a tick for every
                // step, and fifty of them across 250 points is a comb, not a
                // control. Rounding happens where the value is used instead.
                Slider(
                    value: $model.draftLimit,
                    in: Self.limitRange,
                    onEditingChanged: model.sliderEditingChanged
                )
                .controlSize(.small)

                HStack {
                    Spacer()
                    Text("resumes at \(model.resumePoint) %")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                // Meaningless when nothing is being limited, and a number with no
                // meaning is worse than no number.
                .opacity(model.summary.isLimiting ? 1 : 0)
            }
            .disabled(!model.summary.controlsAreEnabled || !model.summary.isLimiting)
        }
    }

    /// The bounds the controller enforces, not a pair of numbers repeated here.
    private static let limitRange =
        Double(ChargeConfig.upperRange.lowerBound)...Double(ChargeConfig.upperRange.upperBound)

    private var toneColor: Color {
        switch model.summary.tone {
        case .normal: return .primary
        case .caution: return .orange
        case .alarm: return .red
        }
    }

    /// A badge, so a warning reads as a status rather than as text that happens
    /// to be coloured. Nothing at all when there is nothing wrong.
    private var toneSymbol: String? {
        switch model.summary.tone {
        case .normal: return nil
        case .caution: return "exclamationmark.circle.fill"
        case .alarm: return "exclamationmark.triangle.fill"
        }
    }
}

/// Charge as a bar, with the corridor shaded and the limit marked on it.
///
/// The mark is the cheapest explanation of the word "limit" there is: it shows
/// where charging stops relative to where the battery is now, with no sentence.
/// The shaded stretch behind it is the band — the reason the gate does not move
/// every time the charge drifts a percent.
struct ChargeBar: View {
    let percentage: Int?
    let limit: Int?
    let resumesAt: Int?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.quaternary)

                if let limit, let resumesAt, limit > resumesAt {
                    Rectangle()
                        .fill(.tint.opacity(0.2))
                        .frame(width: width * fraction(limit - resumesAt))
                        .offset(x: width * fraction(resumesAt))
                }

                if let percentage {
                    Rectangle()
                        .fill(.tint)
                        .frame(width: width * fraction(percentage))
                }

                if let limit {
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 2)
                        .offset(x: width * fraction(limit) - 1)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel(accessibilityDescription)
    }

    private func fraction(_ value: Int) -> CGFloat {
        CGFloat(min(max(value, 0), 100)) / 100
    }

    private var accessibilityDescription: String {
        var text = percentage.map { "Charge \($0) percent" } ?? "Charge unknown"
        if let limit { text += ", limit \(limit) percent" }
        return text
    }
}

/// A row that highlights under the pointer, the way a menu item does.
///
/// `Button` with the plain style is inert-looking, and this is the only thing in
/// the popover that behaves like a menu command.
struct MenuRow: View {
    let title: String
    let shortcut: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(isHovering
                            ? AnyShapeStyle(Color.white.opacity(0.7))
                            : AnyShapeStyle(.tertiary))
                }
            }
            .font(.subheadline)
            .foregroundStyle(isHovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q")
        .onHover { isHovering = $0 }
        .padding(.horizontal, -7)
    }
}
