import OpenPolyCore
import SwiftUI

struct AudioSection: View {
    let store: ControlStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if store.audio.isPresent {
                HStack(alignment: .top, spacing: 18) {
                    device(input: true)
                    device(input: false)
                }
            } else {
                ContentUnavailableView("Audio unavailable", systemImage: "waveform.slash", description: Text(store.statusMessage))
                    .frame(maxWidth: .infinity, minHeight: 330)
            }
        }
    }

    private func device(input: Bool) -> some View {
        let volume = store.audio.volume(input: input)
        let muted = store.audio.isMuted(input: input)
        return StudioCard(title: input ? "Microphone" : "Speakers", symbol: input ? "mic" : "speaker.wave.2") {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(volume.map { Format.readbackPercent($0).replacingOccurrences(of: "%", with: "") } ?? "—")
                        .font(.system(size: 70, weight: .light, design: .rounded)).tracking(-3).monospacedDigit()
                    Text("%").font(.system(size: 22, weight: .light)).foregroundStyle(Studio.muted)
                    Spacer()
                    Image(systemName: muted == true ? (input ? "mic.slash" : "speaker.slash") : (input ? "mic" : "speaker.wave.2"))
                        .font(.system(size: 32, weight: .ultraLight)).foregroundStyle(muted == true ? .orange : Studio.accent)
                }.padding(.top, 14)
                CommitSlider(title: input ? "Input level" : "Output level", range: 0...100, step: nil,
                             deviceValue: volume ?? 0, display: volume.map(Format.readbackPercent) ?? "Unknown",
                             enabled: store.audio.allChannelsWritable(input: input, mute: false) && store.canSendHardwareCommands) { value in
                    Task { await store.setVolume(input: input, percent: Int(value.rounded())) }
                }
                Rectangle().fill(Studio.line).frame(height: 1)
                Toggle(isOn: Binding(get: { muted ?? false }, set: { value in Task { await store.setMute(input: input, muted: value) } })) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(input ? "Mute microphone" : "Mute speakers").font(.system(size: 13, weight: .medium))
                        Text(muted.map { $0 ? "Muted on device" : "Unmuted on device" } ?? "State unavailable")
                            .font(.system(size: 11)).foregroundStyle(Studio.muted)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityLabel(input ? "Mute microphone" : "Mute speakers")
                .disabled(!store.audio.allChannelsWritable(input: input, mute: true) || !store.canSendHardwareCommands)
                Button { Task { await store.makeDefault(input: input) } } label: {
                    HStack {
                        Text("Use as default \(input ? "input" : "output")")
                        Image(systemName: "arrow.up.right")
                    }
                }.buttonStyle(StudioButtonStyle()).disabled(!store.canSendHardwareCommands)
            }
        }
    }
}
