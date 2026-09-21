import Foundation

/// A single `lights list` line: either a percentage for an LED or an on/off state
/// for a firmware event source.
public struct LightReading: Equatable, Identifiable, Sendable {
    public let name: String
    public let percent: Int?
    public let isOn: Bool?

    public var id: String { name }

    public init(name: String, percent: Int? = nil, isOn: Bool? = nil) {
        self.name = name
        self.percent = percent
        self.isOn = isOn
    }
}

/// Stored firmware light settings read back by `p21ctl lights list`.
///
/// These are the values the firmware holds, not a measurement of emitted light,
/// and the UI must say so.
public struct LightsStoredState: Equatable, Sendable {
    public var readings: [LightReading]

    public init(readings: [LightReading] = []) {
        self.readings = readings
    }

    public static let empty = LightsStoredState()

    public func percent(_ name: String) -> Int? {
        readings.first { $0.name == name }?.percent
    }

    public func isOn(_ name: String) -> Bool? {
        readings.first { $0.name == name }?.isOn
    }

    /// Firmware event sources that can override the lighting at any time.
    public static let events = ["manual", "sensor", "idle", "incoming", "active", "held", "charging"]
}

/// Result of a verified, live side-light write.
public struct SidesVerification: Equatable, Sendable {
    public var left: Int?
    public var right: Int?

    public init(left: Int? = nil, right: Int? = nil) {
        self.left = left
        self.right = right
    }
}

/// Bottom-bar colour. Stored as 8-bit components to match the helper's arguments.
public struct P21Color: Equatable, Sendable {
    public var red: Int
    public var green: Int
    public var blue: Int

    public init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let off = P21Color(red: 0, green: 0, blue: 0)

    public var isOff: Bool { red == 0 && green == 0 && blue == 0 }

    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// Curated swatches for the bottom bar: the two colours with physical
    /// confirmation plus even hue steps around the wheel.
    public static let swatches: [P21Color] = [
        P21Color(red: 255, green: 255, blue: 255),
        P21Color(red: 255, green: 0, blue: 0),
        P21Color(red: 255, green: 92, blue: 0),
        P21Color(red: 255, green: 200, blue: 0),
        P21Color(red: 0, green: 200, blue: 72),
        P21Color(red: 0, green: 170, blue: 255),
        P21Color(red: 90, green: 60, blue: 255),
        P21Color(red: 255, green: 0, blue: 192),
    ]
}
