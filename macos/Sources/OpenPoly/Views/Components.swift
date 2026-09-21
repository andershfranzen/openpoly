import OpenPolyCore
import SwiftUI

/// Connection state, always the same words everywhere it appears.
struct StatusPill: View {
    let store: ControlStore
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: store.stateSymbol)
            Text(store.stateTitle)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(store.stateTint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(store.stateTint.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(store.stateTint.opacity(0.35), lineWidth: 0.5))
        .accessibilityLabel("Device state: \(store.stateTitle)")
        .help(store.statusMessage)
    }
}

/// User changes are coalesced before sending; device readback replaces the draft.
struct CommitSlider: View {
    let title: String?
    let range: ClosedRange<Double>
    /// A step adds tick marks; pass nil for a smooth control that rounds on commit.
    let step: Double?
    let deviceValue: Double
    let display: String
    let enabled: Bool
    let onCommit: (Double) -> Void

    @State private var draft: Double
    @State private var editing = false
    @State private var pendingCommit: Task<Void, Never>?

    init(
        title: String? = nil,
        range: ClosedRange<Double>,
        step: Double?,
        deviceValue: Double,
        display: String,
        enabled: Bool,
        onCommit: @escaping (Double) -> Void
    ) {
        self.title = title
        self.range = range
        self.step = step
        self.deviceValue = deviceValue
        self.display = display
        self.enabled = enabled
        self.onCommit = onCommit
        _draft = State(initialValue: deviceValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack {
                    Text(title)
                    Spacer(minLength: 12)
                    Text(display)
                        .monospacedDigit()
                        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.6))
                }
                .font(.system(size: 12))
            }
            slider
            .disabled(!enabled)
            .accessibilityLabel(title ?? "Value")
            .accessibilityValue(display)
        }
        .onChange(of: enabled) { _, isEnabled in
            if isEnabled && !editing { draft = deviceValue }
        }
        .onChange(of: deviceValue) { _, newValue in
            if !editing { draft = newValue }
        }
    }

    @ViewBuilder
    private var slider: some View {
        let input = Binding<Double>(
            get: { draft },
            set: { value in
                draft = value
                pendingCommit?.cancel()
                pendingCommit = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
                    let snapped = step.map { range.lowerBound + ((value - range.lowerBound) / $0).rounded() * $0 } ?? value
                    onCommit(min(range.upperBound, max(range.lowerBound, snapped)))
                }
            }
        )
        Slider(value: input, in: range, onEditingChanged: { editing = $0 })
            .tint(Studio.accent)
    }
}

/// Label on the left, hardware value on the right. Read-only.
struct LabeledValue: View {
    let label: String
    let value: String
    var note: String?
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(tint)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

struct SwatchButton: View {
    let color: P21Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(color))
                .frame(width: 26, height: 26)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.white.opacity(0.85) : .clear, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Use \(color.hex)")
        .accessibilityLabel("Colour \(color.hex)")
    }
}

/// The single place command results are reported. Nothing here is optimistic:
/// every message comes from the helper's own stdout or stderr.
struct OutcomeBanner: View {
    let outcome: ControlStore.Outcome

    private var symbol: String {
        switch outcome.level {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch outcome.level {
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(outcome.message)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let command = outcome.command {
                    Text(command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(10)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 0.5)
        )
    }
}

/// Says plainly where a number came from, so stored settings are never read as
/// live measurements.
struct ProvenanceNote: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
