# Open-source DisplayLink feasibility for the Poly Studio P21

> **Implementation status (2026-09-21):** The research below describes the
> landscape before the P21 Firefly protocol was completed. This repository now
> contains an independent macOS driver in [`driver/macos`](../driver/macos/README.md).
> It has been verified on the physical P21 after DisplayLink Manager was removed.
> The original assessment remains here as the provenance for the implementation.

Research date: 2026-09-20. Scope: the P21 display USB function observed as
`17e9:ff18`, and a replacement for Synaptics/DisplayLink Manager on macOS.
This note uses local descriptor evidence plus official Apple and Synaptics/
DisplayLink documentation and upstream source. No vendor executable was run
and no hardware was accessed during this research.

## Assessment

At the time of this survey there was no drop-in open-source **macOS** driver that
could make the P21 a normal macOS display without DisplayLink Manager. A current
open-source exception existed on Linux: Vino v3 was a real DL3 kernel DRM driver
for three other families, but it deliberately declined Firefly, the family
identified by this P21's descriptor. OpenPoly subsequently filled that P21/macOS
gap with the clean-room implementation linked above.

The public projects cover different layers:

* **EVDI/libevdi** is the Linux virtual-display handoff between a DRM device
  and a userspace client. EVDI explicitly says that it is generic, is not tied
  to a bus or transport, and is **not a complete DisplayLink driver**.
* **Vino v3** is a current open-source Linux kernel driver that implements
  modern DL3 initialization, encrypted control, monitor management, mode
  programming, compression, and USB submission. Its supported profiles are
  Ella, Ridge, and Navarro; its source recognizes Firefly but returns no
  Firefly profile. It is therefore useful protocol evidence and a possible
  Linux reference, not a P21 macOS driver.
* **libdlo, `udl`, and `udlfb`** contain host-side USB command and pixel
  encoding for the older DL-1xx families. Their sources do not establish
  compatibility with the P21's modern USB 3/DL3 path.
* **`xf86-video-displaylink`** is an old X.org layer on top of a Linux
  framebuffer driver. It is neither a macOS driver nor the USB transport.
* Synaptics' own packaging guide identifies EVDI/libevdi as the open pieces,
  then separately ships a `DisplayLinkManager` user-mode binary and firmware
  images for DL-3xxx, DL-4xxx, DL-5xxx, and DL-6xxx devices.

Therefore, baking EVDI, libdlo, or `udl` into this macOS project cannot remove
the proprietary P21 transport implementation. A clean-room replacement would
need both a new P21/DL3 USB protocol implementation and a macOS display
publication mechanism. Apple documents the first half (custom USB access), but
does not document a third-party host display-output DriverKit family.

## What is known about the P21 hardware

The repository's primary measurements record:

* USB identity `17e9:ff18`, product `Poly_Studio_P21_Display`;
* USB link speed `5,000,000,000` bits/s and `bcdUSB: 800` in the local
  inventory; and
* interface 0 as vendor class `ff`, subclass `00`, with a vendor descriptor.

See the [USB inventory](../evidence/usb-inventory.json), [descriptor record](../evidence/usb-descriptors.txt), and the [measured protocol table](protocol.md#interfaces).
Those files are measurements of this unit, not a published DisplayLink
protocol specification.

Synaptics' [DL-4xxx product page](https://www.synaptics.com/assets/product-brief/displaylink-integrated-chipset/dl-4000)
lists Poly among the products using the DL-4xxx family, includes a
“Poly Studio P21: Quick Start” example labeled under DL-4120, and describes
DL-4110/DL-4115/DL-4120 as USB 3 5 Gbps, single-output, DDR-less display
parts using the DL3 codec. The DL-4120 entry supports up to 1200p and names
integrated LVDS/eDP. This is the strongest public generation clue for the P21.
It also explains why copying Ella's framebuffer allocation would be especially
unsafe: Firefly is publicly described as DDR-less. The page does not explicitly
map PID `ff18` to a chip revision, so the exact silicon and firmware revision
remain unproven.

The contrast with the older family is explicit in Synaptics' [DL-1x5 product
brief](https://www.synaptics.com/sites/default/files/displaylink/assets/displaylink-1x5-series-product-brief.pdf):
DL-1x5 is USB 2, uses DL2 compression, and its host DL2 driver is described as
fully open-source. The P21's measured USB 3-class hardware and the DL-4xxx/DL3
clues put it outside the scope of that old disclosure.

### The P21's DL3 identity and the Vino v3 boundary

The local [read-only P21 display inventory](p21-display-local.md) records a
DisplayLink function with interface class `ff`, subclass `00`, protocol
`03`, and only bulk endpoints `0x02` (OUT) and `0x84` (IN). Its type-`0x40`
identity descriptor ends in the eight-byte platform name `FflyMoni`.

The upstream [Vino v3 branch](https://github.com/FireBurn/linux/tree/vino-v3) contains
the [firmware source](https://raw.githubusercontent.com/FireBurn/linux/vino-v3/drivers/gpu/drm/vino/firmware.rs), which
maps both `Firefly` and `FflyMoni` to `Family::Firefly`. Vino's
[documentation](https://raw.githubusercontent.com/FireBurn/linux/vino-v3/Documentation/gpu/vino.rst)
binds the same `17e9`/`ff`/`00`/`03` DL3 function shape and says that it
implements the complete Linux-side path: initialization, HDCP 2.2,
encrypted control, downstream monitor management, mode programming, video
compression, and USB submission. This is a genuine modern open-source
DisplayLink implementation, unlike EVDI alone.

The boundary is explicit in Vino's [profile source](https://raw.githubusercontent.com/FireBurn/linux/vino-v3/drivers/gpu/drm/vino/profile.rs):
the current profiles are Ella, Ridge, and Navarro, while
`for_family(Family::Firefly)` returns `None` with the comment “Firefly has
never been seen here at all.” Vino's Ella profile uses only `0x02`/`0x84`
and serializes control and video on that shared pipe. The P21 endpoint shape
is consistent with that topology, but matching endpoints do not prove matching
codec geometry, frame records, mode constants, pacing, authentication
sequencing, or recovery behavior. Vino itself treats these as family-profile
measurements and declines an unknown family rather than guessing and resetting
the device. Its source is marked GPL-2.0-only, so any code reuse also needs a
license review.

This changes the landscape conclusion precisely: **modern DL3 protocol code
now exists in open source for Linux, but the P21's Firefly profile is still
missing, and Vino has no macOS implementation.** Vino v3 is a Linux
kernel/RFC branch rather than a macOS component, and its tested profiles do
not establish P21 compatibility. Reusing its protocol work in a macOS app
would still require Firefly-specific protocol evidence plus a macOS USB and
codec port. It has not been established that Firefly support fits entirely in
Vino's existing profile fields; its DDR-less design may require different
streaming behavior. The local prototype handles display publication with a
private API.

### Local macOS host prototype

This repository now contains a tested macOS host prototype in
[`driver/macos`](../driver/macos/README.md). It creates a 1920x1080@60 virtual
display with the private `CGVirtualDisplay` API, discovers that display through
ScreenCaptureKit, and receives BGRA frames. A local two-second run received 113
1920x1080 frames. This proves the macOS display-publication and capture half of
the architecture on the development Mac without calling DisplayLink Manager.

`CGVirtualDisplay` is a private CoreGraphics API, so this is suitable for a
directly distributed local tool rather than the Mac App Store. The prototype
does not yet light the physical P21 panel: the missing half is the Firefly DL3
profile and USB encoder/transport that consumes those captured frames.

## What the open-source projects actually implement

### EVDI/libevdi

The upstream [EVDI README](https://github.com/DisplayLink/evdi/blob/main/README.md)
defines EVDI as a Linux kernel module plus `libevdi` wrapper. It lets a
userspace program receive screen updates and exposes a virtual display through
Linux DRM. The same README states that EVDI is generic, not tied to a bus or
transport, and “not a complete driver for DisplayLink devices.”

The [EVDI quick start](https://github.com/DisplayLink/evdi/blob/main/docs/quickstart.md)
shows the intended division: a client connects EVDI to DRM, receives dirty
pixel buffers, and then does whatever transport work the application provides.
EVDI does not open a USB endpoint, select a DisplayLink channel, encode a DL3
frame, or initialize a P21.

The official [DisplayLink packaging guide](https://support.displaylink.com/knowledgebase/articles/679060)
is unambiguous about the modern stack. It lists:

* open-source EVDI and `libevdi`;
* a separate `DisplayLinkManager` user-mode binary driver;
* separate firmware images for DL-3xxx, DL-4xxx, and DL-6xxx devices; and
* standard `libusb` used by the manager to access DisplayLink USB devices.

That is direct vendor evidence that EVDI is the display plumbing, not the
device-side USB protocol implementation. The [upstream EVDI module
README](https://github.com/DisplayLink/evdi/blob/main/module/README.md) also
describes EVDI as primarily used by the proprietary userspace DisplayLink
driver that performs device enumeration and control.

EVDI is Linux-specific: it is a Linux kernel module and Linux DRM device, so
it cannot simply be embedded in a macOS application or DriverKit extension.

### libdlo

The archived [official libdlo project page](https://libdlo.freedesktop.org/wiki/)
states that libdlo is LGPL 2.1 reference code and explicitly limits support to
DL-120/DL-160 (DL-1x0, “Alex”) and DL-125/DL-165/DL-195 (DL-1x5, “Ollie”). It
also describes the technology in that project as a proprietary protocol over
USB 2.0.

Thus libdlo is useful evidence of a historically published DL-1xx wire
implementation, but it is not a P21 driver. It has no published DL3/P21
initialization, compression, EDID, hotplug, or recovery path.

### Linux `udl` and `udlfb`

The current Linux sources retain the same legacy protocol. The mainline
[`udl` USB match table](https://raw.githubusercontent.com/torvalds/linux/master/drivers/gpu/drm/udl/udl_drv.c)
matches DisplayLink's VID plus vendor interface class `0xff`, subclass `0x00`,
and protocol `0x00`; its comment says this was compatible with known **USB 2.0
era** graphics chips while allowing future incompatible chips to change those
fields. A matching rule is not proof that a device accepts the driver's
commands.

The protocol is visible in the upstream source:

* [`udl_proto.h`](https://raw.githubusercontent.com/torvalds/linux/master/drivers/gpu/drm/udl/udl_proto.h)
  defines bulk messages beginning with `0xaf`, register writes (`0x20`), and
  raw/RLE/copy pixel commands (`0x60`–`0x6b`).
* [`udl_modeset.c`](https://raw.githubusercontent.com/torvalds/linux/master/drivers/gpu/drm/udl/udl_modeset.c)
  programs the old register-based display mode and framebuffer layout.
* [`udl_main.c`](https://raw.githubusercontent.com/torvalds/linux/master/drivers/gpu/drm/udl/udl_main.c)
  sends the well-known 16-byte standard-channel key and submits bulk URBs to
  endpoint 1.
* The older [`udlfb.c`](https://raw.githubusercontent.com/torvalds/linux/master/drivers/video/fbdev/udlfb.c)
  contains the same `0xaf` register/pixel stream and identifies its match as
  the USB 2.0-era DisplayLink interface.

These files do contain a real host-side USB protocol, but for the old DL-1xx
family. Reusing them against `17e9:ff18` would be protocol guessing. The
P21's measured USB 3 link and the DL-4xxx/DL3 evidence provide no basis for
assuming that the `0xaf` stream, channel key, endpoint assumptions, or legacy
registers are accepted by its firmware.

### `xf86-video-displaylink`

The archived [xf86-driver-displaylink page](https://libdlo.freedesktop.org/wiki/xf86-driver-displaylink/)
states that this X.org driver is designed to run on top of the Linux
`displaylink-mod` framebuffer driver. It is desktop/X integration above the
transport, not a standalone USB implementation and not a macOS component.

### Current macOS open-source work

The closest current macOS clean-room project found in upstream GitHub search,
[DisplayLink-Drivers-Reconstruct](https://github.com/durhamaustin9/DisplayLink-Drivers-Reconstruct),
is explicit that its code is a read-only probe, offline parsers, and an
in-memory fake transport. Its README says it is not an open-source DisplayLink
driver, does not send protocol bytes, and does not drive the USB graphics path.
It targets a different dock (`17e9:4323`, DL-3900/Ella), so it is useful as
evidence about the research gap, not as a P21 implementation.

Vino is the closest current modern implementation, but it is Linux kernel
code and its `Firefly` profile is intentionally absent. No functional,
macOS-capable, open-source implementation of the P21's `17e9:ff18` transport
was found in the upstream sources reviewed.

## macOS APIs and signing boundary

### USB access is publicly supported

Apple's [USBDriverKit documentation](https://developer.apple.com/documentation/usbdriverkit)
supports custom or non-class-compliant USB devices on macOS. A DriverKit
extension can use `IOUSBHostInterface`, `IOUSBHostDevice`, and
`IOUSBHostPipe` to inspect descriptors and issue control/bulk transfers. The
[`DeviceRequest` API](https://developer.apple.com/documentation/usbdriverkit/iousbhostdevice/devicerequest)
provides the control-request primitive needed for a custom protocol.

The [`com.apple.developer.driverkit.transport.usb`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.transport.usb)
entitlement matches a dext to USB descriptor fields including `idVendor`,
`idProduct`, interface class/subclass/protocol, and configuration/interface
numbers. This is enough to claim and speak to a P21 USB interface once its
protocol is independently understood.

### No documented public third-party display-output family

Apple's public [DriverKit framework list](https://developer.apple.com/documentation/driverkit)
describes USB, HID, networking, PCI, serial, and audio family frameworks. It
does not document a third-party host display-output or `IOFramebuffer`
replacement family. This is an absence in the public API catalog, not proof
that Apple's private WindowServer/display internals have no such mechanism.

The public [Quartz Display Services](https://developer.apple.com/documentation/coregraphics/quartz-display-services)
APIs enumerate online displays, inspect them, configure their modes and
positions, capture them, and stream their contents. They take an existing
`CGDirectDisplayID`; the documented API list contains no function that creates
or registers a new physical display backed by an arbitrary userspace USB
device. That makes Core Graphics useful after a display exists, but not a
supported way to publish the P21 as a new desktop display.

For this local project, the private `CGVirtualDisplay` route has been
implemented and tested. That resolves the practical publication problem for
direct distribution, while leaving the lack of a public API as a packaging and
compatibility constraint.

[ParavirtualizedGraphics](https://developer.apple.com/documentation/paravirtualizedgraphics)
is a separate VM guest-display facility. It does not provide a host API for a
USB peripheral to become a macOS desktop display.

### ScreenCaptureKit supplies frames after display publication

Apple's [ScreenCaptureKit documentation](https://developer.apple.com/documentation/screencapturekit)
and [macOS capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
provide a supported way for an app to receive frames from an existing display.
The framework requires Screen Recording permission and an
`NSScreenCaptureUsageDescription`. The local prototype publishes a virtual
display first with private `CGVirtualDisplay`, then captures that specific
display. Once the Firefly transport exists, its frames can feed the P21 while
the virtual display remains a real target in the macOS desktop coordinate
space.

### Entitlements, approval, and distribution

Apple's [DriverKit entitlement guidance](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development)
requires requesting the DriverKit entitlements from Apple, placing the dext in
the app's `Contents/Library/SystemExtensions` directory, and provisioning the
driver with the granted entitlement group. The base
[`com.apple.developer.driverkit`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit)
entitlement must be requested from Apple.

The [System Extensions installation rules](https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers)
require code-signature and entitlement validation and user approval during
activation. Apple's [System Extensions overview](https://developer.apple.com/documentation/systemextensions)
also requires the app and extension to share a Team ID unless the
redistributable entitlement applies, and requires App Store distribution or
notarization for distribution. These requirements apply if the replacement
uses a DriverKit extension. They do not establish that this project requires
one: a userspace USB client is a separate implementation option and should be
evaluated before adding a system extension. Open-source licensing does not
remove the security gates of whichever API is chosen.

## Smallest viable architecture

There are two materially different targets:

1. **True macOS external display for direct distribution.**
   A clean-room project would need a macOS USB DriverKit dext (or another
   supported USB client), a Firefly-specific P21/DL3 transport implementation,
   and a way to publish a display to WindowServer. The last part now works in
   the local prototype through private `CGVirtualDisplay`. Vino is a useful
   Linux reference for the shared DL3 portions, but has no Firefly profile.
   The remaining critical path is therefore Firefly profiling and the macOS
   USB/codec port, with private-API compatibility accepted for direct
   distribution.
2. **App-controlled mirrored sink.**
   ScreenCaptureKit can also capture an existing display after Screen Recording
   approval. A Firefly transport could send those frames to the P21 without
   publishing a separate virtual desktop. This smaller mode remains useful as
   a transport test before the full virtual-display path is enabled.

The smallest honest path toward a true replacement is therefore:

1. Use the P21's `FflyMoni` identity and `0x02`/`0x84` topology as leads, then
   measure a Firefly profile from passive, reversible observations. Do not
   copy Vino's Ella geometry merely because the endpoint addresses match.
2. Derive activation, EDID/mode, frame, compression, hotplug, sleep/wake, and
   recovery messages for `17e9:ff18`; do not reuse the DL-1xx `udl`/libdlo key
   or command stream without proof.
3. Implement and test the transport behind an exact VID:PID and descriptor
   allowlist, using Vino's DL3 code only as a protocol and architecture
   reference subject to its GPL-2.0-only license.
4. Feed the tested `CGVirtualDisplay`/ScreenCaptureKit frame source into that
   transport. Keep the private API boundary explicit in packaging and macOS
   compatibility tests.

## Go/no-go decision

* **Reuse an existing open-source DisplayLink driver for the P21 on macOS:**
  **No-go.** Vino is Linux-only and has no Firefly profile; EVDI is Linux
  display plumbing; libdlo/`udl`/`udlfb` are legacy DL-1xx transport code;
  `xf86-video-displaylink` is Linux/X.org glue.
* **Build a clean-room true-display replacement:** **partially implemented.**
  The virtual-display and capture half works locally. The Firefly-specific
  modern DisplayLink profile and USB transport remain the critical blocker;
  the macOS display-publication API used is private.
* **Remove Synaptics/DisplayLink software while preserving a normal desktop
  display:** **not complete yet.** The macOS half is demonstrated, and Vino
  supplies the shared DL3 reference implementation. Completing this for the
  physical P21 depends on measured Firefly protocol behavior and a proven
  transport/encoder. Profile values alone are not yet known to be sufficient.
  DisplayLink Manager remains necessary until our implementation drives the
  physical panel and passes restart/reconnect validation.
