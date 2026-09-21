# OpenPoly for macOS

Native SwiftUI controls for Poly Studio P21, hosted in an AppKit menu bar popover and window. Dark appearance; lighting, RGB, display, camera and audio controls. No Python, web view or Poly SDK.

From the repository root:

```sh
./script/build_and_run.sh                        # build and launch in menu bar
./script/build_and_run.sh --verify --open-controls
./script/build_native.sh --test                  # offline checks, no hardware writes
```

The app is staged at `dist/OpenPoly.app`. Click its display icon in the menu bar, then **Open controls**. Closing the window keeps the menu bar app running. Quit from the popover or Command-Q.

Lighting edits apply automatically after a 180 ms debounce. Camera/audio sliders also debounce edits; toggles and selection controls apply immediately. The helper validates writes and reads the device back. Side lights use 10% hardware increments. Lighting, camera and audio settings are not applied at startup or refresh. An enabled display starts when OpenPoly opens. Lighting values are session selections; firmware events and other apps can override them. Refresh reads stored side-light settings, camera and audio status; it does not reconstruct the RGB chip state.

USB failures pause further control commands until an explicit retry. The display
driver reconnects with a fresh authenticated session after USB reconnection. Keep
other P21 control tools idle during lighting, camera and audio writes.

Build requires macOS 14+, Swift tooling, Xcode's SwiftUI macro plugin and Homebrew libusb. The script packages the native helpers and runtimes inside the app. It uses a unique installed Developer ID certificate when available; set OPENPOLY_SIGN_IDENTITY to select one explicitly. Otherwise it uses ad-hoc signing. Developer ID signing keeps the app identity stable across rebuilds. The resulting local bundle needs no Python or Homebrew runtime. It is not notarized for distribution.

The CLI remains available: `--build-only` builds `build/p21ctl`; explicit command arguments still run the CLI.

The menu bar panel includes left/right light levels, RGB presets and off, camera zoom, microphone mute/level, and speaker volume. The full camera page keeps a live P21 preview visible beside scrolling settings, with an optional mirrored view. Camera access is requested when the camera page opens; leaving it or closing the window releases the camera. No audio/video is recorded. A closed physical shutter produces a black image.

Capture uses Apple's [AVCaptureDevice](https://developer.apple.com/documentation/avfoundation/avcapturedevice) and native `AVCaptureVideoPreviewLayer` APIs, selecting the P21 specifically rather than another webcam.

## Display

Open the **Display** page and choose **Start display**. macOS must grant OpenPoly
Screen Recording permission so it can send the virtual desktop to the P21.
Capture is local; there is no screen recording file or network upload.

If an early ad-hoc build was granted Screen Recording before installing the signed
app, macOS can retain the old build's exact code fingerprint. The toggle may show
enabled while the current app is rejected. Quit OpenPoly, run
`tccutil reset ScreenCapture com.openpoly.OpenPoly`, reopen the installed app, and
grant Screen Recording once. This resets only OpenPoly's screen permission; it
does not grant access automatically. Subsequent Developer ID builds retain the
same signing requirement. Start checks permission each time but requests the
system prompt at most once per app launch.

The display runs while OpenPoly is open. Closing the controls window keeps the
menu-bar app and display running; quitting stops the display session. The app
remembers whether display output is enabled and offers an **Open at login** toggle.
A reconnect creates fresh USB and authenticated protocol sessions, preserving
the virtual desktop. The panel mode is 1920×1080 at 60 Hz; live updates depend on
changed content and processing time. Idle desktops need few updates.

The **Display settings** card adjusts the hardware backlight with verified DDC/CI
readback (32 physical levels). It offers desktop resolutions 1920×1080, 1600×900,
1280×720 and 960×540, with 60 or 30 Hz desktop refresh. Smaller desktops are scaled
to the native panel; its physical scanout remains 1920×1080 at 60 Hz. Applying a
mode briefly reconnects the virtual desktop. Mode choices and explicitly changed,
verified brightness are remembered for the next start.

The app bundles a checksum-pinned official Node 24.19.0 runtime solely for the
display protocol helper, plus native capture/encoder and USB executables. The UI
is SwiftUI/AppKit. No separate runtime installation or vendor library is needed.
Display driver source and license notices are included in the bundle's Resources.

For app diagnostics:

```sh
log show --last 5m --predicate 'subsystem == "com.openpoly.OpenPoly" AND category == "Display"'
```
