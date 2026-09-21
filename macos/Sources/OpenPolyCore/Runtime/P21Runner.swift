import Foundation

/// The outcome of one helper invocation.
public struct P21Result: Equatable, Sendable {
    public var command: P21Command
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var launchError: String?

    public init(
        command: P21Command,
        exitCode: Int32,
        stdout: String = "",
        stderr: String = "",
        timedOut: Bool = false,
        launchError: String? = nil
    ) {
        self.command = command
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.launchError = launchError
    }

    public var succeeded: Bool { launchError == nil && !timedOut && exitCode == 0 }
}

/// Anything that can run a helper command. Tests swap in a scripted runner.
public protocol P21Running: Sendable {
    func run(_ command: P21Command, timeout: TimeInterval) async -> P21Result
}

/// Runs the bundled helper off the main actor, one command at a time.
///
/// Commands are chained so a second request can never overlap the first, which is
/// what the P21 vendor protocol needs. Each run is bounded: a command that
/// outstays its timeout is terminated (SIGTERM first, so the helper can restore
/// the device, then SIGKILL).
public actor P21ProcessRunner: P21Running {
    private let executableURL: URL
    private var tail: Task<Void, Never>?

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    public func run(_ command: P21Command, timeout: TimeInterval) async -> P21Result {
        let previous = tail
        let executableURL = self.executableURL
        let work = Task<P21Result, Never> {
            if let previous { await previous.value }
            return await P21ProcessRunner.execute(
                executableURL: executableURL,
                command: command,
                timeout: timeout
            )
        }
        tail = Task { _ = await work.value }
        return await work.value
    }

    nonisolated static func execute(
        executableURL: URL,
        command: P21Command,
        timeout: TimeInterval
    ) async -> P21Result {
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory
            .appendingPathComponent("openpoly-\(UUID().uuidString)", isDirectory: true)

        do {
            try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return P21Result(
                command: command,
                exitCode: -1,
                launchError: "Cannot create a scratch directory: \(error.localizedDescription)"
            )
        }
        defer { try? manager.removeItem(at: scratch) }

        // Output goes to files rather than pipes: the helper can print a lot of
        // readback lines, and a full pipe would deadlock a bounded run.
        let outURL = scratch.appendingPathComponent("stdout")
        let errURL = scratch.appendingPathComponent("stderr")
        guard manager.createFile(atPath: outURL.path, contents: nil),
              manager.createFile(atPath: errURL.path, contents: nil),
              let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return P21Result(
                command: command,
                exitCode: -1,
                launchError: "Cannot open scratch files for helper output"
            )
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = command.arguments
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            return P21Result(
                command: command,
                exitCode: -1,
                launchError: "Cannot run \(executableURL.lastPathComponent): \(error.localizedDescription)"
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }

        if timedOut {
            let graceDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < graceDeadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        try? outHandle.close()
        try? errHandle.close()

        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        let exitCode: Int32 = process.isRunning ? 137 : process.terminationStatus

        return P21Result(
            command: command,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }
}

/// How a failure should change the app's state.
public enum P21Failure: Equatable, Sendable {
    case none
    case deviceAbsent
    /// USB transport failed or stalled. New hardware commands wait for the user.
    case usbStall
    /// Another P21 tool holds the vendor lock. Worth retrying, nothing to latch.
    case busy
    case other
}

public enum P21Diagnostics {
    /// stderr fragments the helper uses for the two conditions worth special-casing.
    static let deviceAbsentMarkers = [
        "matching devices: 0",
        "Expected one P21 input device; found 0",
        "Expected one P21 output device; found 0",
        "Expected one P21 display",
    ]

    static let stallMarkers = [
        "P21 USB",
        "stopping transfers",
        "LIBUSB_ERROR_TIMEOUT",
        "LIBUSB_ERROR_NO_DEVICE",
        "LIBUSB_ERROR_IO",
        "LIBUSB_ERROR_PIPE",
        "LIBUSB_ERROR_OTHER",
        "No matching BR response",
        "LED bridge failed",
    ]

    static let busyMarkers = [
        "Cannot acquire P21 vendor-control lock",
    ]

    public static func classify(_ result: P21Result) -> P21Failure {
        if result.succeeded { return .none }
        if result.timedOut { return .usbStall }
        for marker in busyMarkers where result.stderr.contains(marker) { return .busy }
        for marker in deviceAbsentMarkers where result.stderr.contains(marker) { return .deviceAbsent }
        for marker in stallMarkers where result.stderr.contains(marker) { return .usbStall }
        return .other
    }

    /// One honest sentence for the status strip. Never invents a success.
    public static func summary(_ result: P21Result, failure: P21Failure) -> String {
        if let launchError = result.launchError { return launchError }
        switch failure {
        case .none:
            return "Done"
        case .deviceAbsent:
            return "No Poly Studio P21 is connected."
        case .usbStall:
            if result.timedOut {
                return "The P21 stopped answering within \(Int(result.command.access == .read ? 45 : 25)) seconds. Reconnect or power-cycle it, then retry."
            }
            return "The P21 USB transport stopped responding. Reconnect or power-cycle it before sending more commands."
        case .busy:
            return "Another Poly tool is holding the P21 control lock. Close it and refresh."
        case .other:
            let line = result.stderr
                .split(separator: "\n")
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            if let line { return String(line) }
            return "The helper exited with status \(result.exitCode)."
        }
    }
}

/// Finds the bundled helper. The app ships `p21ctl` inside its own bundle.
public enum P21HelperLocator {
    public static let environmentOverride = "OPENPOLY_HELPER"

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> URL? {
        if let override = environment[environmentOverride], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        if let url = bundle.url(forAuxiliaryExecutable: "p21ctl") { return url }
        return nil
    }
}
