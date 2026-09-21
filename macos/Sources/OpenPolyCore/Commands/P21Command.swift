import Foundation

/// One invocation of the bundled `p21ctl` helper.
///
/// The helper stays the hardware authority: the app never speaks USB itself.
public struct P21Command: Equatable, Sendable {
    public enum Access: Equatable, Sendable {
        /// Reads only. Safe to run without telling the user first.
        case read
        /// Changes device state. Only ever sent from an explicit user action.
        case write
    }

    public let arguments: [String]
    public let access: Access

    public init(_ arguments: [String], _ access: Access) {
        self.arguments = arguments
        self.access = access
    }

    public var label: String { (["p21ctl"] + arguments).joined(separator: " ") }

    // MARK: Reads

    public static let cameraList = P21Command(["camera", "list"], .read)
    public static let audioStatus = P21Command(["audio", "status"], .read)
    public static let lightsList = P21Command(["lights", "list"], .read)

    // MARK: Lights

    /// Live, independently verified side-light brightness. Rounds up to 10% steps.
    public static func sides(left: Int, right: Int) -> P21Command {
        P21Command(["lights", "sides", String(left), String(right)], .write)
    }

    /// Immediate bottom-bar colour. The helper writes once and verifies the registers.
    public static func rgb(red: Int, green: Int, blue: Int) -> P21Command {
        P21Command(["lights", "rgb", String(red), String(green), String(blue)], .write)
    }

    public static func fade(_ level: Int) -> P21Command {
        P21Command(["lights", "fade", String(level)], .write)
    }

    // MARK: Camera

    public static func camera(_ control: String, values: [Int]) -> P21Command {
        P21Command(["camera", control] + values.map(String.init), .write)
    }

    // MARK: Audio

    public static func audioVolume(input: Bool, percent: Int) -> P21Command {
        P21Command(["audio", input ? "mic-volume" : "speaker-volume", String(percent)], .write)
    }

    public static func audioMute(input: Bool, muted: Bool) -> P21Command {
        P21Command(["audio", input ? "mic-mute" : "speaker-mute", muted ? "on" : "off"], .write)
    }

    public static func audioDefault(input: Bool) -> P21Command {
        P21Command(["audio", input ? "default-input" : "default-output"], .write)
    }
}
