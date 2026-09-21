import Foundation
import OpenPolyCore

/// Scripted stand-in for the helper. Records every command the store sends so the
/// checks can prove that refreshes stay read-only and that a latch stops traffic.
final class MockRunner: P21Running, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: P21Result] = [:]
    private var delays: [String: UInt64] = [:]
    private var fallback: ((P21Command) -> P21Result)?
    private var visited: [P21Command] = []

    func respond(
        _ command: P21Command,
        exitCode: Int32 = 0,
        stdout: String = "",
        stderr: String = "",
        timedOut: Bool = false
    ) {
        lock.lock()
        responses[command.label] = P21Result(
            command: command,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
        lock.unlock()
    }

    func respond(_ commands: [P21Command], exitCode: Int32 = 0, stdout: String = "", stderr: String = "") {
        for command in commands { respond(command, exitCode: exitCode, stdout: stdout, stderr: stderr) }
    }

    func setFallback(_ handler: @escaping (P21Command) -> P21Result) {
        lock.lock()
        fallback = handler
        lock.unlock()
    }

    func delay(_ command: P21Command, nanoseconds: UInt64) {
        lock.lock()
        delays[command.label] = nanoseconds
        lock.unlock()
    }

    var recorded: [P21Command] {
        lock.lock()
        defer { lock.unlock() }
        return visited
    }

    func run(_ command: P21Command, timeout: TimeInterval) async -> P21Result {
        let (scripted, handler, delay) = record(command)
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if let scripted { return scripted }
        if let handler { return handler(command) }
        return P21Result(command: command, exitCode: 1, stderr: "unmocked command: \(command.label)")
    }

    /// Synchronous so the lock is never held across a suspension point.
    private func record(_ command: P21Command) -> (P21Result?, ((P21Command) -> P21Result)?, UInt64) {
        lock.lock()
        defer { lock.unlock() }
        visited.append(command)
        return (responses[command.label], fallback, delays[command.label] ?? 0)
    }
}
