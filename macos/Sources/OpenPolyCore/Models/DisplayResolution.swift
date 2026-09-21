import Foundation

public enum DisplayResolution: String, CaseIterable, Identifiable, Sendable {
    case fullHD = "1920x1080"
    case medium = "1600x900"
    case large = "1280x720"
    case extraLarge = "960x540"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .fullHD: "1920 × 1080 — Default"
        case .medium: "1600 × 900"
        case .large: "1280 × 720"
        case .extraLarge: "960 × 540 — Larger text"
        }
    }
    public var width: Int { Int(rawValue.split(separator: "x")[0])! }
    public var height: Int { Int(rawValue.split(separator: "x")[1])! }
}
