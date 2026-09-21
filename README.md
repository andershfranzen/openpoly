# OpenPoly

An independent native macOS app and command-line tools for a connected **Poly
Studio P21**. OpenPoly controls the display, lights, camera and audio without the
Poly Studio app, DisplayLink Manager, a Poly SDK, service or account.

## Build and use

Requires Apple command-line tools and Homebrew `libusb` (already installed on the development Mac).

```sh
./script/build_and_run.sh --build-only
./build/p21ctl camera list
./build/p21ctl camera brightness 128
./build/p21ctl camera zoom 20
./build/p21ctl camera pan-tilt 3600 0
./build/p21ctl audio status
./build/p21ctl audio mic-volume 50
./build/p21ctl audio mic-mute on
./build/p21ctl audio mic-mute off
./build/p21ctl screen status
./build/p21ctl screen modes
./build/p21ctl lights list
./build/p21ctl lights status 10
./build/p21ctl lights status 100
./build/p21ctl hid mute-indicator on
./build/p21ctl hid mute-indicator off
./build/p21ctl hid softphone-icon teams
./build/p21ctl hid softphone-icon zoom
```

Omit the value to read a control. `audio default-input` and `audio default-output` select the P21 as the system default. `camera brightness` controls the **camera image**, not the screen backlight. `hid mute-indicator` sets an indicator; use `audio mic-mute` to mute audio.

`./script/test.sh` runs offline checks without changing hardware. The Codex Run action builds and shows command help.

## Native app and independent display

OpenPoly includes a native **Display** page alongside the light, camera and audio
controls. Its display driver has been visually verified on the physical P21,
including a usable desktop and mouse pointer. The final installed build was also
verified after DisplayLink Manager and HP Poly Studio were removed from the Mac.

```sh
./script/build_native.sh
open dist/OpenPoly.app --args --open-display
```

Allow **Screen Recording** for OpenPoly, then choose **Start display**. The Display
page provides hardware brightness, resolution and refresh controls. The physical
panel uses 1920×1080 at 60 Hz; virtual desktop modes are 1920×1080, 1600×900,
1280×720 and 960×540 at 60 or 30 Hz. Capture targets 60 updates per second and
reuses unchanged image regions; the displayed update rate drops when the desktop
is still. A fixed 60 FPS under every workload has not been established.

The bundle contains the display helpers, libusb and a verified standalone Node
runtime. It requires no DisplayLink installation, separate Node, Homebrew or
Python runtime. The display path uses fresh authenticated sessions and directly
encodes/transmits Firefly Haar frames over USB. It bundles no vendor executable,
firmware package, captured screen image or captured session key.

The prototype can also run from the source tree:

```sh
./driver/macos/build.sh
node driver/macos/p21-display.cjs --seconds 30 --take-over
node driver/macos/p21-display.cjs --run --take-over
```

The bounded command restores an initially running DisplayLink Manager after the
trial. Ctrl+C stops a continuous run. The native app remembers an enabled display,
provides an **Open at login** setting, and retries a disconnected USB session.
See [driver details](driver/macos/README.md) and [native app usage](macos/README.md).

## Bottom bar: direct RGB and cycling

The P21 firmware exposes an undocumented USB-to-I2C bridge. The controller uses it to access the two bottom-bar KTD2061 chips directly, without Poly software or a firmware update. Blue and magenta writes, a six-second spectrum cycle, and restoration have passed device register readback. **Purple is visually confirmed.**

```sh
./build/p21ctl lights bar-state
./build/p21ctl lights rgb 64 0 64 10  # Purple for ten seconds, then restore
./build/p21ctl lights cycle 3600 30  # Run one hour; one RGB cycle every 30 seconds
./build/p21ctl lights rgb 0 0 0      # Off
./build/p21ctl lights rgb 40 40 40   # Dim white, stays until changed/overridden
./build/p21ctl lights fade 3         # 250 ms fade time constant
```

RGB inputs are 0–255, mapped to the chips' 0–192 current steps per component. Timed commands and cycling save and restore the original registers, including on Ctrl+C. Untimed writes remain until another command or a firmware status event changes them. Cycling uses firmware-native red → green → blue commands with hardware fades, repeating every 30 seconds by default. Its optional second number changes the period in seconds. Continuous diagnostic I2C cycling stalled this unit, so the cycle uses the diagnostic bridge only for setup, initial verification, and restoration. Subsequent phases use native command acknowledgments; intermediate colors come from the hardware fade. Fade values `0..7` correspond to `31, 63, 125, 250, 500, 1000, 2000, 4000` milliseconds.

Each chip exposes 12 RGB module selectors. Each has two RGB palettes; each module can select off or any combination of the two palettes' red, green and blue components. This provides **24 module selectors**, with eight possible palette combinations per chip; it does not provide 24 unrelated RGB triples simultaneously. Physical left-to-right chip/module order remains to be mapped visually.

```sh
# Chip 1: first six modules red, remaining six blue.
./build/p21ctl lights palette 1 64 0 0 0 0 64 888888ffffff
```

The twelve map characters correspond to successive high/low nibbles in registers `09..0e`: `0` is off; `8` selects palette 0; `f` selects palette 1. Values `9..e` mix components (bit 0 selects blue, bit 1 green, bit 2 red from palette 1). Chip `1` is address `69`; chip `2` is `6a`.

Firmware status changes can override direct lighting. RGB and cycle commands automatically activate the bottom channel through a native firmware command when another LED channel is selected. Activation briefly sets dim white; timed commands then restore that **post-activation baseline**, since the previous bottom state cannot be read safely on another channel. If the bottom channel is already selected, timed commands restore its existing registers. `bar-state`, `fade`, and `palette` never activate the channel implicitly.

Cycling permits two retries for nonfatal native-command failures. It keeps the temporary firmware command gate enabled while running and restores its prior state on exit; that mode can affect Teams-icon and charging/touch behavior during the cycle. USB timeout, disconnect, or stalled endpoint stops all further transfers on that handle, including restoration; the tool reports the unresolved state and requests USB reconnection. The CLI never resets or power-cycles the device. A separate standard USB port reset was tried during diagnosis, but also timed out. Response polling has a two-second deadline, plus at most one outstanding USB transfer.

Mux checks run around writes and readback. They detect some races but are separate operations, so they cannot guarantee exclusive access to addresses reused on other LED channels. Keep Poly software from issuing simultaneous vendor commands. A successful endurance run is evidence for the tested session, not a guarantee that device firmware will never stall.
