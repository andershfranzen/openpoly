# P21 display: local USB and DisplayLink evidence

> **Historical snapshot:** This inventory was captured while DisplayLink Manager
> was installed so its architecture could be measured. OpenPoly's independent
> driver was subsequently implemented and verified, and DisplayLink Manager and
> HP Poly Studio were removed from the development Mac on 2026-09-21.

Read-only inventory captured on 2026-09-20 from the connected P21 on an Apple M5 Pro running macOS 27.0 (build `26A5416b`). No vendor binary was loaded by this inspection, no USB interface was claimed, and no USB write/reset/uninstall action was performed.

## Live device and display

`system_profiler SPUSBHostDataType -detailLevel full` reports:

| Property | Value |
|---|---|
| Product | `Poly_Studio_P21_Display` |
| USB vendor/product | `17e9:ff18` (DisplayLink) |
| USB product version | `0x3038` |
| USB path | USB 3.1 bus → Microchip `0424:5906` USB5906 Smart Hub |
| Location | `0x01240000` |
| Link speed | 5 Gb/s |
| Configuration | 1 |

The same P21 exposes the camera `095d:9298` at 480 Mb/s and the audio device `047f:431a` at 12 Mb/s. The display function has a USB serial string, but the value is omitted here to match the repository's existing evidence policy.

`ioreg -p IOService -l -w 0` shows the display device and both child interfaces. The display device has `UsbExclusiveOwner = "pid 999, DisplayLinkUserAgent"`. Interface 0 has `bInterfaceClass=0xff`, subclass `0x00`, protocol `0x03`, and two endpoints. Interface 1 has class `0xfe`, subclass `0x01`, protocol `0x01`, and no endpoints. The interface properties also identify the owning process as the DisplayLink user agent.

The local `p21ctl screen status` probe currently finds one CoreGraphics display matching the P21 EDID identity (vendor `0x4199` / `PLY`, product `1`): display ID `6`, `1920x1080` at 60 Hz. `system_profiler SPDisplaysDataType` lists the same output generically as `Display` at 1920x1080@60; the P21 identity comes from CoreGraphics, not the USB product name.

## Complete `17e9:ff18` descriptor shape

The read-only libusb descriptor walk found one device on bus 1, address 3:

```text
device descriptor:
  bLength=18 bDescriptorType=01 bcdUSB=0320
  bDeviceClass=ef bDeviceSubClass=02 bDeviceProtocol=01
  bMaxPacketSize0=09 idVendor=17e9 idProduct=ff18 bcdDevice=3038
  iManufacturer=1 iProduct=2 iSerialNumber=3 bNumConfigurations=1

configuration descriptor:
  bLength=09 bDescriptorType=02 wTotalLength=90
  bNumInterfaces=2 bConfigurationValue=1 iConfiguration=0
  bmAttributes=c0 MaxPower=1

interface 0, alternate 0:
  bInterfaceNumber=0 bAlternateSetting=0 bNumEndpoints=2
  bInterfaceClass=ff bInterfaceSubClass=00 bInterfaceProtocol=03
  extra (12 bytes): 0c5f01000a00040401000400
  endpoint 0:
    bEndpointAddress=02 bmAttributes=02 wMaxPacketSize=0400
    bInterval=0 bRefresh=0 bSynchAddress=0
    extra (6 bytes): 063000000000
  endpoint 1:
    bEndpointAddress=84 bmAttributes=02 wMaxPacketSize=0400
    bInterval=0 bRefresh=0 bSynchAddress=0
    extra (6 bytes): 063000000000

interface 1, alternate 0:
  bInterfaceNumber=1 bAlternateSetting=0 bNumEndpoints=0
  bInterfaceClass=fe bInterfaceSubClass=01 bInterfaceProtocol=01
  extra (25 bytes):
    092101c8000004010110400c020f0a0b3046666c794d6f6e69
```

Endpoint `0x02` is bulk OUT and `0x84` is bulk IN (`bmAttributes=0x02`); both advertise a 1024-byte max packet. The endpoint extra bytes begin with descriptor type `0x30`, consistent with a SuperSpeed endpoint companion. The raw vendor/application-specific descriptor bytes are preserved above; their semantics are not inferred from the descriptor alone.

The interface-1 extra payload ends in the ASCII identity `FflyMoni`. The local Vino analysis recognizes that identity as the Firefly family, but has no matching Firefly profile. This is a useful generation/profile lead, not proof that an older Firefly protocol or resource package is wire-compatible with this P21.

The earlier repository capture in [usb-descriptors.txt](../evidence/usb-descriptors.txt) contains the same interface and extra-descriptor bytes, but did not print endpoint records. The current walk fills that gap.

## Installed DisplayLink architecture

The active installation is `/Applications/DisplayLink Manager.app`, version `16.2.39`:

| Component | Bundle/signing identifier | Current state |
|---|---|---|
| Main user agent | `com.displaylink.DisplayLinkUserAgent` | PID 999, owns the P21 USB device |
| XPC service | `com.displaylink.DisplayLinkXpcService` | PID 1005, running as a ServiceManagement XPC service |
| Crash helper | `com.displaylink.CrashRestartHelper` | PID 1006, keep-alive-on-success helper |
| Login helper | `com.displaylink.DisplayLinkLoginHelper` | Nested LoginItems app, not observed as a separate process |

The app bundle contains only user-space Mach-O executables, LaunchAgent plists, UI resources, Metal libraries, and opaque proprietary `.spkg` resources (`ella-dock-release`, `firefly-monitor-release`, `navarro-dock-release`, `ridge-dock-release`). The `.spkg` files start with an `ELLA` container header; no source or public P21 stream implementation is present in the bundle.

The bundled launch plists submit `Contents/MacOS/DisplayLinkXpcService` and `Contents/MacOS/CrashRestartHelper`. The installed `/Library/LaunchAgents/com.displaylink.loginscreen.plist` runs `/usr/bin/open -W '/Applications/DisplayLink Manager.app'` at the LoginWindow and is marked KeepAlive. `launchctl print gui/501/com.displaylink.XpcService` exposes the two Mach endpoints `com.displaylink.XpcService.internal` and `com.displaylink.XpcService.V2`.

`DisplayLinkUserAgent` links against Apple `IOKit`, `CoreGraphics`, `IOSurface`, `Metal`, `AVFoundation`, and `ScreenCaptureKit` among other system frameworks. Its import/string tables directly reference `CGVirtualDisplay` and `SCStream`/`SCStreamOutput`, in addition to USB/display plumbing names such as `IOUSBDevice`, `UsbTransfer_EP_`, `usbVid`, `usbPid`, `usbSerialNumber`, `DlmXpc::Driver`, and `DisplayLinkDisplayV2`. This is consistent with a sandboxed user process that creates a virtual display, captures/composes frames, and drives the USB display interface through an XPC/IOKit path.

There is no DisplayLink or Synaptics item in `/Library/Extensions`, `/System/Library/Extensions`, or `/Library/SystemExtensions`; `kextstat` and `kmutil showloaded` show no DisplayLink/EVDI component. `systemextensionsctl list` contains only the unrelated Proton VPN and Tailscale network extensions. `/Library/PrivilegedHelperTools` contains no DisplayLink helper. The IORegistry therefore points to a direct user-client architecture rather than a loaded kernel extension or DriverKit display extension.

## Signature and entitlement evidence

`codesign --verify --deep --strict` succeeds for the app and all nested executables. The binaries are universal `x86_64`/`arm64` Mach-O files signed by:

```text
Developer ID Application: DisplayLink Corp (73YQY62QM3)
TeamIdentifier=73YQY62QM3
Runtime hardening enabled; notarization ticket stapled on the main app
```

The main user agent's embedded entitlements are:

```text
com.apple.security.app-sandbox = true
com.apple.security.application-groups = 73YQY62QM3.com.displaylink.DisplayLinkShared
com.apple.security.device.usb = true
com.apple.security.files.user-selected.read-only = true
com.apple.security.network.client = true
com.apple.security.temporary-exception.mach-lookup.global-name =
  com.displaylink.XpcService.internal, com.apple.backlightd
```

The XPC service and crash helper are sandboxed; the nested login helper is sandboxed and has the same application group. The main user-agent code-directory CDHash is `75cbf2c8d6f8573933b1f0a22324dc9b3a3b9638`.

## Open-source boundary and safe next seams

The repository's [research note](research.md) identifies EVDI as open-source host-side virtual display plumbing and documents public legacy DL-1xx notes for `17e9:0360`. Neither is evidence of a P21 `17e9:ff18` USB stream implementation. EVDI can supply a virtual framebuffer/DRM surface; it does not supply the P21-generation USB encoder, compression, initialization, or panel control protocol. No P21-specific open-source implementation was found in this checkout or on the installed Mac.

Static inspection found a useful passive-capture path in the signed user
agent: the configuration key `CopyUsbDataToFile`, the output prefix
`Dl3UsbData_`, and the per-transfer prefix `UsbTransfer_EP_`. The key is read
while the agent constructs its USB connection, and the enabled branch wraps
that connection with a file-copying layer. In the ARM64 slice that layer
overrides one interface slot (`+0x78`, implementation `0x10039dea0`) and calls
through to the inner interface before logging the returned byte count; the
separate `fwrite` routines are a different logger, not this recorder. The
current agent process has the sandbox data root below as its working directory:

```text
~/Library/Containers/com.displaylink.DisplayLinkUserAgent/Data
```

The agent's Nivo configuration loader scans `./` for files ending in `.ncf`.
Its `.ncf` parser consumes tagged binary records rather than text preferences.
No `.ncf` or raw capture file is currently present there. The ordinary
container preference plist also has no `CopyUsbDataToFile` key. These are
read-only observations; neither location was changed.

The official Linux 6.2 distribution was also unpacked without installing or
running it. It contains the proprietary `DisplayLinkManager` executables and
the four `.spkg` firmware resources, but no `.ncf` file that could reveal the
configuration tree or enable the recorder. Its Firefly package is 363,248
bytes with SHA-256
`0f473f3dae3d7e429e9cd97ed1d7e5680dc387b3720dfbcfd93915fb434de0b4`;
it is not byte-identical to the installed macOS package (364,048 bytes,
SHA-256 `8317987cec218d4001bf54802db6f6cacda0ce667e05ed32ca580bb40b219b9e`).
Neither opaque firmware package supplies a safe host profile, and neither will
be sent to the device.

The raw recorder format is now established statically. The recorder writes
`Dl3UsbData_0.log` once and then cycles `Dl3UsbData_1.log` through
`Dl3UsbData_9.log`, so there are ten distinct names. Before writing each record
it compares a running counter of the current file's payload bytes against 5 MiB
(5242880 bytes) and, at or above that threshold, opens the next file in the
cycle and restarts the counter with the record that triggered the rotation. The
six framing bytes are never counted. Each record is binary framed as:

```text
[XXXX]<binary payload>
```

`XXXX` is exactly four uppercase ASCII hexadecimal digits, and it is not the
whole length. In DisplayLink Manager 16.2.39 the ARM64 recorder at
`0x10039dea0` reads the provider's result, skips a zero or negative value, keeps
the full 32-bit count as the payload length, builds the header from bits 15..0
only, and then writes that full 32-bit length of payload bytes with
`basic_ostream::write`. No upper bound of 65535 bytes has been established in
the producer, so a record of 65536 bytes or more is written in full but framed
as its low 16 bits, and any two lengths that differ by a multiple of 65536
produce identical headers. This framing cannot detect that aliasing in general.
`[0000]` is rejected rather than read as an empty record, because the recorder
skips zero and negative lengths and never emits one. The recorder flushes after
each record. The record itself has no timestamp, endpoint, or direction field,
so capture direction must not be inferred from this framing alone. Ring-file
chronology must use capture timing and file metadata rather than numeric
filename order after wraparound.

`build/p21-capture-dump` implements a strict native parser for this format
under that explicit assumption. It refuses to parse, list, or extract anything
without `--assume-u16-lengths`, which the caller must pass only for logs whose
records are known to be at most 65535 bytes; the library entry point is named
`p21_dl3_capture_parse_u16` for the same reason. The parser does not
resynchronize on a `[` byte inside payload, rejects malformed, truncated, and
zero-length records, reports record offsets and lengths, and can concatenate
the binary payloads for later protocol analysis. The test fixture includes NUL,
`0xff`, and an embedded `[` to verify binary-safe framing, covers the
65535-byte boundary, and exercises the CLI refusal, zero-wrap rejection, and
output-file preservation paths. This parser does not enable capture, load
vendor code, or touch USB.

The safest next evidence seams are:

1. Establish a reversible, isolated way to use the vendor agent's `CopyUsbDataToFile` recorder, or capture the traffic with a hardware analyzer. Record one known state change at a time (connect, enable, mode change, disable), validate every output file with `p21-capture-dump`, correlate it to interface 0 endpoints `0x02`/`0x84`, and leave the DisplayLink process as the exclusive USB owner.
2. Use the existing CoreGraphics P21 identity and the DisplayLink app's XPC notifications as the display-state timeline. Record resolution/EDID changes and endpoint traffic together; do not fuzz the vendor interface or reuse legacy `17e9:0360` requests/keys.
3. Continue static-only inspection of the signed app and `.spkg` containers (`strings`, `otool`, descriptor parsing, hashes). This can map resource selection and control-flow boundaries without loading vendor code, but it cannot by itself establish the proprietary stream format.

The current evidence supports removing the Poly/Lens application from the display path once a compatible DisplayLink host implementation exists. It does not support baking EVDI alone into the macOS app as a replacement for DisplayLink Manager.
