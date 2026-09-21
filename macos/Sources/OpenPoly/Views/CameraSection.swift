import OpenPolyCore
import SwiftUI

struct CameraSection: View {
    let store: ControlStore

    private var available: [CameraControl] {
        store.visibleCameraControls.filter { $0.isAvailable }
    }

    private var groups: [(title: String, controls: [CameraControl])] {
        CameraCatalog.groups.compactMap { group in
            let controls = available.filter { CameraCatalog.info(for: $0.name).group == group }
            return controls.isEmpty ? nil : (group, controls)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Camera").font(.system(size: 28, weight: .medium)).tracking(-0.7)
                CameraPreviewView(store: store)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity)
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if store.connection == .ready && !groups.isEmpty {
                    ForEach(groups, id: \.title) { group in
                        StudioCard(title: group.title, symbol: group.title == "Framing" ? "viewfinder" : "camera.aperture") {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Spacer()
                                    Button {
                                        Task { await store.resetCameraGroup(group.title) }
                                    } label: {
                                        Label("Reset", systemImage: "arrow.counterclockwise")
                                    }
                                    .buttonStyle(.plain)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Studio.muted)
                                    .disabled(!store.canResetCameraGroup(group.title) || !store.canSendHardwareCommands)
                                    .help("Use the defaults reported by this camera")
                                }
                                ForEach(group.controls) { control in
                                    row(control)
                                }
                            }
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let note = store.cameraNote {
                        ProvenanceNote(text: note)
                    }
                } else {
                    emptyState
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.hidden).frame(width: 290)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label("Camera controls unavailable", systemImage: "video.slash")
        } description: {
            Text(store.connection == .ready
                 ? "The camera reported no readable controls."
                 : store.statusMessage)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    @ViewBuilder
    private func row(_ control: CameraControl) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch control.kind {
            case .toggle:
                Toggle(control.title, isOn: toggleBinding(control))
                    .toggleStyle(.switch)
                    .disabled(!control.isEditable || !store.canSendHardwareCommands)
            case .modes(let modes):
                HStack {
                    Text(control.title)
                    Spacer(minLength: 12)
                    Picker("", selection: modeBinding(control, modes: modes)) {
                        ForEach(modes, id: \.self) { mode in
                            Text(CameraCatalog.modeLabel(control: control.name, value: mode) ?? "\(mode)")
                                .tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 125)
                    .disabled(!control.isEditable || !store.canSendHardwareCommands)
                }
                .font(.callout)
            case .slider(let range, let step):
                slider(control, index: 0, label: control.title, range: range, step: step)
            case .pair(let range, let step):
                slider(control, index: 0, label: "Pan", range: range, step: step)
                slider(control, index: 1, label: "Tilt", range: range, step: step)
            case .unsupported(let reason):
                LabeledValue(label: control.title, value: "Not available", note: reason)
            }

            if !isUnsupported(control), let note = editabilityNote(control) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
    }

    private func slider(
        _ control: CameraControl,
        index: Int,
        label: String,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        let current = control.current?[safe: index] ?? Int(range.lowerBound)
        return CommitSlider(
            title: label,
            range: range,
            step: step,
            deviceValue: Double(current),
            display: control.display(current, index: index),
            enabled: control.isEditable &&
                store.canSendHardwareCommands &&
                (control.name != "pan-tilt" || store.canAdjustPanTilt)
        ) { value in
            commit(control, index: index, value: value)
        }
    }

    private func toggleBinding(_ control: CameraControl) -> Binding<Bool> {
        Binding(
            get: { (control.current?.first ?? 0) != 0 },
            set: { newValue in
                Task { await store.setCamera(control, values: [newValue ? 1 : 0]) }
            }
        )
    }

    private func modeBinding(_ control: CameraControl, modes: [Int]) -> Binding<Int> {
        Binding(
            get: { control.current?.first ?? modes.first ?? 0 },
            set: { newValue in
                Task { await store.setCamera(control, values: [newValue]) }
            }
        )
    }

    private func commit(_ control: CameraControl, index: Int, value: Double) {
        if control.name == "pan-tilt" {
            Task {
                await store.setCameraComponent(
                    control.name,
                    index: index,
                    value: Int(value.rounded())
                )
            }
            return
        }
        var values = control.current ?? []
        while values.count <= index { values.append(Int(value.rounded())) }
        values[index] = Int(value.rounded())
        Task { await store.setCamera(control, values: values) }
    }

    private func editabilityNote(_ control: CameraControl) -> String? {
        if control.name == "pan-tilt", !store.canAdjustPanTilt {
            return "Pan and tilt require actual zoom above 1.0×."
        }
        if control.disabledByAutomaticMode {
            return "Disabled by the camera's automatic mode."
        }
        if !control.writable {
            return "Read-only on this firmware."
        }
        return nil
    }

    private func isUnsupported(_ control: CameraControl) -> Bool {
        if case .unsupported = control.kind { return true }
        return false
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
