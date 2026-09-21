import Foundation
import Observation

/// The honest device state shown to the user. Nothing here is inferred from a
/// timer or a reconnect: it is the result of the last helper command.
@MainActor
@Observable
public final class ControlStore {
    public struct CameraPreviewToken: Hashable, Sendable {
        fileprivate let id: UUID
    }

    public enum Connection: Equatable, Sendable {
        case unknown
        case ready
        case noDevice
        case failed
        /// USB failed or stalled. No further hardware commands until the user retries.
        case latched
    }

    public struct Outcome: Equatable, Sendable {
        public enum Level: Equatable, Sendable {
            case success
            case warning
            case failure
        }
        public var level: Level
        public var message: String
        public var command: String?
    }

    public static let readTimeout: TimeInterval = 45
    public static let writeTimeout: TimeInterval = 25

    // MARK: Observed state

    public private(set) var connection: Connection = .unknown
    public private(set) var statusMessage = "Not checked yet."
    public private(set) var activity: String?
    public private(set) var isWorking = false
    public private(set) var lastUpdated: Date?
    public private(set) var outcome: Outcome?

    public private(set) var cameraControls: [CameraControl] = []
    public private(set) var cameraNote: String?
    public private(set) var audio = AudioState.empty
    public private(set) var lights = LightsStoredState.empty

    /// Live verification results. These are the only values the UI may call live.
    public private(set) var sidesVerified: SidesVerification?
    public private(set) var rgbApplied: P21Color?
    public private(set) var fadeApplied: Int?

    // MARK: Drafts (user edits, not device state)

    public var draftLeft: Double = 50 { didSet { rememberSideIntent() } }
    public var draftRight: Double = 50 { didSet { rememberSideIntent() } }
    public var draftFade: Double = 0
    public var draftRGB = P21Color(red: 80, green: 60, blue: 255) {
        didSet {
            if draftRGB != rgbApplied { rgbApplied = nil }
        }
    }

    private let runner: any P21Running
    private let helperPath: String?
    private struct SideLevels: Equatable, Sendable { var left: Int; var right: Int }
    private var sideIntent: SideLevels?
    private var sideIntentIsExplicit = false
    private var sideIntentVersion = 0
    private var loadingSideDrafts = false
    private var activePreview: CameraPreviewToken?

    public init(runner: any P21Running, helperPath: String? = nil) {
        self.runner = runner
        self.helperPath = helperPath
        if helperPath == nil {
            connection = .failed
            statusMessage = "The bundled p21ctl helper is missing from this app."
        }
    }

    /// The production store: bundled helper, real process runner.
    public static func live() -> ControlStore {
        guard let helper = P21HelperLocator.locate() else {
            return ControlStore(runner: P21ProcessRunner(executableURL: URL(fileURLWithPath: "/nonexistent")), helperPath: nil)
        }
        return ControlStore(runner: P21ProcessRunner(executableURL: helper), helperPath: helper.path)
    }

    public var canSendHardwareCommands: Bool {
        connection == .ready && !isWorking
    }

    public var visibleCameraControls: [CameraControl] {
        cameraControls.filter { !CameraCatalog.hidden.contains($0.name) }
    }

    public var canAdjustPanTilt: Bool {
        cameraControls.first { $0.name == "zoom" }?.current?.first.map { $0 > 10 } ?? false
    }

    public func canResetCameraGroup(_ group: String) -> Bool {
        cameraControls.contains {
            !CameraCatalog.hidden.contains($0.name) && $0.info.group == group && $0.validatedDefault != nil
        }
    }

    private func rememberSideIntent() {
        guard !loadingSideDrafts else { return }
        let levels = SideLevels(left: Int(draftLeft), right: Int(draftRight))
        if sideIntent != levels { sideIntentVersion += 1 }
        sideIntent = levels
        sideIntentIsExplicit = true
    }

    private func adoptStoredSides() {
        guard !sideIntentIsExplicit,
              let left = lights.percent("left"), let right = lights.percent("right") else { return }
        let levels = SideLevels(left: left, right: right)
        if sideIntent != levels { sideIntentVersion += 1 }
        sideIntent = levels
        loadingSideDrafts = true
        draftLeft = Double(left)
        draftRight = Double(right)
        loadingSideDrafts = false
    }

    // MARK: - Reads

    /// First read for a freshly opened surface. Never writes to the device.
    public func refreshIfNeeded() async {
        guard lastUpdated == nil, connection != .latched else { return }
        await refresh()
    }

    /// Manual refresh. Read-only, so it is safe to run at any time.
    public func refresh() async {
        guard !isWorking else { return }
        guard helperPath != nil else {
            connection = .failed
            statusMessage = "The bundled p21ctl helper is missing from this app."
            outcome = Outcome(level: .failure, message: statusMessage)
            return
        }
        if connection == .latched {
            outcome = Outcome(
                level: .warning,
                message: "Command traffic is paused after a USB failure. Reconnect the P21, then use Retry connection."
            )
            return
        }

        isWorking = true
        activity = "Reading the P21"
        defer { isWorking = false; activity = nil }

        cameraLatchReason = nil
        var problems: [String] = []

        // CoreAudio first: this needs no USB vendor access.
        let audioResult = await runner.run(.audioStatus, timeout: Self.readTimeout)
        let audioFailure = P21Diagnostics.classify(audioResult)
        if audioFailure == .none {
            audio = P21Parser.audioState(audioResult.stdout)
        } else {
            audio = .empty
            problems.append(P21Diagnostics.summary(audioResult, failure: audioFailure))
        }

        let lightsResult = await runner.run(.lightsList, timeout: Self.readTimeout)
        let lightsFailure = P21Diagnostics.classify(lightsResult)
        if lightsFailure == .none {
            lights = P21Parser.lightsStored(lightsResult.stdout)
            adoptStoredSides()
        } else {
            lights = .empty
            problems.append(P21Diagnostics.summary(lightsResult, failure: lightsFailure))
        }

        let connectionFromLights: Connection
        switch lightsFailure {
        case .none: connectionFromLights = .ready
        case .deviceAbsent: connectionFromLights = .noDevice
        case .usbStall: connectionFromLights = .latched
        case .busy, .other: connectionFromLights = .failed
        }

        if connectionFromLights == .ready {
            await readCameraControls(&problems)
        } else {
            cameraControls = []
            cameraNote = nil
        }

        // A camera read can turn a good connection into a latched one.
        connection = cameraLatchReason ?? connectionFromLights

        lastUpdated = Date()
        statusMessage = problems.isEmpty
            ? "Read from the device. Values are the last hardware readback."
            : problems.joined(separator: " ")
        if problems.isEmpty {
            outcome = nil
        } else {
            outcome = Outcome(level: connection == .ready ? .warning : .failure, message: problems.joined(separator: " "))
        }
    }

    /// Set while reading camera controls if the transport itself failed.
    private var cameraLatchReason: Connection?

    private func readCameraControls(_ problems: inout [String]) async {
        cameraLatchReason = nil
        let result = await runner.run(.cameraList, timeout: Self.readTimeout)
        let parsed = P21Parser.cameraControls(result.stdout)

        if result.timedOut {
            cameraControls = []
            cameraNote = nil
            cameraLatchReason = .latched
            problems.append(P21Diagnostics.summary(result, failure: .usbStall))
            return
        }

        if !parsed.isEmpty {
            cameraControls = parsed
            let unavailable = parsed.filter { !$0.isAvailable }.count
            if unavailable > 0 {
                cameraNote = "\(unavailable) control\(unavailable == 1 ? "" : "s") did not answer and \(unavailable == 1 ? "is" : "are") not shown."
                problems.append("Some camera controls did not answer; the controls that answered are shown.")
            } else {
                cameraNote = nil
            }
            return
        }

        cameraControls = []
        cameraNote = nil
        let failure = P21Diagnostics.classify(result)
        if failure == .deviceAbsent { cameraLatchReason = .noDevice }
        else if failure == .usbStall { cameraLatchReason = .latched }
        else { cameraLatchReason = .failed }
        problems.append(P21Diagnostics.summary(result, failure: failure))
    }

    /// Clears a USB latch and re-reads. Read-only, and the only way out of a latch.
    public func retryConnection() async {
        guard !isWorking else { return }
        connection = .unknown
        statusMessage = "Rechecking the P21."
        await refresh()
    }

    // MARK: - Lights

    public enum LightingChange: Hashable { case sides, rgb, fade }
    private var pendingLighting: [LightingChange: Task<Void, Never>] = [:]

    /// Coalesce input changes, then wait for any in-flight hardware transaction.
    /// Newer values replace queued values; startup/refresh never call this path.
    public func scheduleLighting(_ change: LightingChange) {
        pendingLighting[change]?.cancel()
        pendingLighting[change] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            guard let self else { return }
            guard !Task.isCancelled, self.connection == .ready else { return }
            switch change {
            case .sides: await self.applySides()
            case .rgb: await self.applyRGB(self.draftRGB)
            case .fade: await self.applyFade()
            }
        }
    }

    public func applySides() async {
        let requestedLeft = draftLeft
        let requestedRight = draftRight
        let left = Int(requestedLeft)
        let right = Int(requestedRight)
        let command = P21Command.sides(left: left, right: right)
        guard let result = await runWrite(command, activity: "Setting side lights") else { return }

        sidesVerified = P21Parser.sidesVerification(result.stdout)
        let verified = sidesVerified
        if let left = verified?.left, draftLeft == requestedLeft { draftLeft = Double(left) }
        if let right = verified?.right, draftRight == requestedRight { draftRight = Double(right) }
        if verified?.left == nil && verified?.right == nil {
            report(
                .success,
                "Side lights set to \(left)% and \(right)%. The helper reported success without a per-side verification line.",
                command
            )
        } else {
            report(
                .success,
                "Side lights verified live: left \(verified?.left.map(String.init) ?? "?")%, right \(verified?.right.map(String.init) ?? "?")%.",
                command
            )
        }
    }

    public func applyRGB(_ color: P21Color) async {
        let command = P21Command.rgb(red: color.red, green: color.green, blue: color.blue)
        guard let result = await runWrite(command, activity: "Applying bottom-bar colour") else { return }

        rgbApplied = color
        let note = result.stdout.split(separator: "\n").last.map(String.init) ?? "Bottom bar updated."
        report(.success, "\(note) Verified \(color.hex).", command)
    }

    public func turnBottomBarOff() async {
        draftRGB = .off
        await applyRGB(.off)
    }

    public func applyFade() async {
        let level = Int(draftFade)
        let command = P21Command.fade(level)
        guard let result = await runWrite(command, activity: "Setting bottom-bar fade") else { return }
        fadeApplied = level
        let note = result.stdout.split(separator: "\n").last.map(String.init) ?? "Fade updated."
        report(.success, "\(note) Fade level \(level).", command)
    }

    // MARK: - Camera preview light restoration

    /// Marks a new preview generation. A later generation supersedes this token,
    /// which prevents a delayed stop from restoring lights during a new preview.
    public func prepareCameraPreview() -> CameraPreviewToken {
        let token = CameraPreviewToken(id: UUID())
        activePreview = token
        return token
    }

    /// Cancels a preview that never started, for example after capture permission
    /// was denied or AVFoundation could not open a session.
    public func cancelCameraPreview(_ token: CameraPreviewToken) {
        guard activePreview == token else { return }
        activePreview = nil
    }

    /// Restores side-light intent only after AVFoundation confirms that a real
    /// capture session has stopped. The token is consumed up front, making calls
    /// from both `onDisappear` and model deinitialization idempotent.
    public func cameraPreviewDidStop(
        _ token: CameraPreviewToken,
        captureStarted: Bool
    ) async {
        guard activePreview == token else { return }
        activePreview = nil
        guard captureStarted else { return }

        guard let intended = sideIntent else {
            outcome = Outcome(
                level: .failure,
                message: "Side lights could not be restored after closing the camera because no explicit setting or firmware readback is available."
            )
            return
        }

        let version = sideIntentVersion
        let command = P21Command.sides(left: intended.left, right: intended.right)
        let stillCurrent = {
            self.activePreview == nil &&
            self.sideIntentVersion == version &&
            self.sideIntent == intended
        }
        guard await beginOperation(
            command,
            activity: "Restoring side lights after camera preview",
            stillValid: stillCurrent
        ) else {
            if stillCurrent() {
                let reason = outcome?.message ?? "The device is not ready."
                outcome = Outcome(
                    level: .failure,
                    message: "Side lights could not be restored after closing the camera. \(reason)",
                    command: command.label
                )
            }
            return
        }
        defer { endOperation() }

        guard let result = await executeWrite(command) else {
            let reason = outcome?.message ?? "The helper did not confirm the write."
            outcome = Outcome(
                level: .failure,
                message: "Side lights could not be restored after closing the camera. \(reason)",
                command: command.label
            )
            return
        }

        sidesVerified = P21Parser.sidesVerification(result.stdout)
        if sideIntentVersion == version, sideIntent == intended {
            let restored = SideLevels(
                left: sidesVerified?.left ?? intended.left,
                right: sidesVerified?.right ?? intended.right
            )
            if sideIntent != restored { sideIntentVersion += 1 }
            sideIntent = restored
            loadingSideDrafts = true
            draftLeft = Double(restored.left)
            draftRight = Double(restored.right)
            loadingSideDrafts = false
        }
        report(
            .success,
            "Side lights were restored after closing the camera.",
            command
        )
    }

    // MARK: - Camera

    public func setCamera(_ control: CameraControl, values: [Int]) async {
        guard !values.isEmpty else { return }
        let command = P21Command.camera(control.name, values: values)
        guard await beginOperation(command, activity: "Setting \(control.title.lowercased())") else { return }
        defer { endOperation() }

        let latest = cameraControls.first(where: { $0.name == control.name }) ?? control
        guard validateCameraEdit(latest, values: values, command: command) else { return }
        guard let result = await executeWrite(command) else { return }
        reportCameraWrite(result, fallback: latest, command: command)

        // Automatic mode changes alter the writability of sibling controls. Keep
        // the operation slot until this read completes so another write cannot
        // race against stale capabilities.
        if control.name == "auto-exposure" || control.name == "auto-white-balance" {
            activity = "Updating camera controls"
            var problems: [String] = []
            await readCameraControls(&problems)
            if let latch = cameraLatchReason { connection = latch }
            if !problems.isEmpty {
                outcome = Outcome(
                    level: connection == .ready ? .warning : .failure,
                    message: problems.joined(separator: " ")
                )
            }
        }
    }

    /// Edits one component of a multi-value control after acquiring the write
    /// slot. This preserves the latest value of every sibling component when pan
    /// and tilt changes arrive close together.
    public func setCameraComponent(_ controlName: String, index: Int, value: Int) async {
        let placeholder = P21Command.camera(controlName, values: [value])
        guard await beginOperation(placeholder, activity: "Setting camera framing") else { return }
        defer { endOperation() }

        guard let control = cameraControls.first(where: { $0.name == controlName }),
              var values = control.current,
              values.indices.contains(index) else {
            outcome = Outcome(
                level: .warning,
                message: "The camera no longer reports that control component.",
                command: placeholder.label
            )
            return
        }
        values[index] = value
        let command = P21Command.camera(controlName, values: values)
        guard validateCameraEdit(control, values: values, command: command) else { return }
        guard let result = await executeWrite(command) else { return }
        reportCameraWrite(result, fallback: control, command: command)
    }

    /// Restores every valid device-reported default in one camera group. Known
    /// automatic dependencies are unlocked before dependent controls and the
    /// group's automatic mode is restored last.
    public func resetCameraGroup(_ group: String) async {
        let operation = P21Command(["camera", "reset-group", group.lowercased()], .write)
        guard await beginOperation(operation, activity: "Resetting \(group.lowercased()) controls") else { return }
        defer { endOperation() }

        let controls = cameraControls.filter {
            !CameraCatalog.hidden.contains($0.name) && $0.info.group == group
        }
        guard !controls.isEmpty else {
            outcome = Outcome(level: .warning, message: "The camera reports no controls in the \(group) group.")
            return
        }

        var resettable: [String: CameraControl] = [:]
        var skipped: [String] = []
        for control in controls {
            if control.validatedDefault != nil {
                resettable[control.name] = control
            } else {
                skipped.append(cameraDefaultIssue(control))
            }
        }

        var applied: [String] = []
        var blocked = Set<String>()
        var externalRestores: [(control: CameraControl, values: [Int])] = []
        let automaticNames: Set<String> = ["auto-exposure", "auto-white-balance"]
        let groupAutomatic = controls.filter {
            automaticNames.contains($0.name) && resettable[$0.name] != nil
        }

        // Work out every dependency before applying any defaults, then unlock
        // each dependency once. Dependencies outside this group are restored to
        // their current value so resetting Image cannot also reset Exposure.
        var unlocked = Set<String>()
        for target in controls where resettable[target.name] != nil && target.disabledByAutomaticMode {
            guard let dependency = automaticDependency(for: target.name),
                  let automatic = cameraControls.first(where: { $0.name == dependency.name }),
                  automatic.isAvailable,
                  automatic.writable,
                  automatic.accepts(dependency.unlocked) else {
                blocked.insert(target.name)
                skipped.append("\(target.title): its automatic dependency cannot be unlocked")
                continue
            }

            if automatic.info.group == group,
               automatic.current != dependency.unlocked,
               automatic.validatedDefault == nil {
                blocked.insert(target.name)
                skipped.append("\(target.title): the camera reports no valid automatic-mode default")
                continue
            }
            if automatic.info.group != group,
               automatic.current != dependency.unlocked,
               (automatic.current == nil || !automatic.accepts(automatic.current!)) {
                blocked.insert(target.name)
                skipped.append("\(target.title): the external automatic mode cannot be restored safely")
                continue
            }
            guard automatic.current != dependency.unlocked else { continue }
            guard unlocked.insert(automatic.name).inserted else { continue }

            if automatic.info.group != group, let original = automatic.current {
                externalRestores.append((automatic, original))
            }
            guard await writeCameraControl(automatic, values: dependency.unlocked) else {
                await recoverAutomaticModesAfterResetFailure(
                    group: group,
                    failedControl: automatic,
                    externalRestores: externalRestores,
                    groupAutomatic: groupAutomatic
                )
                return
            }
        }

        if group == "Framing" {
            guard await resetFraming(
                controls: controls,
                resettable: resettable,
                blocked: blocked,
                applied: &applied,
                skipped: &skipped
            ) else { return }
        } else {
            for control in controls {
                guard let values = control.validatedDefault,
                      !automaticNames.contains(control.name),
                      !blocked.contains(control.name) else { continue }
                guard await writeCameraControl(control, values: values) else {
                    await recoverAutomaticModesAfterResetFailure(
                        group: group,
                        failedControl: control,
                        externalRestores: externalRestores,
                        groupAutomatic: groupAutomatic
                    )
                    return
                }
                applied.append(control.title)
            }
        }

        for restore in externalRestores.reversed() {
            guard await writeCameraControl(restore.control, values: restore.values) else {
                await recoverAutomaticModesAfterResetFailure(
                    group: group,
                    failedControl: restore.control,
                    externalRestores: externalRestores,
                    groupAutomatic: groupAutomatic
                )
                return
            }
        }

        for control in groupAutomatic {
            guard let values = control.validatedDefault else { continue }
            guard await writeCameraControl(control, values: values) else {
                await recoverAutomaticModesAfterResetFailure(
                    group: group,
                    failedControl: control,
                    externalRestores: [],
                    groupAutomatic: groupAutomatic
                )
                return
            }
            applied.append(control.title)
        }

        let appliedText = applied.isEmpty
            ? "No controls were reset."
            : "Reset \(applied.joined(separator: ", ")) to device-reported defaults."
        if skipped.isEmpty {
            outcome = Outcome(level: .success, message: appliedText)
        } else {
            outcome = Outcome(
                level: .failure,
                message: "\(appliedText) Skipped \(skipped.joined(separator: "; "))."
            )
        }
    }

    private func merge(_ control: CameraControl) {
        if let index = cameraControls.firstIndex(where: { $0.name == control.name }) {
            cameraControls[index] = control
        } else {
            cameraControls.append(control)
        }
    }

    private struct AutomaticDependency {
        var name: String
        var unlocked: [Int]
    }

    private func automaticDependency(for controlName: String) -> AutomaticDependency? {
        switch controlName {
        case "exposure", "gain":
            return AutomaticDependency(name: "auto-exposure", unlocked: [1])
        case "white-balance":
            return AutomaticDependency(name: "auto-white-balance", unlocked: [0])
        default:
            return nil
        }
    }

    private func cameraDefaultIssue(_ control: CameraControl) -> String {
        if let reason = control.unavailable { return "\(control.title): unavailable (\(reason))" }
        if !control.isAvailable { return "\(control.title): current readback unavailable" }
        if !control.writable { return "\(control.title): read-only" }
        guard let defaultValue = control.defaultValue else {
            return "\(control.title): no device-reported default"
        }
        if !control.accepts(defaultValue) {
            return "\(control.title): invalid device-reported default"
        }
        return "\(control.title): default unavailable"
    }

    private func validateCameraEdit(
        _ control: CameraControl,
        values: [Int],
        command: P21Command
    ) -> Bool {
        guard control.isEditable else {
            outcome = Outcome(
                level: .warning,
                message: "\(control.title) is not writable in the camera's current mode.",
                command: command.label
            )
            return false
        }
        guard control.accepts(values) else {
            outcome = Outcome(
                level: .warning,
                message: "The requested \(control.title.lowercased()) value is outside the range reported by the camera.",
                command: command.label
            )
            return false
        }
        if control.name == "pan-tilt", !canAdjustPanTilt {
            outcome = Outcome(
                level: .warning,
                message: "Pan and tilt require the camera's actual zoom to be above 1.0×.",
                command: command.label
            )
            return false
        }
        return true
    }

    private func writeCameraControl(_ control: CameraControl, values: [Int]) async -> Bool {
        let command = P21Command.camera(control.name, values: values)
        guard let result = await executeWrite(command) else { return false }
        if let updated = P21Parser.cameraControls(result.stdout).first(where: { $0.name == control.name }) {
            merge(updated)
        }
        return true
    }

    private func reportCameraWrite(
        _ result: P21Result,
        fallback control: CameraControl,
        command: P21Command
    ) {
        if let updated = P21Parser.cameraControls(result.stdout).first(where: { $0.name == control.name }) {
            merge(updated)
            let actual = updated.current?.map { updated.display($0) }.joined(separator: ", ") ?? "unknown"
            report(.success, "\(control.title) is now \(actual) on the hardware.", command)
        } else {
            report(.success, "\(control.title) write reported success.", command)
        }
    }

    private func markResetFailure(group: String, control: CameraControl) {
        let reason = outcome?.message ?? "The helper did not confirm the write."
        outcome = Outcome(
            level: .failure,
            message: "The \(group.lowercased()) reset stopped at \(control.title.lowercased()). \(reason)",
            command: outcome?.command
        )
    }

    private func recoverAutomaticModesAfterResetFailure(
        group: String,
        failedControl: CameraControl,
        externalRestores: [(control: CameraControl, values: [Int])],
        groupAutomatic: [CameraControl]
    ) async {
        let failureReason = outcome?.message ?? "The helper did not confirm the write."
        let failedCommand = outcome?.command
        let hasModesToRestore = !externalRestores.isEmpty || !groupAutomatic.isEmpty
        var recoveryFailures: [String] = []

        if connection == .ready {
            for restore in externalRestores.reversed() {
                if !(await writeCameraControl(restore.control, values: restore.values)) {
                    recoveryFailures.append(restore.control.title)
                    if connection != .ready { break }
                }
            }
            if connection == .ready {
                for automatic in groupAutomatic {
                    guard let values = automatic.validatedDefault else { continue }
                    if !(await writeCameraControl(automatic, values: values)) {
                        recoveryFailures.append(automatic.title)
                        if connection != .ready { break }
                    }
                }
            }
        } else if hasModesToRestore {
            recoveryFailures.append("automatic modes")
        }

        let recoveryNote: String
        if !hasModesToRestore {
            recoveryNote = ""
        } else if recoveryFailures.isEmpty {
            recoveryNote = " Automatic modes were restored after the failure."
        } else {
            recoveryNote = " Automatic-mode restoration could not be verified for \(recoveryFailures.joined(separator: ", "))."
        }
        outcome = Outcome(
            level: .failure,
            message: "The \(group.lowercased()) reset stopped at \(failedControl.title.lowercased()). \(failureReason)\(recoveryNote)",
            command: failedCommand
        )
    }

    private func resetFraming(
        controls: [CameraControl],
        resettable: [String: CameraControl],
        blocked: Set<String>,
        applied: inout [String],
        skipped: inout [String]
    ) async -> Bool {
        let zoom = controls.first(where: { $0.name == "zoom" })
        let panTilt = controls.first(where: { $0.name == "pan-tilt" })

        if let panTilt,
           let panDefault = panTilt.validatedDefault,
           !blocked.contains(panTilt.name) {
            guard let zoom,
                  zoom.isAvailable,
                  zoom.writable,
                  let currentZoom = zoom.current?.first else {
                skipped.append("\(panTilt.title): zoom readback is unavailable")
                return await finishFramingZoom(zoom, resettable: resettable, applied: &applied)
            }

            if currentZoom <= 10 {
                guard zoom.validatedDefault != nil,
                      let raisedZoom = firstValidZoomAboveTen(zoom) else {
                    skipped.append("\(panTilt.title): zoom cannot be raised and restored to a valid device default")
                    return await finishFramingZoom(zoom, resettable: resettable, applied: &applied)
                }
                guard await writeCameraControl(zoom, values: [raisedZoom]) else {
                    markResetFailure(group: "Framing", control: zoom)
                    return false
                }
                guard cameraControls.first(where: { $0.name == "zoom" })?.current?.first.map({ $0 > 10 }) == true else {
                    skipped.append("\(panTilt.title): the camera did not raise actual zoom above 1.0×")
                    return await finishFramingZoom(zoom, resettable: resettable, applied: &applied)
                }
            }

            guard await writeCameraControl(panTilt, values: panDefault) else {
                markResetFailure(group: "Framing", control: panTilt)
                return false
            }
            applied.append(panTilt.title)
        }

        return await finishFramingZoom(zoom, resettable: resettable, applied: &applied)
    }

    private func finishFramingZoom(
        _ zoom: CameraControl?,
        resettable: [String: CameraControl],
        applied: inout [String]
    ) async -> Bool {
        guard let zoom, resettable[zoom.name] != nil, let values = zoom.validatedDefault else { return true }
        guard await writeCameraControl(zoom, values: values) else {
            markResetFailure(group: "Framing", control: zoom)
            return false
        }
        applied.append(zoom.title)
        return true
    }

    private func firstValidZoomAboveTen(_ zoom: CameraControl) -> Int? {
        guard let low = zoom.minimum?.first,
              let high = zoom.maximum?.first,
              high > 10 else { return nil }
        let increment = max(zoom.step?.first ?? 1, 1)
        // The helper accepts a P21 zoom readback up to two raw units below the
        // request. Request at least 13 so an accepted readback is still > 10.
        let target = max(low, 13)
        let remainder = (target - low) % increment
        let candidate = remainder == 0 ? target : target + increment - remainder
        return candidate <= high && zoom.accepts([candidate]) ? candidate : nil
    }

    // MARK: - Audio

    public func setVolume(input: Bool, percent: Int) async {
        let command = P21Command.audioVolume(input: input, percent: percent)
        guard let result = await runWrite(command, activity: "Setting \(input ? "microphone" : "speaker") volume") else { return }
        mergeAudio(result.stdout)
        let actual = audio.volume(input: input).map { String(format: "%.0f%%", $0) } ?? "applied"
        report(.success, "\(input ? "Microphone" : "Speaker") volume is \(actual) on the hardware.", command)
    }

    public func setMute(input: Bool, muted: Bool) async {
        let command = P21Command.audioMute(input: input, muted: muted)
        guard let result = await runWrite(command, activity: muted ? "Muting" : "Unmuting") else { return }
        mergeAudio(result.stdout)
        let actual = audio.isMuted(input: input).map { $0 ? "muted" : "live" } ?? (muted ? "muted" : "live")
        report(.success, "\(input ? "Microphone" : "Speaker") is \(actual).", command)
    }

    public func makeDefault(input: Bool) async {
        let command = P21Command.audioDefault(input: input)
        guard let result = await runWrite(command, activity: "Setting the default \(input ? "input" : "output")") else { return }
        let note = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        report(.success, note.isEmpty ? "Default \(input ? "input" : "output") set to Poly Studio P21." : note, command)
    }

    private func mergeAudio(_ output: String) {
        let parsed = P21Parser.audioState(output)
        if !parsed.micVolume.isEmpty { audio.micVolume = parsed.micVolume }
        if !parsed.micMute.isEmpty { audio.micMute = parsed.micMute }
        if !parsed.speakerVolume.isEmpty { audio.speakerVolume = parsed.speakerVolume }
        if !parsed.speakerMute.isEmpty { audio.speakerMute = parsed.speakerMute }
    }

    // MARK: - Shared write path

    /// Waits for the current logical operation so rapid edits are serialized rather
    /// than rejected. Cancellation drops stale coalesced edits before they write.
    private func beginOperation(
        _ command: P21Command,
        activity label: String,
        stillValid: () -> Bool = { true }
    ) async -> Bool {
        while isWorking {
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return false }
        }
        guard !Task.isCancelled, stillValid() else { return false }
        guard connection == .ready else {
            let message: String
            switch connection {
            case .latched:
                message = "Commands are paused after a USB failure. Reconnect the P21 and use Retry connection."
            case .noDevice:
                message = "No Poly Studio P21 is connected."
            case .unknown:
                message = "Refresh first: the app has not read the P21 yet."
            case .failed:
                message = "The P21 could not be reached. Refresh after checking the connection."
            case .ready:
                message = "Not ready."
            }
            outcome = Outcome(level: .warning, message: message, command: command.label)
            return false
        }

        isWorking = true
        activity = label
        return true
    }

    private func endOperation() {
        isWorking = false
        activity = nil
    }

    /// Executes while the caller owns the logical-operation slot.
    private func executeWrite(_ command: P21Command) async -> P21Result? {
        let result = await runner.run(command, timeout: Self.writeTimeout)
        let failure = P21Diagnostics.classify(result)
        switch failure {
        case .none:
            return result
        case .deviceAbsent:
            connection = .noDevice
        case .usbStall:
            connection = .latched
        case .busy, .other:
            break
        }
        outcome = Outcome(
            level: .failure,
            message: P21Diagnostics.summary(result, failure: failure),
            command: command.label
        )
        return nil
    }

    private func runWrite(
        _ command: P21Command,
        activity label: String,
        stillValid: () -> Bool = { true }
    ) async -> P21Result? {
        guard await beginOperation(command, activity: label, stillValid: stillValid) else { return nil }
        defer { endOperation() }
        return await executeWrite(command)
    }

    private func report(_ level: Outcome.Level, _ message: String, _ command: P21Command) {
        outcome = Outcome(level: level, message: message, command: command.label)
    }
}
