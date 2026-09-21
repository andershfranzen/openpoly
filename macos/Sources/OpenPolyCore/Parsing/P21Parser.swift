import Foundation

/// Parses the helper's stdout. Every rule here is covered by OpenPolyCheck.
public enum P21Parser {

    // MARK: - Camera

    public static func cameraControls(_ output: String) -> [CameraControl] {
        output.split(separator: "\n").compactMap { cameraControl(String($0)) }
    }

    static func cameraControl(_ line: String) -> CameraControl? {
        let tokens = line.split(separator: " ").map(String.init)
        guard let name = tokens.first, !name.isEmpty else { return nil }

        var control = CameraControl(name: name)

        if tokens.count > 1, tokens[1] == "unavailable" {
            let reason = tokens.dropFirst(2).joined(separator: " ")
            control.unavailable = reason.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            return control
        }

        for token in tokens.dropFirst() {
            guard let separator = token.firstIndex(of: "=") else { continue }
            let key = String(token[token.startIndex..<separator])
            let raw = String(token[token.index(after: separator)...])
            switch key {
            case "current": control.current = integerList(raw)
            case "min": control.minimum = integerList(raw)
            case "max": control.maximum = integerList(raw)
            case "step": control.step = integerList(raw)
            case "default": control.defaultValue = integerList(raw)
            case "writable": control.writable = raw == "yes"
            default: break
            }
        }

        control.disabledByAutomaticMode = line.contains("(disabled by automatic mode)")
        return control
    }

    static func integerList(_ raw: String) -> [Int]? {
        let parts = raw.split(separator: ",")
        guard !parts.isEmpty else { return nil }
        var values: [Int] = []
        for part in parts {
            guard let value = Int(part) else { return nil }
            values.append(value)
        }
        return values
    }

    // MARK: - Audio

    public static func audioState(_ output: String) -> AudioState {
        var state = AudioState()

        for line in output.split(separator: "\n") {
            let tokens = line.split(separator: " ").map(String.init)
            guard let first = tokens.first else { continue }

            if first == "input" || first == "output" {
                let attributes = attributes(tokens.dropFirst())
                let input = first == "input"
                let device = attributes["device"].flatMap(UInt32.init)
                let channels = attributes["channels"].flatMap(Int.init)
                if input {
                    state.micDevice = device
                    state.micChannelCount = channels
                } else {
                    state.speakerDevice = device
                    state.speakerChannelCount = channels
                }
                continue
            }

            guard let separator = first.firstIndex(of: "=") else { continue }
            let key = String(first[first.startIndex..<separator])
            let raw = String(first[first.index(after: separator)...])
            let attributes = attributes(tokens.dropFirst())
            guard let channel = attributes["channel"].flatMap(UInt32.init) else { continue }
            let writable = attributes["writable"] == "yes"

            switch key {
            case "mic-volume":
                if let percent = percentValue(raw) {
                    state.micVolume.append(AudioChannel(channel: channel, value: percent, writable: writable))
                }
            case "mic-mute":
                if let muted = muteValue(raw) {
                    state.micMute.append(AudioChannel(channel: channel, value: muted ? 1 : 0, writable: writable))
                }
            case "speaker-volume":
                if let percent = percentValue(raw) {
                    state.speakerVolume.append(AudioChannel(channel: channel, value: percent, writable: writable))
                }
            case "speaker-mute":
                if let muted = muteValue(raw) {
                    state.speakerMute.append(AudioChannel(channel: channel, value: muted ? 1 : 0, writable: writable))
                }
            default:
                break
            }
        }

        return state
    }

    static func attributes<S: Sequence>(_ tokens: S) -> [String: String] where S.Element == String {
        var result: [String: String] = [:]
        for token in tokens {
            guard let separator = token.firstIndex(of: "=") else { continue }
            result[String(token[token.startIndex..<separator])] = String(token[token.index(after: separator)...])
        }
        return result
    }

    static func percentValue(_ raw: String) -> Double? {
        let trimmed = raw.hasSuffix("%") ? String(raw.dropLast()) : raw
        return Double(trimmed)
    }

    static func muteValue(_ raw: String) -> Bool? {
        switch raw {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    // MARK: - Lights

    public static func lightsStored(_ output: String) -> LightsStoredState {
        let readings = output.split(separator: "\n").compactMap { line -> LightReading? in
            let tokens = line.split(separator: " ").map(String.init)
            guard let first = tokens.first, let separator = first.firstIndex(of: "=") else { return nil }
            let name = String(first[first.startIndex..<separator])
            let raw = String(first[first.index(after: separator)...])
            if raw.hasSuffix("%"), let percent = Int(raw.dropLast()) {
                return LightReading(name: name, percent: percent)
            }
            switch raw {
            case "on": return LightReading(name: name, isOn: true)
            case "off": return LightReading(name: name, isOn: false)
            default: return nil
            }
        }
        return LightsStoredState(readings: readings)
    }

    /// Reads the helper's post-write verification line, for example
    /// `side-left=30% (live, verified)`.
    public static func sidesVerification(_ output: String) -> SidesVerification? {
        var verification = SidesVerification()
        for line in output.split(separator: "\n") {
            guard line.contains("(live, verified)") else { continue }
            guard let token = line.split(separator: " ").first else { continue }
            let text = String(token)
            if text.hasPrefix("side-left=") {
                verification.left = Int(text.dropFirst("side-left=".count).dropLast())
            } else if text.hasPrefix("side-right=") {
                verification.right = Int(text.dropFirst("side-right=".count).dropLast())
            }
        }
        return verification.left == nil && verification.right == nil ? nil : verification
    }
}
