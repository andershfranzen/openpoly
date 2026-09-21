import Foundation
import OpenPolyCore

/// Captured helper output. The camera, audio and lights fixtures are verbatim
/// copies of `evidence/camera-controls.txt`, `evidence/audio-status.txt` and
/// `evidence/lights-final-status.txt`, with one synthetic line added to exercise
/// the unavailable-control path.
enum Fixtures {
    /// Verbatim `evidence/camera-controls.txt`.
    static let cameraClean = """
    auto-exposure current=8 step=9 default=8 writable=yes
    exposure-priority current=0 writable=yes
    exposure current=3 min=3 max=2047 step=1 default=3 writable=yes (disabled by automatic mode)
    zoom current=10 min=10 max=40 step=1 default=10 writable=yes
    pan-tilt current=0,0 min=-36000,-36000 max=36000,36000 step=3600,3600 default=0,0 writable=yes
    privacy current=0 writable=yes
    backlight current=1 min=0 max=4 step=1 default=1 writable=yes
    brightness current=128 min=0 max=255 step=1 default=128 writable=yes
    contrast current=128 min=0 max=255 step=1 default=128 writable=yes
    gain current=0 min=0 max=255 step=1 default=0 writable=yes (disabled by automatic mode)
    power-line current=2 min=1 max=2 step=1 default=2 writable=yes
    hue current=0 min=-128 max=128 step=1 default=0 writable=yes
    saturation current=128 min=0 max=255 step=1 default=128 writable=yes
    sharpness current=128 min=0 max=255 step=1 default=128 writable=yes
    gamma current=128 min=1 max=255 step=1 default=128 writable=yes
    white-balance current=4000 min=2000 max=7500 step=10 default=4000 writable=yes (disabled by automatic mode)
    auto-white-balance current=1 default=1 writable=yes
    """

    /// The same capture with one control reported as unreadable.
    static let camera = """
    auto-exposure current=8 step=9 default=8 writable=yes
    exposure-priority current=0 writable=yes
    exposure current=3 min=3 max=2047 step=1 default=3 writable=yes (disabled by automatic mode)
    zoom current=10 min=10 max=40 step=1 default=10 writable=yes
    pan-tilt current=0,0 min=-36000,-36000 max=36000,36000 step=3600,3600 default=0,0 writable=yes
    privacy current=0 writable=yes
    backlight current=1 min=0 max=4 step=1 default=1 writable=yes
    brightness current=128 min=0 max=255 step=1 default=128 writable=yes
    contrast current=128 min=0 max=255 step=1 default=128 writable=yes
    gain current=0 min=0 max=255 step=1 default=0 writable=yes (disabled by automatic mode)
    power-line current=2 min=1 max=2 step=1 default=2 writable=yes
    hue current=0 min=-128 max=128 step=1 default=0 writable=yes
    saturation current=128 min=0 max=255 step=1 default=128 writable=yes
    sharpness current=128 min=0 max=255 step=1 default=128 writable=yes
    gamma current=128 min=1 max=255 step=1 default=128 writable=yes
    white-balance unavailable (LIBUSB_ERROR_TIMEOUT)
    auto-white-balance current=1 default=1 writable=yes
    """

    static let audio = """
    input device=131 channels=1
    mic-volume=75.000% channel=0 writable=yes
    mic-mute=off channel=0 writable=yes
    output device=135 channels=2
    speaker-volume=100.000% channel=1 writable=yes
    speaker-volume=100.000% channel=2 writable=yes
    speaker-mute=off channel=1 writable=yes
    speaker-mute=off channel=2 writable=yes
    """

    static let lights = """
    manual=off
    sensor=off
    left=50%
    right=50%
    status=100%
    idle=on
    incoming=on
    active=on
    held=on
    charging=on
    """

    static let sidesWrite = """
    side-left=30% (live, verified)
    side-right=40% (live, verified)
    """

    static let rgbWrite = "Bottom bar updated; register readback verified."

    static let audioVolumeWrite = """
    mic-volume=40.000% channel=0 writable=yes
    """

    static let cameraZoomWrite = """
    zoom current=13 min=10 max=40 step=1 default=10 writable=yes
    """

    static let cameraTimeout = P21Result(
        command: .cameraList,
        exitCode: 143,
        stdout: "",
        stderr: "",
        timedOut: true
    )

    static let deviceAbsent = """
    047f:431a: NoDevice (matching devices: 0)
    """

    static let usbStall = """
    P21 USB LIBUSB_ERROR_TIMEOUT; stopping transfers. Lighting restoration is unverified. Reconnect USB before retrying.
    """

    static let lockHeld = """
    Cannot acquire P21 vendor-control lock
    """
}
