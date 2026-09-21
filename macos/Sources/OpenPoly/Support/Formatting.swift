import AppKit
import OpenPolyCore
import SwiftUI

enum Format {
    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    /// Hardware readback: keep the fraction when the device did not land on a
    /// whole percent, so the displayed number matches what was read.
    static func readbackPercent(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 { return String(format: "%.0f%%", rounded) }
        return String(format: "%.1f%%", value)
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "never" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func hex(_ color: P21Color) -> String { color.hex }
}

extension Color {
    init(_ rgb: P21Color) {
        self.init(
            .sRGB,
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255,
            opacity: 1
        )
    }

    var rgbColor: P21Color {
        let converted = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.black
        return P21Color(
            red: Int((converted.redComponent * 255).rounded()),
            green: Int((converted.greenComponent * 255).rounded()),
            blue: Int((converted.blueComponent * 255).rounded())
        )
    }
}

/// The window and popover share one readable sentence per connection state.
extension ControlStore {
    var stateTitle: String {
        switch connection {
        case .unknown: return "Not checked"
        case .ready: return "Connected"
        case .noDevice: return "No device"
        case .failed: return "Problem"
        case .latched: return "Paused"
        }
    }

    var stateSymbol: String {
        switch connection {
        case .unknown: return "questionmark.circle"
        case .ready: return "checkmark.circle.fill"
        case .noDevice: return "cable.connector.slash"
        case .failed: return "exclamationmark.triangle.fill"
        case .latched: return "pause.circle.fill"
        }
    }

    var stateTint: Color {
        switch connection {
        case .unknown: return .secondary
        case .ready: return .green
        case .noDevice: return .orange
        case .failed: return .red
        case .latched: return .red
        }
    }
}
