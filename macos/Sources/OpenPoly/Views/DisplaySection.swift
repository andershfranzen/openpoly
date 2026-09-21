import AppKit
import OpenPolyCore
import SwiftUI
import ServiceManagement

struct DisplaySection: View {
    @Bindable var display: DisplayService
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StudioCard(title: "P21 display", symbol: "display") {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 9) {
                        Circle().fill(display.state == .running ? Studio.accent : Studio.muted).frame(width: 7, height: 7)
                        Text(display.message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                    if display.state == .running {
                        HStack(spacing: 40) {
                            metric("Desktop", display.activeResolution?.rawValue.replacingOccurrences(of: "x", with: " × ") ?? "—")
                            metric("Refresh rate", "\(display.activeRefreshRate ?? 60) Hz")
                            metric("Live updates", display.updatesPerSecond < 1 ? "Idle" : String(format: "%.0f FPS", display.updatesPerSecond))
                        }
                        Text("The update rate drops when the image is still.")
                            .font(.system(size: 11)).foregroundStyle(Studio.muted)
                    }
                    HStack {
                        Button(display.isActive ? "Stop display" : display.state == .permission ? "Check permission" : "Start display") {
                            if display.isActive { display.stop() } else { display.start() }
                        }
                        .buttonStyle(StudioButtonStyle(primary: !display.isActive))
                        .disabled(display.state == .stopping)
                        if display.state == .permission {
                            Button("Screen Recording settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                            }.buttonStyle(StudioButtonStyle())
                        }
                        Spacer()
                    }
                }
            }
            StudioCard(title: "Display settings", symbol: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 22) {
                    CommitSlider(title: "Brightness", range: 0...100, step: nil,
                                 deviceValue: display.brightness ?? 100,
                                 display: display.brightness.map { "\(Int($0))%" } ?? "—",
                                 enabled: display.state == .running && display.brightness != nil,
                                 onCommit: { display.setBrightness($0) })
                    if let error = display.brightnessError {
                        Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    Picker("Resolution", selection: $display.selectedResolution) {
                        ForEach(DisplayResolution.allCases) { resolution in
                            Text(resolution.title).tag(resolution)
                        }
                    }.accessibilityLabel("Display resolution")
                    Picker("Refresh rate", selection: $display.selectedRefreshRate) {
                        Text("60 Hz — Smoothest").tag(60)
                        Text("30 Hz — Lower resource use").tag(30)
                    }.accessibilityLabel("Desktop refresh rate")
                    Text("Smaller resolutions make text and windows larger. These settings control the desktop; the panel stays at 1920 × 1080, 60 Hz. Changing them briefly reconnects the desktop.")
                        .font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(display.isActive ? "Apply settings" : "Save settings") { display.applySettings() }
                            .buttonStyle(StudioButtonStyle())
                            .disabled(display.state == .starting || display.state == .stopping || (display.isActive && !display.hasModeChanges))
                        Spacer()
                    }
                    if let error = display.settingsError {
                        Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
            }
            Text("OpenPoly keeps the display connected while the app is running and reconnects automatically when you plug the P21 back in. Starting the display here also enables it the next time you open OpenPoly.")
                .font(.system(size: 12)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            Toggle("Open OpenPoly at login", isOn: Binding(get: { opensAtLogin }, set: { value in
                do {
                    if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    opensAtLogin = SMAppService.mainApp.status == .enabled
                    loginError = SMAppService.mainApp.status == .requiresApproval ? "Allow OpenPoly in Login Items settings." : nil
                } catch { loginError = error.localizedDescription }
            })).toggleStyle(.switch).font(.system(size: 12))
            if let loginError { Text(loginError).font(.system(size: 11)).foregroundStyle(.orange) }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11)).foregroundStyle(Studio.muted)
            Text(value).font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
        }
    }
}
