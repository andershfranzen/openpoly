# P21 Control (GUI)

A desktop control panel for the Poly Studio P21 on macOS, Windows and Linux. It exposes the controls recovered in this repository: lights, indicators, camera, audio and display mode. It uses no Poly software or services.

| Tab | What it does |
|---|---|
| Lights | Live side-light brightness; bottom-bar colour and fade; per-chip palette and module selectors with a register readout; stored firmware light settings |
| Indicators | Mute, off-hook, ringing and hold indicators; Zoom/Teams logo on the mini-display |
| Camera | Every UVC image control the camera reports, in its native units |
| Audio | Microphone and speaker volume, mute, and system-default selection |
| Display | Resolution and refresh rate of the DisplayLink screen |

Every write reads the device back. The Lights and Indicators tabs restore the previous state if the readback does not match. Camera and Audio show the value the hardware actually applied, since zoom and volume get rounded.

## Run

Requires [uv](https://docs.astral.sh/uv/).

```sh
cd gui
uv run p21gui
```

Offline protocol tests (no hardware): `uv run python -m unittest discover tests`

## Build a standalone app

Build on each target OS; PyInstaller does not cross-compile.

```sh
uv run --group dev pyinstaller --noconfirm --windowed --name "P21 Control" --collect-data libusb_package p21gui/__main__.py
```

Drop `--collect-data libusb_package` on Windows and Linux. The app lands in `dist/`.

## How each OS is driven

| | macOS | Windows | Linux |
|---|---|---|---|
| Lights, indicators, logo | hidapi (IOKit) | hidapi, one handle per HID collection | hidapi `hidraw` backend |
| Camera | UVC requests over libusb | DirectShow `IAMCameraControl` / `IAMVideoProcAmp` | V4L2 controls |
| Audio | CoreAudio | WASAPI (pycaw) | `pactl` (PulseAudio or PipeWire) |
| Display | CoreGraphics | Win32 display settings | `xrandr` (X11 only) |

The vendor protocol code in `p21gui/vendor.py` is a direct port of `src/lights.c` and `src/hid.c`. It keeps their mux fencing, readback and restore rules. It also takes the same lock file as `p21ctl`, so the GUI and CLI never interleave vendor requests. Poly software must still stay idle.

### Verification status

- **macOS:** tested on a connected P21. Every read matches `p21ctl`. Write round-trips pass with readback and restore for bar colour, fade and palette; the stored status setting; the call indicator; the softphone logo; camera brightness and zoom (zoom 15 reads back as 13); microphone volume and mute; and side lights. A colour change after a side-light change switches the bus back. The display mode change is untested (it flickers the screen). The bundled `.app` launches.
- **Windows and Linux:** written against the platform APIs but **not yet run on hardware**.

### Platform notes

- **Linux:** install `linux/70-poly-studio-p21.rules` for HID access, and make sure your user is in the `video` group for the camera. The display needs the DisplayLink `evdi` driver and an X11 session.
- **Windows:** camera exposure is in DirectShow's log₂-seconds units, and pan/tilt are in degrees. DirectShow may not expose power-line frequency or exposure priority; the tab hides controls the driver does not report.
- **Display changes** last for the session.
- **Spectrum cycle is disabled.** The ported version rewrote the chips over I2C every frame, and that stalled the P21's USB during testing (`evidence/lighting-robustness-2026-09-15.txt`). It will return once the firmware-native `0317` cycle is verified.
- **Session handshake.** After power-up or reconnect, the P21 ignores vendor requests until the host sends BR version negotiation. Poly's background service normally does this. The app sends it automatically when a request goes unanswered. `p21ctl` does not, so with Poly's services stopped, run the app once first, or add the handshake to the CLI.
- **USB failures latch.** After a USB-level error the app sends nothing more to the P21, not even a restore or an automatic refresh, because extra transfers make a stall worse. Reconnect or power-cycle the P21, then press Refresh.
- **Firmware status events** (calls, mute) can override lighting at any time. After a live side-light change, the firmware leaves the LED bus on a side channel. The next colour change switches it back with the firmware's own LED command (the bar briefly shows dim white). Fade and palette changes wait until then.
