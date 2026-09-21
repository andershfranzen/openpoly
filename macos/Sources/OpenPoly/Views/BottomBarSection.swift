import OpenPolyCore
import SwiftUI

struct BottomBarSection: View {
    @Bindable var store: ControlStore
    private let colours: [P21Color] = [
        .init(red: 201, green: 237, blue: 172), .init(red: 255, green: 197, blue: 127),
        .init(red: 255, green: 111, blue: 110), .init(red: 235, green: 119, blue: 204),
        .init(red: 142, green: 118, blue: 255), .init(red: 91, green: 179, blue: 244),
        .init(red: 110, green: 226, blue: 209)
    ]
    private let fadeLabels = ["31 ms", "63 ms", "125 ms", "250 ms", "500 ms", "1 s", "2 s", "4 s"]

    var body: some View {
        StudioCard(title: "RGB light", symbol: "circle.lefthalf.filled") {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    ColorPicker("Colour", selection: Binding(get: { Color(store.draftRGB) }, set: { store.draftRGB = $0.rgbColor }), supportsOpacity: false)
                        .font(.system(size: 13))
                    Text(store.draftRGB.hex).font(.system(size: 11, design: .monospaced)).foregroundStyle(Studio.muted)
                }
                HStack(spacing: 6) {
                    ForEach(Array(colours.enumerated()), id: \.offset) { _, colour in
                        SwatchButton(color: colour, selected: colour == store.draftRGB) { store.draftRGB = colour; store.scheduleLighting(.rgb) }
                    }
                }
                HStack {
                    Text("Transition").font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.7))
                    Spacer()
                    Picker("Transition", selection: $store.draftFade) {
                        ForEach(0..<8) { level in Text(fadeLabels[level]).tag(Double(level)) }
                    }.labelsHidden().frame(width: 96)
                }
                Button("Turn off") { store.draftRGB = .off; store.scheduleLighting(.rgb) }.buttonStyle(StudioButtonStyle())
            }
            .disabled(store.connection != .ready)
        }
        .onChange(of: store.draftRGB) { _, _ in store.scheduleLighting(.rgb) }
        .onChange(of: store.draftFade) { _, _ in store.scheduleLighting(.fade) }
    }
}
