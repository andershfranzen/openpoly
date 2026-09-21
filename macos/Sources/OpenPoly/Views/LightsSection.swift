import OpenPolyCore
import SwiftUI

struct LightsSection: View {
    @Bindable var store: ControlStore

    var body: some View {
        StudioCard(title: "Side lights", symbol: "sun.max") {
            VStack(alignment: .leading, spacing: 22) {
                lightSlider("Left", value: $store.draftLeft)
                lightSlider("Right", value: $store.draftRight)
                Button("Turn off") {
                    store.draftLeft = 0
                    store.draftRight = 0
                    store.scheduleLighting(.sides)
                }.buttonStyle(StudioButtonStyle()).disabled(!store.canSendHardwareCommands)
            }
        }
        .onChange(of: store.draftLeft) { _, _ in store.scheduleLighting(.sides) }
        .onChange(of: store.draftRight) { _, _ in store.scheduleLighting(.sides) }
    }

    private func lightSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.7))
                Spacer()
                Text(Format.percent(value.wrappedValue)).font(.system(size: 21, weight: .medium, design: .rounded)).monospacedDigit()
            }
            Slider(value: value, in: 0...100)
                .tint(Studio.accent)
                .disabled(store.connection != .ready)
                .accessibilityLabel("\(title) light brightness")
        }
    }
}
