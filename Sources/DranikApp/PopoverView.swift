import AppKit
import DranikCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            state
            Divider()
            controls
            Divider()
            Button("Quit Dranik") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 268)
        .onAppear { model.popoverAppeared() }
        .onDisappear { model.popoverDisappeared() }
    }

    /// The part people open the popover for: is it charging, and if not, why not.
    private var state: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChargeBar(
                percentage: model.percentage,
                limit: model.summary.isLimiting ? model.summary.upperLimit : nil
            )
            HStack(alignment: .firstTextBaseline) {
                Text(model.summary.headline)
                    .font(.headline)
                    .foregroundStyle(color(for: model.summary.tone))
                Spacer()
                if let percentage = model.percentage {
                    Text("\(percentage) %")
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if let detail = model.summary.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Limit charging", isOn: Binding(
                get: { model.summary.isLimiting },
                set: { model.setLimiting($0) }
            ))
            .toggleStyle(.switch)
            .disabled(!model.summary.controlsAreEnabled)

            HStack(spacing: 10) {
                Text("Limit")
                    .foregroundStyle(.secondary)
                Slider(
                    value: $model.draftLimit,
                    in: Self.limitRange,
                    step: 1,
                    onEditingChanged: model.sliderEditingChanged
                )
                Text("\(Int(model.draftLimit)) %")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .disabled(!model.summary.controlsAreEnabled || !model.summary.isLimiting)

            // Not editable here. It exists so that "limit" is not mistaken for a
            // hard stop the battery sits against, which is what the band is for.
            Text("resumes at \(model.resumePoint) %")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    /// The bounds the controller enforces, not a pair of numbers repeated here.
    private static let limitRange =
        Double(ChargeConfig.upperRange.lowerBound)...Double(ChargeConfig.upperRange.upperBound)

    private func color(for tone: MenuBarSummary.Tone) -> Color {
        switch tone {
        case .normal: return .primary
        case .caution: return .orange
        case .alarm: return .red
        }
    }
}

/// Charge as a bar, with a tick where the limit is.
///
/// The tick is the cheapest explanation of the word "limit" available: it shows
/// where charging will stop relative to where it is now, without a sentence.
struct ChargeBar: View {
    let percentage: Int?
    let limit: Int?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                if let percentage {
                    Capsule()
                        .fill(.tint)
                        .frame(width: width * CGFloat(min(max(percentage, 0), 100)) / 100)
                }
                if let limit {
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2)
                        .offset(x: width * CGFloat(min(max(limit, 0), 100)) / 100 - 1)
                }
            }
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var text = percentage.map { "Charge \($0) percent" } ?? "Charge unknown"
        if let limit { text += ", limit \(limit) percent" }
        return text
    }
}
