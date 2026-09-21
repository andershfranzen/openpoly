import AppKit
import OpenPolyCore
import SwiftUI

struct MenuBarPanel: View {
    @Bindable var store: ControlStore
    @Bindable var display: DisplayService
    var openControls: () -> Void
    private let colours = [P21Color(red: 255, green: 255, blue: 255), .init(red: 255, green: 197, blue: 127), .init(red: 235, green: 119, blue: 204), .init(red: 142, green: 118, blue: 255), .init(red: 110, green: 226, blue: 209)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "circle.hexagongrid.fill").foregroundStyle(Studio.accent)
                Text("openpoly").font(.system(size: 18, weight: .semibold, design: .rounded)).tracking(-0.5)
                Spacer()
                StatusPill(store: store)
            }
            VStack(spacing: 14) {
                HStack {
                    Label("Lights", systemImage: "sun.max").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button {
                        store.draftLeft = 0
                        store.draftRight = 0
                        store.scheduleLighting(.sides)
                    } label: { Image(systemName: "power") }
                        .buttonStyle(.plain).foregroundStyle(Studio.muted).accessibilityLabel("Turn side lights off")
                        .disabled(store.connection != .ready)
                }
                sideSlider("Left", left: true)
                sideSlider("Right", left: false)
                Divider().overlay(Studio.line)
                HStack(spacing: 7) {
                    Text("RGB").font(.system(size: 11)).foregroundStyle(Studio.muted).frame(width: 32, alignment: .leading)
                    ForEach(Array(colours.enumerated()), id: \.offset) { _, colour in
                        SwatchButton(color: colour, selected: store.draftRGB == colour) {
                            store.draftRGB = colour
                            store.scheduleLighting(.rgb)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        store.draftRGB = .off
                        store.scheduleLighting(.rgb)
                    } label: { Image(systemName: "power") }
                        .buttonStyle(.plain).foregroundStyle(Studio.muted).accessibilityLabel("Turn RGB light off")
                }.disabled(store.connection != .ready)
            }.padding(16).background(Studio.surface, in: RoundedRectangle(cornerRadius: 17))

            if let zoom = store.visibleCameraControls.first(where: { $0.name == "zoom" }),
               case .slider(let range, let step) = zoom.kind {
                CommitSlider(title: "Camera zoom", range: range, step: step,
                             deviceValue: Double(zoom.current?.first ?? Int(range.lowerBound)),
                             display: zoom.current?.first.map { zoom.display($0) } ?? "Unknown",
                             enabled: zoom.isEditable && store.canSendHardwareCommands) { value in
                    Task { await store.setCamera(zoom, values: [Int(value.rounded())]) }
                }.padding(.horizontal, 3)
            }

            VStack(spacing: 16) {
                Toggle(isOn: Binding(get: { store.audio.isMuted(input: true) ?? false }, set: { value in
                    Task { await store.setMute(input: true, muted: value) }
                })) {
                    Label("Mute microphone", systemImage: "mic.slash").font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                .disabled(!store.audio.allChannelsWritable(input: true, mute: true) || !store.canSendHardwareCommands)
                audioSlider(input: true)
                audioSlider(input: false)
            }.padding(16).background(Studio.surface, in: RoundedRectangle(cornerRadius: 17))
            Button(action: openControls) {
                HStack { Text("Open controls"); Spacer(); Image(systemName: "arrow.up.right") }.frame(maxWidth: .infinity)
            }.buttonStyle(StudioButtonStyle(primary: true))
            HStack {
                Label("Display", systemImage: "display")
                Spacer()
                Button(display.isActive ? "Stop" : "Start") {
                    if display.isActive { display.stop() } else { display.start() }
                }.disabled(display.state == .stopping)
            }.font(.system(size: 12)).foregroundStyle(Studio.muted)
            HStack {
                Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.isWorking)
                if store.connection == .latched {
                    Button("Retry") { Task { await store.retryConnection() } }.disabled(store.isWorking)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Studio.muted)
            if let outcome = store.outcome, outcome.level == .failure {
                Text(outcome.message).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22).frame(width: 368)
        .background(Studio.background)
        .foregroundStyle(.white.opacity(0.92)).tint(Studio.accent).preferredColorScheme(.dark)
        .task { await store.refreshIfNeeded() }
    }

    private func sideSlider(_ title: String, left: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 11)).foregroundStyle(Studio.muted).frame(width: 32, alignment: .leading)
            Slider(value: Binding(get: { left ? store.draftLeft : store.draftRight }, set: { value in
                if left { store.draftLeft = value } else { store.draftRight = value }
                store.scheduleLighting(.sides)
            }), in: 0...100)
                .disabled(store.connection != .ready)
                .accessibilityLabel("\(title) light brightness")
            Text(Format.percent(left ? store.draftLeft : store.draftRight))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(Studio.muted).frame(width: 35, alignment: .trailing)
        }
    }

    private func audioSlider(input: Bool) -> some View {
        CommitSlider(title: input ? "Microphone" : "Speakers", range: 0...100, step: nil,
                     deviceValue: store.audio.volume(input: input) ?? 0,
                     display: store.audio.volume(input: input).map(Format.readbackPercent) ?? "Unknown",
                     enabled: store.audio.allChannelsWritable(input: input, mute: false) && store.canSendHardwareCommands) { value in
            Task { await store.setVolume(input: input, percent: Int(value.rounded())) }
        }
    }
}
