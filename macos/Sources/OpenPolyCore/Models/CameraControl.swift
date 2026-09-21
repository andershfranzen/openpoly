import Foundation

/// One UVC control as reported by `p21ctl camera list`.
///
/// Everything here comes from the device's own descriptors and GET requests. The
/// helper prints only what it could actually read, so missing fields stay missing.
public struct CameraControl: Equatable, Identifiable, Sendable {
    public var name: String
    public var current: [Int]?
    public var minimum: [Int]?
    public var maximum: [Int]?
    public var step: [Int]?
    public var defaultValue: [Int]?
    public var writable: Bool = false
    public var disabledByAutomaticMode: Bool = false
    /// Set when the helper could not read the control at all, with its reason.
    public var unavailable: String?

    public var id: String { name }

    public init(name: String) {
        self.name = name
    }

    public var isAvailable: Bool { unavailable == nil && current != nil }

    /// Writable right now, from the device's own GET_INFO answer.
    public var isEditable: Bool { isAvailable && writable && !disabledByAutomaticMode }
}

/// The control shape the UI should render, derived from what the device reported.
public enum CameraControlKind: Equatable, Sendable {
    case toggle
    /// Discrete modes, for example exposure modes or power-line frequency.
    case modes([Int])
    case slider(range: ClosedRange<Double>, step: Double)
    /// Two-component control: pan and tilt.
    case pair(range: ClosedRange<Double>, step: Double)
    case unsupported(String)
}

/// Presentation metadata for the controls this firmware reports. Unknown names
/// fall back to a humanised version of the helper's name.
public struct CameraControlInfo: Sendable {
    public let title: String
    public let group: String
    public let unit: String?
    /// Human-readable text for a raw value, when the raw unit is not the useful one.
    public let format: (@Sendable (Int) -> String)?

    public init(
        title: String,
        group: String,
        unit: String? = nil,
        format: (@Sendable (Int) -> String)? = nil
    ) {
        self.title = title
        self.group = group
        self.unit = unit
        self.format = format
    }
}

public enum CameraCatalog {
    /// `privacy` is deliberately absent: the firmware value is a UVC software
    /// control and not evidence of a physical shutter, so it is not presented as a
    /// camera privacy switch. See docs/protocol.md.
    public static let hidden: Set<String> = ["privacy"]

    public static let groups = ["Exposure", "Framing", "Image", "Other"]

    public static let info: [String: CameraControlInfo] = [
        "auto-exposure": CameraControlInfo(title: "Auto exposure", group: "Exposure"),
        "exposure-priority": CameraControlInfo(title: "Exposure priority", group: "Exposure"),
        "exposure": CameraControlInfo(title: "Exposure", group: "Exposure", unit: "100 us"),
        "zoom": CameraControlInfo(
            title: "Zoom",
            group: "Framing",
            format: { String(format: "%.1fx", Double($0) / 10) }
        ),
        "pan-tilt": CameraControlInfo(title: "Pan and tilt", group: "Framing", unit: "arcsec"),
        "backlight": CameraControlInfo(title: "Backlight compensation", group: "Image"),
        "brightness": CameraControlInfo(title: "Brightness", group: "Image"),
        "contrast": CameraControlInfo(title: "Contrast", group: "Image"),
        "gain": CameraControlInfo(title: "Gain", group: "Image"),
        "hue": CameraControlInfo(title: "Hue", group: "Image"),
        "saturation": CameraControlInfo(title: "Saturation", group: "Image"),
        "sharpness": CameraControlInfo(title: "Sharpness", group: "Image"),
        "gamma": CameraControlInfo(title: "Gamma", group: "Image"),
        "white-balance": CameraControlInfo(title: "White balance", group: "Image", unit: "K"),
        "auto-white-balance": CameraControlInfo(title: "Auto white balance", group: "Image"),
        "power-line": CameraControlInfo(title: "Power line frequency", group: "Other"),
    ]

    public static func info(for name: String) -> CameraControlInfo {
        if let known = info[name] { return known }
        return CameraControlInfo(
            title: name.split(separator: "-").map(\.capitalized).joined(separator: " "),
            group: "Other"
        )
    }

    /// Exposure modes are a bitmask in the `step` field, not a numeric step.
    public static let exposureModeLabels: [Int: String] = [
        1: "Manual",
        8: "Aperture priority",
    ]

    public static let powerLineLabels: [Int: String] = [
        1: "50 Hz",
        2: "60 Hz",
    ]

    public static func modeLabel(control: String, value: Int) -> String? {
        switch control {
        case "auto-exposure": return exposureModeLabels[value]
        case "power-line": return powerLineLabels[value]
        default: return nil
        }
    }
}

public extension CameraControl {
    var info: CameraControlInfo { CameraCatalog.info(for: name) }
    var title: String { info.title }

    /// A device-reported default that still satisfies the same range, step and
    /// component rules used by the editable control.
    var validatedDefault: [Int]? {
        guard writable, isAvailable, let defaultValue, accepts(defaultValue) else { return nil }
        return defaultValue
    }

    func accepts(_ values: [Int]) -> Bool {
        switch kind {
        case .toggle:
            return values.count == 1 && (values[0] == 0 || values[0] == 1)
        case .modes(let modes):
            return values.count == 1 && modes.contains(values[0])
        case .slider:
            return values.count == 1 && acceptsComponent(values[0], index: 0)
        case .pair:
            let components = current?.count ?? minimum?.count ?? maximum?.count ?? 0
            return values.count == components && values.indices.allSatisfy { acceptsComponent(values[$0], index: $0) }
        case .unsupported:
            return false
        }
    }

    var kind: CameraControlKind {
        if let reason = unavailable { return .unsupported(reason) }

        if name == "auto-exposure" {
            let supported = (step ?? []).first.map { bits in
                CameraCatalog.exposureModeLabels.keys.filter { bits & $0 != 0 }.sorted()
            } ?? []
            return supported.isEmpty ? .unsupported("No exposure modes reported") : .modes(supported)
        }

        let components = maximum?.count ?? minimum?.count ?? current?.count ?? 1

        if components > 1 {
            guard let low = minimum?.first, let high = maximum?.first, high > low else {
                return .unsupported("No range reported")
            }
            let increment = Double(step?.first ?? 1)
            return .pair(range: Double(low)...Double(high), step: increment > 0 ? increment : 1)
        }

        let low = minimum?.first
        let high = maximum?.first
        let increment = step?.first ?? 1

        if isToggle(name: name, low: low, high: high) { return .toggle }

        guard let low, let high, high > low else {
            return .unsupported("No range reported")
        }
        if name == "power-line" { return .modes([low, high]) }
        return .slider(range: Double(low)...Double(high), step: Double(increment > 0 ? increment : 1))
    }

    private func isToggle(name: String, low: Int?, high: Int?) -> Bool {
        if name == "exposure-priority" || name == "auto-white-balance" { return true }
        return low == 0 && high == 1
    }

    private func acceptsComponent(_ value: Int, index: Int) -> Bool {
        guard let low = minimum?[safe: index], let high = maximum?[safe: index], value >= low, value <= high else {
            return false
        }
        let increment = step?[safe: index] ?? 1
        return increment <= 0 || (value - low) % increment == 0
    }

    /// Formatted value text for a raw component value.
    func display(_ value: Int, index: Int = 0) -> String {
        if let formatter = info.format { return formatter(value) }
        if let label = CameraCatalog.modeLabel(control: name, value: value) { return label }
        if index == 0, let unit = info.unit { return "\(value) \(unit)" }
        return "\(value)"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
