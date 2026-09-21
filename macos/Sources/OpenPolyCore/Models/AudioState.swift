import Foundation

/// One channel of a CoreAudio volume or mute property.
public struct AudioChannel: Equatable, Identifiable, Sendable {
    public let channel: UInt32
    public let value: Double
    public let writable: Bool
    public var id: UInt32 { channel }
}

/// What `p21ctl audio status` actually reported for the P21 microphone and speaker.
public struct AudioState: Equatable, Sendable {
    public var micDevice: UInt32?
    public var micChannelCount: Int?
    public var micVolume: [AudioChannel] = []
    public var micMute: [AudioChannel] = []
    public var speakerDevice: UInt32?
    public var speakerChannelCount: Int?
    public var speakerVolume: [AudioChannel] = []
    public var speakerMute: [AudioChannel] = []

    public init() {}

    public static let empty = AudioState()

    public var isPresent: Bool { micDevice != nil || speakerDevice != nil }

    /// Volume as a 0...100 percentage. Channels are written together by the helper,
    /// so a single representative value is enough for the control surface.
    public func volume(input: Bool) -> Double? { (input ? micVolume : speakerVolume).first?.value }
    public func isMuted(input: Bool) -> Bool? { (input ? micMute : speakerMute).first.map { $0.value != 0 } }
    public func volumeWritable(input: Bool) -> Bool {
        (input ? micVolume : speakerVolume).contains { $0.writable }
    }
    public func muteWritable(input: Bool) -> Bool {
        (input ? micMute : speakerMute).contains { $0.writable }
    }

    /// True when every channel the helper would touch can be written.
    public func allChannelsWritable(input: Bool, mute: Bool) -> Bool {
        let channels = mute ? (input ? micMute : speakerMute) : (input ? micVolume : speakerVolume)
        return !channels.isEmpty && channels.allSatisfy(\.writable)
    }
}
