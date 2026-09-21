import Foundation
import OpenPolyCore

// Offline checks for the native app. They never open a device: parsing runs on
// captured helper output and the store runs against a scripted runner.
// SwiftPM's XCTest/Swift Testing frameworks are not present in this Command Line
// Tools install, so this small executable is the test entry point.

var checks = 0
var failures = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL: \(label)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label) (expected \(expected), got \(actual))")
    }
}

func section(_ name: String) { print("-- \(name)") }

func waitForCommand(_ command: P21Command, in runner: MockRunner) async -> Bool {
    for _ in 0..<100 {
        if runner.recorded.contains(command) { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

func waitForCommandCount(_ command: P21Command, count: Int, in runner: MockRunner) async -> Bool {
    for _ in 0..<100 {
        if runner.recorded.filter({ $0 == command }).count >= count { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

// MARK: - Camera parsing

section("camera parsing")
let cameraControls = P21Parser.cameraControls(Fixtures.camera)
checkEqual(cameraControls.count, 17, "every reported control is parsed")

func control(_ name: String) -> CameraControl? { cameraControls.first { $0.name == name } }

if let autoExposure = control("auto-exposure") {
    checkEqual(autoExposure.current, [8], "auto-exposure current")
    checkEqual(autoExposure.step, [9], "auto-exposure step is the mode bitmask")
    checkEqual(autoExposure.minimum, nil, "auto-exposure reports no range")
    checkEqual(autoExposure.kind, .modes([1, 8]), "auto-exposure offers its two modes")
    check(autoExposure.isEditable, "auto-exposure is editable")
} else {
    check(false, "auto-exposure present")
}

if let exposure = control("exposure") {
    checkEqual(exposure.minimum, [3], "exposure minimum")
    checkEqual(exposure.maximum, [2047], "exposure maximum")
    check(exposure.disabledByAutomaticMode, "exposure is flagged as auto-controlled")
    check(!exposure.isEditable, "auto-controlled exposure is not editable")
    checkEqual(exposure.kind, .slider(range: 3...2047, step: 1), "exposure slider")
} else {
    check(false, "exposure present")
}

if let zoom = control("zoom") {
    checkEqual(zoom.kind, .slider(range: 10...40, step: 1), "zoom slider")
    checkEqual(zoom.display(13), "1.3x", "zoom is displayed as a multiplier")
    checkEqual(zoom.current, [10], "zoom current")
} else {
    check(false, "zoom present")
}

if let panTilt = control("pan-tilt") {
    checkEqual(panTilt.kind, .pair(range: -36000...36000, step: 3600), "pan-tilt is a pair")
    checkEqual(panTilt.current, [0, 0], "pan-tilt has two components")
    checkEqual(panTilt.minimum, [-36000, -36000], "pan-tilt minimums")
} else {
    check(false, "pan-tilt present")
}

if let powerLine = control("power-line") {
    checkEqual(powerLine.kind, .modes([1, 2]), "power-line is a two-option menu")
    checkEqual(powerLine.display(2), "60 Hz", "power-line value 2 is 60 Hz")
} else {
    check(false, "power-line present")
}

if let whiteBalance = control("white-balance") {
    check(!whiteBalance.isAvailable, "an unread control is not available")
    checkEqual(whiteBalance.kind, .unsupported("LIBUSB_ERROR_TIMEOUT"), "unavailable control keeps its reason")
} else {
    check(false, "white-balance present")
}

checkEqual(control("exposure-priority")?.kind, .toggle, "exposure-priority is a toggle")
checkEqual(control("auto-white-balance")?.kind, .toggle, "auto-white-balance is a toggle")
checkEqual(control("gamma")?.kind, .slider(range: 1...255, step: 1), "gamma slider")
checkEqual(control("hue")?.kind, .slider(range: -128...128, step: 1), "hue keeps its negative range")
check(CameraCatalog.hidden.contains("privacy"), "privacy is excluded from the control surface")
checkEqual(control("privacy")?.title, "Privacy", "privacy still parses if it reappears")

// MARK: - Audio parsing

section("audio parsing")
let audio = P21Parser.audioState(Fixtures.audio)
checkEqual(audio.micDevice, 131, "microphone device id")
checkEqual(audio.micChannelCount, 1, "microphone channel count")
checkEqual(audio.speakerDevice, 135, "speaker device id")
checkEqual(audio.speakerChannelCount, 2, "speaker channel count")
checkEqual(audio.volume(input: true), 75, "microphone volume")
checkEqual(audio.isMuted(input: true), false, "microphone mute")
checkEqual(audio.volume(input: false), 100, "speaker volume")
checkEqual(audio.speakerVolume.count, 2, "both speaker channels are kept")
checkEqual(audio.speakerMute.count, 2, "both speaker mute channels are kept")
check(audio.volumeWritable(input: true), "microphone volume is writable")
check(audio.allChannelsWritable(input: false, mute: false), "every speaker channel is writable")
check(audio.isPresent, "audio state reports a present device")

let partialAudio = P21Parser.audioState("mic-volume=40.000% channel=0 writable=yes")
checkEqual(partialAudio.micVolume.count, 1, "a write readback line parses without a device header")
checkEqual(partialAudio.micDevice, nil, "a write readback does not invent a device id")
checkEqual(partialAudio.volume(input: true), 40, "write readback volume")
checkEqual(P21Parser.audioState("").isPresent, false, "empty audio output is not present")

// MARK: - Lights parsing

section("lights parsing")
let lights = P21Parser.lightsStored(Fixtures.lights)
checkEqual(lights.readings.count, 10, "every light line is parsed")
checkEqual(lights.percent("left"), 50, "stored left brightness")
checkEqual(lights.percent("right"), 50, "stored right brightness")
checkEqual(lights.percent("status"), 100, "stored status brightness")
checkEqual(lights.isOn("idle"), true, "idle event is on")
checkEqual(lights.isOn("manual"), false, "manual event is off")
checkEqual(lights.percent("manual"), nil, "an event has no percentage")
checkEqual(P21Parser.lightsStored("").readings.count, 0, "empty lights output parses to nothing")

section("side verification")
let verification = P21Parser.sidesVerification(Fixtures.sidesWrite)
checkEqual(verification?.left, 30, "verified left")
checkEqual(verification?.right, 40, "verified right")
checkEqual(P21Parser.sidesVerification("Bottom bar updated; register readback verified."), nil, "colour output is not a side verification")
checkEqual(P21Parser.sidesVerification("side-left=30% without a marker"), nil, "unverified lines are ignored")

// MARK: - Commands

section("command construction")
checkEqual(P21Command.lightsList.arguments, ["lights", "list"], "lights list arguments")
checkEqual(P21Command.cameraList.access, .read, "camera list is a read")
checkEqual(P21Command.sides(left: 30, right: 40).arguments, ["lights", "sides", "30", "40"], "sides arguments")
checkEqual(P21Command.sides(left: 30, right: 40).access, .write, "sides is a write")
checkEqual(P21Command.rgb(red: 1, green: 2, blue: 3).arguments, ["lights", "rgb", "1", "2", "3"], "rgb arguments")
checkEqual(P21Command.fade(3).arguments, ["lights", "fade", "3"], "fade arguments")
checkEqual(P21Command.camera("pan-tilt", values: [10, 20]).arguments, ["camera", "pan-tilt", "10", "20"], "camera pair arguments")
checkEqual(P21Command.camera("auto-exposure", values: [8]).arguments, ["camera", "auto-exposure", "8"], "camera mode arguments")
checkEqual(P21Command.audioVolume(input: true, percent: 40).arguments, ["audio", "mic-volume", "40"], "microphone volume arguments")
checkEqual(P21Command.audioVolume(input: false, percent: 40).arguments, ["audio", "speaker-volume", "40"], "speaker volume arguments")
checkEqual(P21Command.audioMute(input: true, muted: true).arguments, ["audio", "mic-mute", "on"], "mute arguments")
checkEqual(P21Command.audioMute(input: false, muted: false).arguments, ["audio", "speaker-mute", "off"], "unmute arguments")
checkEqual(P21Command.audioDefault(input: true).arguments, ["audio", "default-input"], "default input arguments")
checkEqual(P21Command.audioDefault(input: false).arguments, ["audio", "default-output"], "default output arguments")
checkEqual(P21Command.sides(left: 0, right: 0).label, "p21ctl lights sides 0 0", "command label")

// MARK: - Failure classification

section("failure classification")
func result(_ command: P21Command, exit: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) -> P21Result {
    P21Result(command: command, exitCode: exit, stdout: stdout, stderr: stderr, timedOut: timedOut)
}

checkEqual(P21Diagnostics.classify(result(.lightsList, exit: 0, stdout: Fixtures.lights)), P21Failure.none, "success classifies as none")
checkEqual(P21Diagnostics.classify(result(.lightsList, exit: 1, stderr: Fixtures.deviceAbsent)), P21Failure.deviceAbsent, "missing device")
checkEqual(P21Diagnostics.classify(result(.lightsList, exit: 1, stderr: Fixtures.usbStall)), P21Failure.usbStall, "usb stall")
checkEqual(P21Diagnostics.classify(result(.lightsList, exit: 1, stderr: Fixtures.lockHeld)), P21Failure.busy, "vendor lock is busy, not a stall")
checkEqual(P21Diagnostics.classify(Fixtures.cameraTimeout), P21Failure.usbStall, "a bounded-run timeout is a stall")
checkEqual(P21Diagnostics.classify(result(.audioStatus, exit: 1, stderr: "Expected one P21 input device; found 0")), P21Failure.deviceAbsent, "audio device absent")
checkEqual(P21Diagnostics.classify(result(.cameraList, exit: 2, stderr: "Unknown camera control")), P21Failure.other, "usage errors are other")
check(P21Diagnostics.summary(result(.lightsList, exit: 1, stderr: Fixtures.usbStall), failure: .usbStall).contains("Reconnect"), "stall summary tells the user to reconnect")
check(P21Diagnostics.summary(result(.lightsList, exit: 1, stderr: Fixtures.lockHeld), failure: .busy).contains("lock"), "busy summary names the lock")
checkEqual(P21Diagnostics.summary(result(.lightsList, exit: 3, stderr: "", timedOut: false), failure: .other), "The helper exited with status 3.", "unknown failures report the exit status")

// MARK: - Store

func scriptedRunner(audio: String = Fixtures.audio, lights: String = Fixtures.lights, camera: String = Fixtures.cameraClean) -> MockRunner {
    let runner = MockRunner()
    runner.respond(.audioStatus, stdout: audio)
    runner.respond(.lightsList, stdout: lights)
    runner.respond(.cameraList, stdout: camera)
    return runner
}

section("store: clean read")
let runner = scriptedRunner()
let store = ControlStore(runner: runner, helperPath: "/mock/p21ctl")
await store.refresh()
checkEqual(store.connection, .ready, "a clean read reports ready")
checkEqual(store.outcome, nil, "a clean read has no error banner")
check(store.lastUpdated != nil, "a clean read records a timestamp")
check(runner.recorded.allSatisfy { $0.access == .read }, "refresh only sent read commands")
checkEqual(store.lights.percent("left"), 50, "stored left brightness is exposed")
checkEqual(store.audio.volume(input: true), 75, "microphone volume is exposed")
checkEqual(store.visibleCameraControls.count, 16, "privacy is filtered out of the control surface")
check(store.visibleCameraControls.allSatisfy(\.isAvailable), "every control in a clean read is available")
check(store.canSendHardwareCommands, "a ready store accepts commands")

section("store: partial camera read")
let partialRunner = scriptedRunner(camera: Fixtures.camera)
let partialStore = ControlStore(runner: partialRunner, helperPath: "/mock/p21ctl")
await partialStore.refresh()
checkEqual(partialStore.connection, .ready, "a partially readable camera still leaves the device usable")
checkEqual(partialStore.outcome?.level, .warning, "an unread control is reported as a warning")
check(partialStore.cameraNote != nil, "the camera note explains the unread control")
checkEqual(partialStore.cameraControls.filter { !$0.isAvailable }.count, 1, "exactly one control failed to read")
checkEqual(partialStore.cameraControls.first { $0.name == "white-balance" }?.kind, .unsupported("LIBUSB_ERROR_TIMEOUT"), "the unread control keeps its reason")
check(partialStore.canSendHardwareCommands, "the remaining controls are still usable")

section("store: no device")
let absentRunner = MockRunner()
absentRunner.respond(.audioStatus, exitCode: 1, stderr: "Expected one P21 input device; found 0")
absentRunner.respond(.lightsList, exitCode: 1, stderr: Fixtures.deviceAbsent)
let absentStore = ControlStore(runner: absentRunner, helperPath: "/mock/p21ctl")
await absentStore.refresh()
checkEqual(absentStore.connection, .noDevice, "a missing device is reported as such")
check(!absentRunner.recorded.contains { $0 == .cameraList }, "the camera is not read when the device is absent")
check(!absentStore.canSendHardwareCommands, "writes are refused with no device")

section("store: usb stall latches")
let stallRunner = scriptedRunner()
stallRunner.respond(.cameraList, exitCode: 143, timedOut: true)
let stallStore = ControlStore(runner: stallRunner, helperPath: "/mock/p21ctl")
await stallStore.refresh()
checkEqual(stallStore.connection, .latched, "a stalled camera read latches the store")
let commandsAfterStall = stallRunner.recorded.count
await stallStore.applyRGB(P21Color(red: 1, green: 2, blue: 3))
await stallStore.applySides()
await stallStore.setVolume(input: true, percent: 10)
checkEqual(stallRunner.recorded.count, commandsAfterStall, "a latched store sends no hardware commands")
checkEqual(stallStore.outcome?.level, .warning, "a refused write explains itself")

section("store: refresh reloads")
stallRunner.respond(.cameraList, stdout: Fixtures.camera)
await stallStore.retryConnection()
checkEqual(stallStore.connection, .ready, "retry clears the latch after the device answers")
check(stallRunner.recorded.contains { $0 == .cameraList }, "retry re-reads the camera")
checkEqual(stallStore.cameraControls.count, 17, "retry repopulates the camera controls")

section("store: writes need a prior read")
let freshRunner = MockRunner()
let freshStore = ControlStore(runner: freshRunner, helperPath: "/mock/p21ctl")
await freshStore.applyRGB(.off)
checkEqual(freshRunner.recorded.count, 0, "a write before the first read sends nothing")
checkEqual(freshStore.outcome?.level, .warning, "the refusal is a warning")

section("store: rgb draft")
let colorRunner = scriptedRunner()
let colorStore = ControlStore(runner: colorRunner, helperPath: "/mock/p21ctl")
await colorStore.refresh()
colorStore.draftRGB = P21Color(red: 10, green: 20, blue: 30)
checkEqual(colorStore.rgbApplied, nil, "a fresh draft has no verified colour")
let draftColor = colorStore.draftRGB
colorRunner.respond(P21Command.rgb(red: draftColor.red, green: draftColor.green, blue: draftColor.blue), stdout: Fixtures.rgbWrite)
await colorStore.applyRGB(draftColor)
checkEqual(colorStore.rgbApplied, draftColor, "a verified write is recorded as applied")
checkEqual(colorStore.outcome?.level, .success, "a verified write reports success")
checkEqual(colorStore.outcome?.message.contains("#0A141E"), true, "the success message carries the verified hex")
colorStore.draftRGB = .off
checkEqual(colorStore.rgbApplied, nil, "changing the draft clears the verified colour")

section("store: side lights")
let sideRunner = scriptedRunner()
let sideStore = ControlStore(runner: sideRunner, helperPath: "/mock/p21ctl")
await sideStore.refresh()
sideRunner.respond(P21Command.sides(left: 30, right: 40), stdout: Fixtures.sidesWrite)
sideStore.draftLeft = 30
sideStore.draftRight = 40
await sideStore.applySides()
checkEqual(sideStore.sidesVerified, SidesVerification(left: 30, right: 40), "the live verification is captured")
checkEqual(sideStore.outcome?.message.contains("verified live"), true, "the message says live and verified")
let sideWrites = sideRunner.recorded.filter { $0 == P21Command.sides(left: 30, right: 40) }
checkEqual(sideWrites.count, 1, "the side command is sent exactly once")

section("store: camera write")
let cameraRunner = scriptedRunner()
let cameraStore = ControlStore(runner: cameraRunner, helperPath: "/mock/p21ctl")
await cameraStore.refresh()
if let zoom = cameraStore.cameraControls.first(where: { $0.name == "zoom" }) {
    cameraRunner.respond(P21Command.camera("zoom", values: [13]), stdout: Fixtures.cameraZoomWrite)
    await cameraStore.setCamera(zoom, values: [13])
    checkEqual(cameraStore.cameraControls.first { $0.name == "zoom" }?.current, [13], "the camera readback replaces the old value")
    checkEqual(cameraStore.outcome?.message.contains("1.3x"), true, "the camera message reports the value the hardware applied")
} else {
    check(false, "zoom control is available to the store")
}

section("store: audio write")
let audioRunner = scriptedRunner()
let audioStore = ControlStore(runner: audioRunner, helperPath: "/mock/p21ctl")
await audioStore.refresh()
audioRunner.respond(P21Command.audioVolume(input: true, percent: 40), stdout: Fixtures.audioVolumeWrite)
await audioStore.setVolume(input: true, percent: 40)
checkEqual(audioStore.audio.volume(input: true), 40, "the audio readback replaces the old value")
audioRunner.respond(P21Command.audioMute(input: true, muted: true), stdout: "mic-mute=on channel=0 writable=yes")
await audioStore.setMute(input: true, muted: true)
checkEqual(audioStore.audio.isMuted(input: true), true, "mute readback is recorded")
checkEqual(audioStore.outcome?.message.contains("muted"), true, "the mute message reflects the hardware")

section("store: default device")
let defaultRunner = scriptedRunner()
let defaultStore = ControlStore(runner: defaultRunner, helperPath: "/mock/p21ctl")
await defaultStore.refresh()
defaultRunner.respond(P21Command.audioDefault(input: true), stdout: "default-input=Poly Studio P21")
await defaultStore.makeDefault(input: true)
checkEqual(defaultStore.outcome?.level, .success, "setting the default input succeeds")
checkEqual(defaultStore.outcome?.message, "default-input=Poly Studio P21", "the helper's own confirmation is relayed")

section("store: missing helper")
let missingStore = ControlStore(runner: MockRunner(), helperPath: nil)
await missingStore.refresh()
checkEqual(missingStore.connection, .failed, "a missing helper is a failure, not an empty device")

print("")
section("store: automatic mode updates sibling controls")
let autoRunner = scriptedRunner()
let autoStore = ControlStore(runner: autoRunner, helperPath: "/mock/p21ctl")
await autoStore.refresh()
if let automatic = autoStore.cameraControls.first(where: { $0.name == "auto-exposure" }) {
    autoRunner.respond(.camera("auto-exposure", values: [1]), stdout: "auto-exposure current=1 step=9 writable=yes")
    autoRunner.respond(.cameraList, stdout: "auto-exposure current=1 step=9 writable=yes\nexposure current=30 min=3 max=2047 step=1 writable=yes")
    await autoStore.setCamera(automatic, values: [1])
    checkEqual(autoStore.cameraControls.first { $0.name == "exposure" }?.isEditable, true, "manual exposure unlocks without a manual refresh")
    checkEqual(autoRunner.recorded.last, .cameraList, "automatic mode change rereads sibling capabilities")
}

section("store: retry after camera failure and disconnected lights")
let retryRunner = scriptedRunner()
retryRunner.respond(.cameraList, exitCode: 143, timedOut: true)
let retryStore = ControlStore(runner: retryRunner, helperPath: "/mock/p21ctl")
await retryStore.refresh()
retryRunner.respond(.lightsList, exitCode: 1, stderr: Fixtures.deviceAbsent)
await retryStore.retryConnection()
checkEqual(retryStore.connection, .noDevice, "old camera latch cannot override new disconnect evidence")

section("store: automatic-mode refresh keeps the write slot")
let autoQueueRunner = scriptedRunner()
let autoQueueStore = ControlStore(runner: autoQueueRunner, helperPath: "/mock/p21ctl")
await autoQueueStore.refresh()
let manualExposure = P21Command.camera("auto-exposure", values: [1])
let queuedAfterAuto = P21Command.audioVolume(input: true, percent: 40)
autoQueueRunner.respond(manualExposure, stdout: "auto-exposure current=1 step=9 default=8 writable=yes")
autoQueueRunner.respond(.cameraList, stdout: "auto-exposure current=1 step=9 default=8 writable=yes\nexposure current=30 min=3 max=2047 step=1 default=3 writable=yes")
autoQueueRunner.respond(queuedAfterAuto, stdout: Fixtures.audioVolumeWrite)
autoQueueRunner.delay(.cameraList, nanoseconds: 180_000_000)
if let automatic = autoQueueStore.cameraControls.first(where: { $0.name == "auto-exposure" }) {
    let automaticWrite = Task { await autoQueueStore.setCamera(automatic, values: [1]) }
    check(await waitForCommandCount(.cameraList, count: 2, in: autoQueueRunner), "automatic-mode sibling refresh starts")
    let queuedAudio = Task { await autoQueueStore.setVolume(input: true, percent: 40) }
    try? await Task.sleep(nanoseconds: 50_000_000)
    check(!autoQueueRunner.recorded.contains(queuedAfterAuto), "a later write waits for the sibling refresh")
    await automaticWrite.value
    await queuedAudio.value
    checkEqual(autoQueueRunner.recorded.last, queuedAfterAuto, "the queued write runs after the sibling refresh")
} else {
    check(false, "automatic exposure is available for operation-slot check")
}

section("store: automatic lighting coalesces edits")
let liveRunner = scriptedRunner()
let liveStore = ControlStore(runner: liveRunner, helperPath: "/mock/p21ctl")
await liveStore.refresh()
check(liveRunner.recorded.allSatisfy { $0.access == .read }, "startup does not apply lighting")
liveRunner.respond(.rgb(red: 10, green: 20, blue: 30), stdout: Fixtures.rgbWrite)
liveStore.draftRGB = .init(red: 1, green: 2, blue: 3)
liveStore.scheduleLighting(.rgb)
liveStore.draftRGB = .init(red: 10, green: 20, blue: 30)
liveStore.scheduleLighting(.rgb)
try await Task.sleep(nanoseconds: 350_000_000)
let automaticWrites = liveRunner.recorded.filter { $0.access == .write }
checkEqual(automaticWrites, [.rgb(red: 10, green: 20, blue: 30)], "rapid colour edits send only the latest value")
checkEqual(liveStore.rgbApplied, liveStore.draftRGB, "automatically applied colour is verified")
absentStore.draftRGB = .off
absentStore.scheduleLighting(.rgb)
let absentCount = absentRunner.recorded.count
try await Task.sleep(nanoseconds: 250_000_000)
checkEqual(absentRunner.recorded.count, absentCount, "automatic changes do not write while disconnected")

section("store: concurrent writes are serialized")
let queuedRunner = scriptedRunner()
let queuedStore = ControlStore(runner: queuedRunner, helperPath: "/mock/p21ctl")
await queuedStore.refresh()
let brightnessCommand = P21Command.camera("brightness", values: [129])
let volumeCommand = P21Command.audioVolume(input: true, percent: 40)
queuedRunner.respond(brightnessCommand, stdout: "brightness current=129 min=0 max=255 step=1 default=128 writable=yes")
queuedRunner.respond(volumeCommand, stdout: Fixtures.audioVolumeWrite)
queuedRunner.delay(brightnessCommand, nanoseconds: 200_000_000)
if let brightness = queuedStore.cameraControls.first(where: { $0.name == "brightness" }) {
    let firstWrite = Task { await queuedStore.setCamera(brightness, values: [129]) }
    check(await waitForCommand(brightnessCommand, in: queuedRunner), "first queued write starts")
    let secondWrite = Task { await queuedStore.setVolume(input: true, percent: 40) }
    await firstWrite.value
    await secondWrite.value
    check(queuedRunner.recorded.contains(volumeCommand), "a second rapid write waits instead of being dropped")
    checkEqual(queuedStore.audio.volume(input: true), 40, "the queued audio value is applied")
} else {
    check(false, "brightness control is available for serialization check")
}

section("store: reverting side lights while a write is in flight")
let revertRunner = scriptedRunner()
let revertStore = ControlStore(runner: revertRunner, helperPath: "/mock/p21ctl")
await revertStore.refresh()
let priorSides = P21Command.sides(left: 30, right: 40)
let intermediateSides = P21Command.sides(left: 80, right: 90)
revertRunner.respond(priorSides, stdout: "side-left=30% (live, verified)\nside-right=40% (live, verified)")
revertRunner.respond(intermediateSides, stdout: "side-left=80% (live, verified)\nside-right=90% (live, verified)")
revertStore.draftLeft = 30
revertStore.draftRight = 40
await revertStore.applySides()
revertRunner.delay(intermediateSides, nanoseconds: 200_000_000)
revertStore.draftLeft = 80
revertStore.draftRight = 90
revertStore.scheduleLighting(.sides)
check(await waitForCommand(intermediateSides, in: revertRunner), "intermediate side write starts")
revertStore.draftLeft = 30
revertStore.draftRight = 40
revertStore.scheduleLighting(.sides)
try await Task.sleep(nanoseconds: 350_000_000)
let revertedSideWrites = revertRunner.recorded.filter { $0 == priorSides || $0 == intermediateSides }
checkEqual(revertedSideWrites.last, priorSides, "returning to the prior side levels queues a restoring write")

section("store: pan and tilt preserve the latest sibling axis")
let pairCamera = Fixtures.cameraClean.replacingOccurrences(
    of: "zoom current=10",
    with: "zoom current=13"
)
let pairRunner = scriptedRunner(camera: pairCamera)
let pairStore = ControlStore(runner: pairRunner, helperPath: "/mock/p21ctl")
await pairStore.refresh()
let panCommand = P21Command.camera("pan-tilt", values: [3600, 0])
let tiltCommand = P21Command.camera("pan-tilt", values: [3600, 7200])
pairRunner.respond(panCommand, stdout: "pan-tilt current=3600,0 min=-36000,-36000 max=36000,36000 step=3600,3600 default=0,0 writable=yes")
pairRunner.respond(tiltCommand, stdout: "pan-tilt current=3600,7200 min=-36000,-36000 max=36000,36000 step=3600,3600 default=0,0 writable=yes")
pairRunner.delay(panCommand, nanoseconds: 150_000_000)
let panWrite = Task { await pairStore.setCameraComponent("pan-tilt", index: 0, value: 3600) }
check(await waitForCommand(panCommand, in: pairRunner), "pan edit starts")
let tiltWrite = Task { await pairStore.setCameraComponent("pan-tilt", index: 1, value: 7200) }
await panWrite.value
await tiltWrite.value
check(pairRunner.recorded.contains(tiltCommand), "tilt edit keeps the latest pan readback")
checkEqual(pairStore.cameraControls.first { $0.name == "pan-tilt" }?.current, [3600, 7200], "both rapid axis edits survive")

section("store: pan and tilt require actual zoom")
let guardedRunner = scriptedRunner()
let guardedStore = ControlStore(runner: guardedRunner, helperPath: "/mock/p21ctl")
await guardedStore.refresh()
let guardedWriteCount = guardedRunner.recorded.filter { $0.access == .write }.count
await guardedStore.setCameraComponent("pan-tilt", index: 0, value: 3600)
checkEqual(guardedRunner.recorded.filter { $0.access == .write }.count, guardedWriteCount, "pan is not written at actual zoom 1.0x")
checkEqual(guardedStore.canAdjustPanTilt, false, "the store exposes the pan and tilt dependency")
checkEqual(guardedStore.outcome?.message.contains("actual zoom"), true, "the rejected pan edit explains the actual-zoom requirement")

section("store: exposure reset orders automatic mode last")
let exposureResetRunner = scriptedRunner()
let exposureResetStore = ControlStore(runner: exposureResetRunner, helperPath: "/mock/p21ctl")
await exposureResetStore.refresh()
let exposureUnlock = P21Command.camera("auto-exposure", values: [1])
let exposureDefault = P21Command.camera("exposure", values: [3])
let exposureAutoDefault = P21Command.camera("auto-exposure", values: [8])
exposureResetRunner.respond(exposureUnlock, stdout: "auto-exposure current=1 step=9 default=8 writable=yes")
exposureResetRunner.respond(exposureDefault, stdout: "exposure current=3 min=3 max=2047 step=1 default=3 writable=yes")
exposureResetRunner.respond(exposureAutoDefault, stdout: "auto-exposure current=8 step=9 default=8 writable=yes")
await exposureResetStore.resetCameraGroup("Exposure")
checkEqual(
    exposureResetRunner.recorded.filter { $0.access == .write },
    [exposureUnlock, exposureDefault, exposureAutoDefault],
    "exposure reset unlocks first and restores the automatic default last"
)
checkEqual(exposureResetStore.outcome?.level, .failure, "an incomplete group reset is reported as a failure")
checkEqual(exposureResetStore.outcome?.message.contains("no device-reported default"), true, "reset names the unavailable default")

section("store: image reset unlocks dependencies and rejects invalid defaults")
let imageResetCamera = """
auto-exposure current=8 step=9 default=8 writable=yes
gain current=5 min=0 max=255 step=1 default=0 writable=yes (disabled by automatic mode)
brightness current=140 min=0 max=255 step=1 default=999 writable=yes
white-balance current=5000 min=2000 max=7500 step=10 default=4000 writable=yes (disabled by automatic mode)
auto-white-balance current=1 default=1 writable=yes
"""
let imageResetRunner = scriptedRunner(camera: imageResetCamera)
let imageResetStore = ControlStore(runner: imageResetRunner, helperPath: "/mock/p21ctl")
await imageResetStore.refresh()
let imageCommands: [P21Command] = [
    .camera("auto-exposure", values: [1]),
    .camera("auto-white-balance", values: [0]),
    .camera("gain", values: [0]),
    .camera("white-balance", values: [4000]),
    .camera("auto-exposure", values: [8]),
    .camera("auto-white-balance", values: [1]),
]
let imageOutputs = [
    "auto-exposure current=1 step=9 default=8 writable=yes",
    "auto-white-balance current=0 default=1 writable=yes",
    "gain current=0 min=0 max=255 step=1 default=0 writable=yes",
    "white-balance current=4000 min=2000 max=7500 step=10 default=4000 writable=yes",
    "auto-exposure current=8 step=9 default=8 writable=yes",
    "auto-white-balance current=1 default=1 writable=yes",
]
for (command, output) in zip(imageCommands, imageOutputs) {
    imageResetRunner.respond(command, stdout: output)
}
await imageResetStore.resetCameraGroup("Image")
checkEqual(imageResetRunner.recorded.filter { $0.access == .write }, imageCommands, "image reset unlocks all dependencies before defaults and restores auto modes last")
check(!imageResetRunner.recorded.contains(.camera("brightness", values: [999])), "an invalid reported default is never written")
checkEqual(imageResetStore.outcome?.message.contains("invalid device-reported default"), true, "an invalid default is reported honestly")

section("store: failed reset restores an unlocked external mode")
let failedResetCamera = """
auto-exposure current=8 step=9 default=8 writable=yes
gain current=5 min=0 max=255 step=1 default=0 writable=yes (disabled by automatic mode)
"""
let failedResetRunner = scriptedRunner(camera: failedResetCamera)
let failedResetStore = ControlStore(runner: failedResetRunner, helperPath: "/mock/p21ctl")
await failedResetStore.refresh()
let failedGain = P21Command.camera("gain", values: [0])
failedResetRunner.respond(.camera("auto-exposure", values: [1]), stdout: "auto-exposure current=1 step=9 default=8 writable=yes")
failedResetRunner.respond(failedGain, exitCode: 1, stderr: "gain reset failed")
failedResetRunner.respond(.camera("auto-exposure", values: [8]), stdout: "auto-exposure current=8 step=9 default=8 writable=yes")
await failedResetStore.resetCameraGroup("Image")
checkEqual(
    failedResetRunner.recorded.filter { $0.access == .write },
    [.camera("auto-exposure", values: [1]), failedGain, .camera("auto-exposure", values: [8])],
    "a failed dependent reset restores the outside automatic mode"
)
checkEqual(failedResetStore.outcome?.level, .failure, "a failed reset remains a failure after cleanup")
checkEqual(failedResetStore.outcome?.message.contains("Automatic modes were restored"), true, "reset failure reports successful automatic-mode cleanup")

section("store: framing reset raises zoom and restores its default last")
let framingResetRunner = scriptedRunner()
let framingResetStore = ControlStore(runner: framingResetRunner, helperPath: "/mock/p21ctl")
await framingResetStore.refresh()
let raisedZoom = P21Command.camera("zoom", values: [13])
let centeredPanTilt = P21Command.camera("pan-tilt", values: [0, 0])
let defaultZoom = P21Command.camera("zoom", values: [10])
framingResetRunner.respond(raisedZoom, stdout: "zoom current=13 min=10 max=40 step=1 default=10 writable=yes")
framingResetRunner.respond(centeredPanTilt, stdout: "pan-tilt current=0,0 min=-36000,-36000 max=36000,36000 step=3600,3600 default=0,0 writable=yes")
framingResetRunner.respond(defaultZoom, stdout: "zoom current=10 min=10 max=40 step=1 default=10 writable=yes")
await framingResetStore.resetCameraGroup("Framing")
checkEqual(
    framingResetRunner.recorded.filter { $0.access == .write },
    [raisedZoom, centeredPanTilt, defaultZoom],
    "framing reset raises zoom before pan and tilt, then restores zoom last"
)
checkEqual(framingResetStore.outcome?.level, .success, "a complete framing reset succeeds")

section("store: preview without a started session does not restore lights")
let noSessionRunner = scriptedRunner()
let noSessionStore = ControlStore(runner: noSessionRunner, helperPath: "/mock/p21ctl")
await noSessionStore.refresh()
let noSessionToken = noSessionStore.prepareCameraPreview()
await noSessionStore.cameraPreviewDidStop(noSessionToken, captureStarted: false)
check(noSessionRunner.recorded.allSatisfy { $0.access == .read }, "permission denial or failed capture sends no restoration write")

section("store: preview stop restoration is idempotent")
let duplicateStopRunner = scriptedRunner()
let duplicateStopStore = ControlStore(runner: duplicateStopRunner, helperPath: "/mock/p21ctl")
await duplicateStopStore.refresh()
let storedSides = P21Command.sides(left: 50, right: 50)
duplicateStopRunner.respond(storedSides, stdout: "side-left=50% (live, verified)\nside-right=50% (live, verified)")
let duplicateToken = duplicateStopStore.prepareCameraPreview()
await duplicateStopStore.cameraPreviewDidStop(duplicateToken, captureStarted: true)
await duplicateStopStore.cameraPreviewDidStop(duplicateToken, captureStarted: true)
checkEqual(duplicateStopRunner.recorded.filter { $0 == storedSides }.count, 1, "onDisappear and deinit can restore only once")

section("store: stale preview stops are ignored")
let staleStopRunner = scriptedRunner()
let staleStopStore = ControlStore(runner: staleStopRunner, helperPath: "/mock/p21ctl")
await staleStopStore.refresh()
staleStopRunner.respond(storedSides, stdout: "side-left=50% (live, verified)\nside-right=50% (live, verified)")
let staleToken = staleStopStore.prepareCameraPreview()
let currentToken = staleStopStore.prepareCameraPreview()
await staleStopStore.cameraPreviewDidStop(staleToken, captureStarted: true)
checkEqual(staleStopRunner.recorded.filter { $0 == storedSides }.count, 0, "an old stop cannot restore during a newer preview")
await staleStopStore.cameraPreviewDidStop(currentToken, captureStarted: true)
checkEqual(staleStopRunner.recorded.filter { $0 == storedSides }.count, 1, "the current preview restores once it stops")

section("store: preview restoration prefers latest explicit sides")
let latestSidesRunner = scriptedRunner()
let latestSidesStore = ControlStore(runner: latestSidesRunner, helperPath: "/mock/p21ctl")
await latestSidesStore.refresh()
latestSidesStore.draftLeft = 70
latestSidesStore.draftRight = 80
let latestSides = P21Command.sides(left: 70, right: 80)
latestSidesRunner.respond(latestSides, stdout: "side-left=70% (live, verified)\nside-right=80% (live, verified)")
let latestSidesToken = latestSidesStore.prepareCameraPreview()
await latestSidesStore.cameraPreviewDidStop(latestSidesToken, captureStarted: true)
checkEqual(latestSidesRunner.recorded.filter { $0.access == .write }, [latestSides], "explicit side intent wins over stored firmware values")

section("store: a later side edit supersedes a queued preview restore")
let supersededRunner = scriptedRunner()
let supersededStore = ControlStore(runner: supersededRunner, helperPath: "/mock/p21ctl")
await supersededStore.refresh()
let blockingBrightness = P21Command.camera("brightness", values: [129])
supersededRunner.respond(blockingBrightness, stdout: "brightness current=129 min=0 max=255 step=1 default=128 writable=yes")
supersededRunner.delay(blockingBrightness, nanoseconds: 200_000_000)
let supersededToken = supersededStore.prepareCameraPreview()
if let brightness = supersededStore.cameraControls.first(where: { $0.name == "brightness" }) {
    let blocker = Task { await supersededStore.setCamera(brightness, values: [129]) }
    check(await waitForCommand(blockingBrightness, in: supersededRunner), "a write blocks preview restoration")
    let queuedRestore = Task { await supersededStore.cameraPreviewDidStop(supersededToken, captureStarted: true) }
    try? await Task.sleep(nanoseconds: 40_000_000)
    supersededStore.draftLeft = 70
    supersededStore.draftRight = 80
    supersededRunner.respond(latestSides, stdout: "side-left=70% (live, verified)\nside-right=80% (live, verified)")
    let laterEdit = Task { await supersededStore.applySides() }
    await blocker.value
    await queuedRestore.value
    await laterEdit.value
    checkEqual(supersededRunner.recorded.filter { $0 == storedSides }.count, 0, "a stale queued restoration is dropped")
    checkEqual(supersededRunner.recorded.filter { $0 == latestSides }.count, 1, "the later explicit edit is the applied side value")
} else {
    check(false, "brightness control is available for preview serialization")
}

section("store: disconnected preview restoration reports failure")
let restoreFailureRunner = scriptedRunner()
let restoreFailureStore = ControlStore(runner: restoreFailureRunner, helperPath: "/mock/p21ctl")
await restoreFailureStore.refresh()
let restoreFailureToken = restoreFailureStore.prepareCameraPreview()
let disconnectColour = P21Color(red: 1, green: 2, blue: 3)
let disconnectCommand = P21Command.rgb(red: 1, green: 2, blue: 3)
restoreFailureRunner.respond(disconnectCommand, exitCode: 1, stderr: Fixtures.deviceAbsent)
await restoreFailureStore.applyRGB(disconnectColour)
let commandsBeforeRestore = restoreFailureRunner.recorded.count
await restoreFailureStore.cameraPreviewDidStop(restoreFailureToken, captureStarted: true)
checkEqual(restoreFailureRunner.recorded.count, commandsBeforeRestore, "a disconnected store sends no camera-close restoration write")
checkEqual(restoreFailureStore.outcome?.level, .failure, "camera-close restoration failure is an error")
checkEqual(restoreFailureStore.outcome?.message.contains("after closing the camera"), true, "camera-close restoration failure is identified")

print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
