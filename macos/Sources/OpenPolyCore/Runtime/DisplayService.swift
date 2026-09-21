import CoreGraphics
import Foundation
import Observation
import Darwin
import OSLog

@Observable @MainActor
public final class DisplayService {
    public enum State: String, Sendable { case stopped, starting, running, waiting, stopping, permission, failed }
    public private(set) var state: State = .stopped
    public private(set) var message = "Use OpenPoly to drive your P21 display."
    public private(set) var updatesPerSecond = 0.0
    public private(set) var megabytesPerSecond = 0.0
    public private(set) var enabled: Bool
    public var selectedResolution: DisplayResolution
    public var selectedRefreshRate: Int
    public private(set) var activeResolution: DisplayResolution?
    public private(set) var activeRefreshRate: Int?
    public private(set) var brightness: Double?
    public private(set) var brightnessError: String?
    public private(set) var settingsError: String?
    public var hasModeChanges: Bool { activeResolution != selectedResolution || activeRefreshRate != selectedRefreshRate }
    public var isActive: Bool { process != nil }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.openpoly.OpenPoly", category: "Display")
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var buffer = Data()
    private var runID: UUID?
    private var stopRequested = false
    private var lastError = ""
    private var brightnessTask: Task<Void, Never>?
    private var requestedScreenPermission = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "OpenPolyDisplayEnabled")
        selectedResolution = DisplayResolution(rawValue: defaults.string(forKey: "OpenPolyDisplayResolution") ?? "") ?? .fullHD
        let refresh = defaults.integer(forKey: "OpenPolyDisplayRefreshRate")
        selectedRefreshRate = [30, 60].contains(refresh) ? refresh : 60
    }

    public func applySettings() {
        guard [30, 60].contains(selectedRefreshRate) else { return }
        defaults.set(selectedResolution.rawValue, forKey: "OpenPolyDisplayResolution")
        defaults.set(selectedRefreshRate, forKey: "OpenPolyDisplayRefreshRate")
        settingsError = nil
        if isActive {
            send(["command": "settings", "width": selectedResolution.width,
                  "height": selectedResolution.height, "refreshHz": selectedRefreshRate])
        }
    }

    public func setBrightness(_ percent: Double) {
        guard state == .running, percent.isFinite, (0...100).contains(percent) else { return }
        brightnessTask?.cancel()
        brightnessTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, self.state == .running else { return }
            self.brightnessError = nil
            self.send(["command": "brightness", "percent": Int(percent.rounded())])
        }
    }

    private func send(_ command: [String: Any]) {
        guard let handle = input?.fileHandleForWriting, !stopRequested else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: command)
            data.append(10)
            try handle.write(contentsOf: data)
        } catch { settingsError = "Could not send display settings. Start the display again." }
    }

    public func startIfEnabled() {
        guard enabled else { return }
        guard CGPreflightScreenCaptureAccess() else {
            state = .permission
            message = "Allow Screen Recording for OpenPoly to use the display."
            return
        }
        start()
    }

    public func start() {
        guard process == nil else { return }
        enabled = true
        defaults.set(true, forKey: "OpenPolyDisplayEnabled")
        var permitted = CGPreflightScreenCaptureAccess()
        if !permitted && !requestedScreenPermission {
            // Repeated checks must not keep opening the system permission prompt.
            // A grant for an old ad-hoc build can remain visible in Settings even
            // though TCC rejects its obsolete code requirement.
            requestedScreenPermission = true
            permitted = CGRequestScreenCaptureAccess()
        }
        guard permitted else {
            logger.notice("Screen Recording permission is required")
            state = .permission
            message = "Allow OpenPoly in Screen Recording settings, then check permission again. If it is already enabled, quit and reopen OpenPoly."
            return
        }
        guard let node = Bundle.main.url(forAuxiliaryExecutable: "openpoly-display-runtime"),
              let script = Bundle.main.resourceURL?.appendingPathComponent("DisplayDriver/p21-display.cjs"),
              FileManager.default.fileExists(atPath: script.path) else {
            state = .failed
            message = "The bundled display helper is missing. Rebuild or reinstall OpenPoly."
            return
        }
        let task = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe(), id = UUID()
        applySettings()
        task.executableURL = node
        task.arguments = [script.path, "--run", "--take-over", "--parent-pipe",
                          "--resolution", selectedResolution.rawValue, "--refresh", String(selectedRefreshRate)]
        if let saved = defaults.object(forKey: "OpenPolyDisplayBrightness") as? Int, (0...100).contains(saved) {
            task.arguments?.append(contentsOf: ["--brightness", String(saved)])
        }
        // A helper exiting during a settings write must become a recoverable
        // pipe error, rather than terminating the entire menu-bar app.
        signal(SIGPIPE, SIG_IGN)
        var environment = ProcessInfo.processInfo.environment
        environment["OPENPOLY_DISPLAY_BIN"] = node.deletingLastPathComponent().path
        // A user-installed Node configuration must not alter the bundled helper.
        environment.removeValue(forKey: "NODE_OPTIONS")
        environment.removeValue(forKey: "NODE_PATH")
        task.environment = environment
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        input = stdin; output = stdout; errors = stderr; process = task; runID = id
        stopRequested = false; buffer.removeAll(); lastError = ""
        brightness = nil; brightnessError = nil; settingsError = nil
        state = .starting; message = "Connecting the display…"
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data, id: id) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.runID == id else { return }
                self.lastError = String((self.lastError + String(decoding: data, as: UTF8.self)).suffix(4096))
            }
        }
        task.terminationHandler = { [weak self] task in
            let code = task.terminationStatus
            Task { @MainActor in self?.ended(id: id, code: code) }
        }
        do { try task.run(); logger.notice("Display helper started") }
        catch { lastError = error.localizedDescription; ended(id: id, code: -1) }
    }

    public func stop(persist: Bool = true) {
        brightnessTask?.cancel(); brightnessTask = nil
        if persist { enabled = false; defaults.set(false, forKey: "OpenPolyDisplayEnabled") }
        guard let task = process, let id = runID else { state = .stopped; message = "Display stopped"; return }
        stopRequested = true; state = .stopping; message = "Stopping the display…"
        logger.notice("Stopping display helper")
        try? input?.fileHandleForWriting.close()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.runID == id, task.isRunning else { return }
            task.terminate()
            try? await Task.sleep(for: .seconds(2))
            if self.runID == id, task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
    }

    public func shutdown() async {
        stop(persist: false)
        for _ in 0..<140 {
            if process == nil { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func receive(_ data: Data, id: UUID) {
        guard runID == id, !data.isEmpty else { return }
        buffer.append(data)
        guard buffer.count <= 65_536 else { lastError = "Invalid display helper output"; stop(persist: false); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                if let value = event["state"] as? String, let next = State(rawValue: value), !stopRequested {
                    logger.notice("Display state: \(value, privacy: .public)")
                    state = next
                    if next == .running, let width = event["width"] as? Int, let height = event["height"] as? Int {
                        activeResolution = DisplayResolution(rawValue: "\(width)x\(height)")
                        activeRefreshRate = event["refreshHz"] as? Int
                    }
                    if let text = event["message"] as? String { message = text }
                }
                if event["event"] as? String == "statistics" {
                    updatesPerSecond = event["fps"] as? Double ?? 0
                    megabytesPerSecond = event["megabytesPerSecond"] as? Double ?? 0
                }
                if event["event"] as? String == "brightness", let percent = event["percent"] as? Double {
                    brightness = percent; brightnessError = nil
                    if event["requestedPercent"] is NSNumber {
                        defaults.set(Int(percent), forKey: "OpenPolyDisplayBrightness")
                    }
                }
                if event["event"] as? String == "brightness-error" {
                    brightnessError = "Brightness could not be verified. Try again after reconnecting the P21."
                }
                if event["event"] as? String == "settings-error" { settingsError = event["message"] as? String }
            }
            buffer.removeSubrange(...newline)
        }
    }

    private func ended(id: UUID, code: Int32) {
        guard runID == id else { return }
        logger.notice("Display helper exited: \(code)")
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        input = nil; output = nil; errors = nil; process = nil; runID = nil
        updatesPerSecond = 0; megabytesPerSecond = 0
        activeResolution = nil; activeRefreshRate = nil; brightness = nil
        brightnessTask?.cancel(); brightnessTask = nil
        if stopRequested || code == 0 { state = .stopped; message = "Display stopped" }
        else {
            if state != .failed { message = lastError.isEmpty ? "The display helper stopped. Start the display to retry." : lastError.trimmingCharacters(in: .whitespacesAndNewlines) }
            state = .failed
        }
    }
}
