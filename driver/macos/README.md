# Independent P21 display driver

The complete desktop-to-USB path is implemented for the attached P21 Firefly
firmware 12.2.15. Physical output and pointer movement were confirmed by the user
with DisplayLink stopped on 20 September 2026. Native-app integration is built; its
separate macOS Screen Recording permission is required on first use.

- `p21-desktop-host`: CoreGraphics virtual display, 60 Hz ScreenCaptureKit capture,
  native Haar encoding, per-strip caches and parallel encoding of changed regions.
- `p21-display.cjs`: session lifecycle, vendor handover, reconnect and shutdown.
- `dl3-session.cjs`: fresh HDCP exchanges, authenticated control/video sessions.
- `p21-video.cjs`: measured Firefly mode, mixed codebooks, video memory allocation,
  pointer-table commits and per-bank delta updates.
- `p21-usb-bridge`: libusb interface 0 only, bounded transfers and idle watchdog.
- `p21-brightness.cjs`: measured DDC/CI VCP 0x10, 32 hardware backlight levels,
  checksum-checked readback, and settling time between requests.
- `p21-display-settings.cjs`: validated desktop modes, scaled to the fixed panel.

The source-tree command is `node driver/macos/p21-display.cjs --run --take-over`.
Use `--seconds 30` for a bounded trial. The native app bundles the runtime and
helpers. Unexpected hardware/firmware is rejected; there are no resets, firmware
writes or DFU operations. Frames that exceed a 1.5 MiB video bank are re-encoded with fewer fine-detail
coefficients, preserving an image instead of stopping the driver.
The existing helper below remains available for descriptor and capture research.

`--resolution` accepts `1920x1080`, `1600x900`, `1280x720`, or `960x540`;
`--refresh` accepts `60` or `30`. These configure the virtual desktop and capture
interval, preserving the measured 1920×1080/60 panel signal. `--brightness 0..100`
sets and verifies the backlight. Omitting it reads the current brightness without
changing it. With `--parent-pipe`, newline-delimited JSON accepts `settings`
commands (`width`, `height`, `refreshHz`) and `brightness` commands (`percent`).
EOF or a `stop` line cleanly stops the session. Pending settings are coalesced;
USB work remains serialized with frame writes.

```sh
./driver/macos/build.sh
./build/p21-display-host --probe
./build/p21-display-host 5
./build/p21-capture-dump --assume-u16-lengths --records Dl3UsbData_0.log
./build/p21-capture-dump --assume-u16-lengths --extract dl3-payload.bin Dl3UsbData_0.log
./build/p21-capture-dump --assume-u16-lengths --extract dl3-payload.bin oldest.log newer.log newest.log
```

`--probe` performs descriptor-only discovery. It verifies `17e9:ff18`, the
`ff/00/03` DL3 interface, bulk endpoints `0x02`/`0x84`, their 1024-byte packet
size, and the `FflyMoni` identity. It does not open, claim, reset, detach, or
write to the USB device, so it can run while DisplayLink Manager owns the
interface.

`p21-capture-dump` parses the raw recorder format built into DisplayLink
Manager. Each record is a six-byte `[XXXX]` header of uppercase hexadecimal
digits followed by exactly XXXX binary payload bytes. `--records` prints record
offsets and lengths; `--extract` concatenates the payloads. Extraction accepts
multiple capture files in the explicit chronological order given. It uses
exclusive output creation so a capture or existing analysis result cannot be
truncated accidentally. Extraction does not imply a transfer direction or
decode the DL3 protocol. Those facts must be established from a controlled
sample and its surrounding timeline.

The `[XXXX]` header is not the whole length. Static analysis of DisplayLink
Manager 16.2.39 shows the recorder writes the full 32-bit payload length with
`basic_ostream::write`, while the header encodes only bits 15..0 of that value,
and no upper bound of 65535 bytes has been established in the producer. The
tool therefore refuses to parse, list, or extract anything without
`--assume-u16-lengths`, and the library entry point is named
`p21_dl3_capture_parse_u16` for the same reason. Pass the flag only for logs
whose records are known to be at most 65535 bytes: a 65536-byte record is
written in full but framed as `[0000]`, and any two lengths that differ by a
multiple of 65536 produce identical headers, so this framing cannot detect that
aliasing in general. `[0000]` is rejected rather than accepted as an empty
record, because the recorder skips zero and negative lengths and never emits
one. The parser consumes exactly the declared payload bytes and never
resynchronizes on a `[` byte found inside payload.

macOS may request Screen Recording permission on first capture. The virtual
display uses the private `CGVirtualDisplay` API because Apple does not publish a
display-provider API for DriverKit. It therefore targets direct distribution,
not the Mac App Store.

The minimal private declarations are derived from VirtualDisplayKit. Its MIT
terms and attribution are preserved in `LICENSE.VirtualDisplayKit`. The session and Haar construction also adapt the GPL-2.0-only Vino driver.
Those display components use GPL-2.0-only; see ../licenses/GPL-2.0.txt.
