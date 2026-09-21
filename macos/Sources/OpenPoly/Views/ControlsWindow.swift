import AppKit
import OpenPolyCore
import SwiftUI

struct ControlsWindow: View {
    @Bindable var store: ControlStore
    @Bindable var display: DisplayService
    @State private var selection = CommandLine.arguments.contains("--open-display") ? Tab.display : Tab.lights

    enum Tab: String, CaseIterable {
        case lights = "Lighting"
        case display = "Display"
        case camera = "Camera"
        case audio = "Audio"
        var symbol: String {
            switch self {
            case .lights: return "lightbulb.max"
            case .display: return "display"
            case .camera: return "camera.aperture"
            case .audio: return "waveform"
            }
        }

    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            Rectangle().fill(Studio.line).frame(width: 1)
            VStack(spacing: 0) {
                topbar
                if let outcome = store.outcome, outcome.level == .failure {
                    OutcomeBanner(outcome: outcome)
                        .padding(.horizontal, 32)
                        .padding(.top, 16)
                }
                if selection == .camera {
                    CameraSection(store: store)
                        .padding(28)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        pageHeading
                        switch selection {
                        case .lights:
                            HStack(alignment: .top, spacing: 18) {
                                LightsSection(store: store)
                                BottomBarSection(store: store)
                            }
                        case .camera:
                            CameraSection(store: store)
                        case .audio:
                            AudioSection(store: store)
                        case .display:
                            DisplaySection(display: display)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .padding(.bottom, 26)
                }
                .scrollIndicators(.hidden)
                }
            }
        }
        .background(Studio.background)
        .foregroundStyle(Color.white.opacity(0.92))
        .tint(Studio.accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 960, minHeight: 600)
        .task { await store.refreshIfNeeded() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 27))
                    .foregroundStyle(Studio.accent)
                Text("openpoly").font(.system(size: 22, weight: .semibold, design: .rounded)).tracking(-0.7)
            }
            .padding(.top, 34)
            .padding(.bottom, 30)
            .padding(.horizontal, 24)

            VStack(spacing: 6) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button {
                        selection = tab
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: tab.symbol).font(.system(size: 16)).frame(width: 22)
                            Text(tab.rawValue).font(.system(size: 13, weight: selection == tab ? .semibold : .medium))
                            Spacer()
                            if selection == tab { Circle().fill(Studio.accent).frame(width: 5, height: 5) }
                        }
                        .foregroundStyle(selection == tab ? Studio.accent : Studio.muted)
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .background(selection == tab ? Studio.accent.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }.padding(.horizontal, 14)
            Spacer()
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 11) {
                    Image(systemName: "display").font(.system(size: 22)).foregroundStyle(Studio.muted)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Studio P21").font(.system(size: 13, weight: .medium))
                        Text("Poly · USB device").font(.system(size: 10)).foregroundStyle(Studio.muted)
                    }
                }
                StatusPill(store: store)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Studio.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            .padding(14)

        }
        .background(Studio.sidebar)
    }

    private var topbar: some View {
        HStack {
            HStack(spacing: 9) {
                Image(systemName: "square.grid.2x2").font(.system(size: 11))
                Text("Studio P21")
                Text("/").foregroundStyle(Studio.muted.opacity(0.5))
                Text(selection.rawValue).foregroundStyle(Color.white.opacity(0.8))
            }.font(.system(size: 11)).foregroundStyle(Studio.muted)
            Spacer()
            if store.isWorking { ProgressView().controlSize(.small) }
            if store.connection != .ready {
                StatusPill(store: store, compact: true)
            }
            if store.connection == .latched {
                Button("Retry connection") { Task { await store.retryConnection() } }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .disabled(store.isWorking)
            }
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .background(Studio.raised.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(store.isWorking)
            .help("Refresh device · ⌘R")
            .accessibilityLabel("Refresh device")
        }
        .padding(.horizontal, 32)
        .frame(height: 54)
        .overlay(alignment: .bottom) { Rectangle().fill(Studio.line).frame(height: 1) }
    }

    private var pageHeading: some View {
        Text(selection.rawValue).font(.system(size: 28, weight: .medium)).tracking(-0.7)
    }

}
