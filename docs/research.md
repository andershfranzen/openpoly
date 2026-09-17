# Poly Studio P21 host-interface research

**Research date:** 2026-09-15
**Scope:** host-visible interfaces for the LCD, camera, microphone/speakers, buttons, status/vanity lights, and firmware mode. This record separates vendor documentation and public source code from observations made on the connected unit. It does not claim a P21 wire command unless a source documents that command.

## Executive result

The P21 is best treated as a composite USB peripheral. Its camera and audio function are standard USB classes, so an application can use the operating system's UVC/UAC APIs without Poly Studio/Lens. The LCD is a DisplayLink USB graphics function: Poly's own documentation explicitly requires display software for the display, while stating that the camera, speakers, microphone, and vanity lights work without that software.

This gives two practical meanings of “without the Poly app”:

1. **Use native class drivers for camera and audio, and keep an independent DisplayLink host driver for the LCD.** This removes the Poly application from the data path, but still depends on DisplayLink/Synaptics software for the screen.
2. **Remove every vendor driver as well.** This requires implementing the P21's DisplayLink rendering protocol. I found public host plumbing (EVDI) and documentation for older DisplayLink chips, but no public P21-specific rendering or LED command protocol. EVDI alone is not the USB wire protocol.

Poly's Lens Desktop help is also explicit about the boundary: the display software is required for the P21 display, but the camera, speakers, microphone, and vanity lights can be used without it ([Poly Lens Desktop Online Help, pp. 41–42](https://kaas.hpcloud.hp.com/pdf-public/pdf_8545851_en-US-1.pdf)). The P21 user guide separately says that the guide's features can be used without Lens Desktop ([Poly Studio P21 User Guide, p. 2](https://kaas.hpcloud.hp.com/pdf-public/pdf_8708481_en-US-1.pdf)). P21 support was removed from Lens Desktop 2.0 and HP Poly Studio Desktop 5.0 ([Poly Lens supported devices](https://info.lens.poly.com/docs/lensapps/Studio%20Desktop/desktop-supported-dev)).

## Legacy Poly Lens Desktop for macOS

An [HP Poly employee's release post](https://h30434.www3.hp.com/t5/Poly-Software/Software-Poly-Lens-Version-2-1-1/td-p/9367076) links the older macOS package as “Older Lens Desktop 1.4.0 version for incompatible Apple Hardware.” The link resolves to this vendor-hosted artifact:

**[Poly Lens Mac - 1.4.0.zip](https://swupdate.lens.poly.com/ZippedModelFirmware/Lens_Desktop/Poly%20Lens%20Mac%20-%201.4.0.zip)**

The official [Poly Lens Desktop 1.4.0 release page](https://info.lens.poly.com/lens-dt-rn/2024/05/16/version-1.4.0) dates the release to May 16, 2024. The official release index describes Lens 1.5 as Windows-only, making 1.4.0 the latest clearly identified macOS 1.x release in the published history. A second artifact using the same official storage path is also available: [Poly Lens Mac - 1.3.2.zip](https://swupdate.lens.poly.com/ZippedModelFirmware/Lens_Desktop/Poly%20Lens%20Mac%20-%201.3.2.zip). The release index dates 1.3.2 to February 12, 2024 ([release index, page 2](https://info.lens.poly.com/lens-dt-rn/page/2)).

Read-only HTTP metadata observed on 2026-09-15:

| Artifact | HTTP result | Size | Last-Modified | ETag | Published checksum |
|---|---:|---:|---|---|---|
| 1.4.0.zip | 200, `application/octet-stream` | 179,668,400 bytes | 2024-05-16 19:12:32 GMT | `"0x8DC75DC23845566"` | None found |
| 1.3.2.zip | 200, `application/octet-stream` | 178,325,801 bytes | 2024-02-12 21:33:16 GMT | `"0x8DC2C1239B93E98"` | None found |

The storage response did not include `Content-MD5`; `.sha256`, `.sha256sum`, `.md5`, and `.sig` sidecar URLs returned 404 for both artifacts. The Azure-style ETag is an opaque cache/version token and must not be treated as a cryptographic checksum. No package was downloaded, installed, or executed for this check. An HP Community user later reported a corrupt 1.4.0 ZIP, so preserve the byte length and ETag when obtaining it and independently hash a downloaded copy before static analysis ([field report](https://h30434.www3.hp.com/t5/Poly-Software/Poly-Lens-Mac-1-4-0-zip-is-corrupt/td-p/9486618)); that report is not a vendor integrity statement and was not independently reproduced here.

The official release page calls the product version `1.4.0`; a secondary patch catalog labels the Windows build `1.4.0.6062`. I found no primary vendor page that assigns that build number to the macOS ZIP, so use `1.4.0` as the verified macOS identity until package metadata is inspected.

## Evidence map

| Function | What is documented | Current confidence | What remains unknown |
|---|---|---:|---|
| LCD/display | P21 display requires DisplayLink display software; USB 3 is required for the full 1080p display path ([User Guide, pp. 3 and 6–7](https://kaas.hpcloud.hp.com/pdf-public/pdf_8708481_en-US-1.pdf)). | High for dependency | P21's runtime DisplayLink stream, packet framing, compression, and control requests are not public. |
| Camera | P21 is used as a USB camera; Poly documents image controls such as brightness, contrast, hue, saturation, sharpness, gamma, white balance, backlight compensation, gain, and exposure ([Lens Help, pp. 44–45](https://kaas.hpcloud.hp.com/pdf-public/pdf_8545851_en-US-1.pdf)). The device reports as UVC in the local inventory. | High for class path | Exact UVC Extension Unit GUIDs/selectors and which Poly controls map to standard Processing Unit controls are descriptor-dependent. |
| Microphone/speakers | Poly documents selecting P21 audio in the operating system/conferencing application and using the microphone, speakers, mute, volume, and headset path without Lens ([User Guide, pp. 11–13](https://kaas.hpcloud.hp.com/pdf-public/pdf_8708481_en-US-1.pdf)). The local inventory reports USB Audio Class. | High for class path | USB Audio entity IDs, Feature Unit selectors, endpoint formats, and any vendor DSP controls. |
| Buttons and status LEDs | The guide documents button behavior and LED meanings; Lens exposes button assignment, status-light brightness/toggles, and vanity-light settings ([Lens Help, pp. 43–44](https://kaas.hpcloud.hp.com/pdf-public/pdf_8545851_en-US-1.pdf)). | High for behavior, low for transport | No public P21 HID report descriptor, report IDs-to-functions map, or vendor output reports were found. |
| Vanity-light touch control | Poly documents a rear capacitive touch slider and ambient-light-based vanity-light behavior ([User Guide, pp. 4–5 and 12–13](https://kaas.hpcloud.hp.com/pdf-public/pdf_8708481_en-US-1.pdf)). The open-source offer names an IQS269A touch-controller driver ([Poly Open Source Offer](https://kaas.hpcloud.hp.com/pdf-public/pdf_9121719_en-US-1.pdf)); the public Linux driver identifies IQS269A as an I²C capacitive-touch controller ([Linux IQS269A driver](https://android.googlesource.com/kernel/common/+/e626cb02ee8399fd42c415e542d031d185783903/drivers/input/misc/iqs269a.c)). | Medium for internal hardware | Whether host-visible touch/lighting events use HID, a vendor interface, or only internal firmware. |
| Firmware/update mode | Public fwupd quirks identify P21 update-mode IDs `095d:9298` and `095d:9299` and a DFU plugin ([fwupd DFU quirks](https://github.com/fwupd/fwupd/blob/main/plugins/dfu/dfu.quirk)). | High for update-mode IDs | These are update-mode IDs, not proof of the runtime IDs or a usable control protocol. |

The local measurements supplied by the parent task are recorded in [measured USB controls](protocol.md). They report runtime camera `095d:9298`, audio `047f:431a`, and DisplayLink `17e9:ff18`; an earlier inventory, before DisplayLink Manager was present, showed the USB display function but no registered P21 display. The parent now reports `/Applications/DisplayLink Manager.app` version `16.2.39` running and `system_profiler` showing display id `9` at `1920x1080`. That transition is strong live evidence that the independent DisplayLink host path is the missing display dependency; the app's installation provenance is outside this research task. The same measurements show raw libusb control transfers can be issued without claiming an interface. These are useful observations, but they are not public vendor protocol documentation and should not be generalized to other firmware revisions.

## LCD: independent DisplayLink driver versus full protocol reimplementation

### What Poly documents

The P21 User Guide says that its screen does not show host output until DisplayLink driver/software is installed, and describes DisplayLink Manager permissions and automatic startup on macOS ([User Guide, pp. 6–7](https://kaas.hpcloud.hp.com/pdf-public/pdf_8708481_en-US-1.pdf)). The Lens help gives the same installation boundary and says display software is required only for the display; P21 camera/audio/vanity lights remain usable without it ([Lens Help, pp. 41–42](https://kaas.hpcloud.hp.com/pdf-public/pdf_8545851_en-US-1.pdf)).

The guide also warns that the supplied cable is directional and that USB 3 is needed for full 1080p. Therefore a failure to see a registered monitor does not by itself show that the panel is defective: the USB function can enumerate while the host-side DisplayLink graphics stack is absent or not attached.

The P21 release notes list separate DisplayLink driver requirements alongside Lens firmware updates, with macOS and Windows DisplayLink driver versions tested for the supported operating systems ([P21 Release Notes, pp. 1 and 4](https://kaas.hpcloud.hp.com/pdf-public/pdf_14780118_en-US-1.pdf)). That is additional evidence that DisplayLink is a separate host dependency from the Poly configuration application.

### What public DisplayLink source provides

DisplayLink's [EVDI project](https://displaylink.github.io/evdi/) is a host-side virtual DRM/display interface. Its documentation describes EVDI as the userspace/Linux virtual display layer used as the base of the DisplayLink Ubuntu driver for USB 3 docks and adapters. The [public displaylink-rpm package specification](https://github.com/displaylink-rpm/displaylink-rpm/blob/master/displaylink.spec) shows the typical host architecture: a udev trigger recognizes DisplayLink vendor ID `17e9` and starts a proprietary `displaylink-driver.service`; the package itself links to EVDI and a proprietary Synaptics driver.

This establishes an actionable, lower-risk route: use the platform's DisplayLink driver and EVDI/equivalent host display plumbing, while using native UVC/UAC/HID APIs for the other functions. It does **not** establish that EVDI can send a P21 stream by itself. The actual DisplayLink USB encoder/transport remains in the proprietary driver.

### A documented legacy protocol is not a P21 protocol

The public [EspUsbHost DisplayLink notes](https://github.com/tanakamasayuki/EspUsbHost/blob/main/docs/usb-display-spec.md) document an older DL-1x0/DL-1x5 (“Alex/Ollie”) family, tested with `17e9:0360`. They describe a vendor-class interface with bulk OUT endpoint `0x01` for commands/pixel data and these control requests:

| Request in the public legacy notes | Documented meaning | P21 applicability |
|---|---|---|
| `bmRequestType=0x40`, `bRequest=0x12`, `wValue=0`, `wIndex=0`, 16-byte key `57 CD DC A7 1C 88 5E 15 60 FE C6 97 16 3D 47 F2` | Select a channel; the notes say the standard key leaves encryption off. | **Unknown and unsafe to apply.** The source targets `17e9:0360`, not the P21 runtime `17e9:ff18`. |
| `bmRequestType=0xC0`, `bRequest=0x02`, `wValue=i<<8`, `wIndex=0xA1`, two-byte IN data | Read one EDID byte at a time; the notes use the second returned byte. | **Unknown.** Treat only as a historical comparison after matching the P21 descriptor/chip generation. |
| Vendor-specific descriptor type `0x5F` | The notes mention a maximum-pixel-count descriptor but do not document its complete layout. | **Unknown.** Do not parse it as a P21 descriptor without a matching descriptor capture. |

For the same legacy family, the notes document bulk commands beginning with `AF`: `AF 20 reg val` (register write), `AF 6B ...` (RLE-compressed RGB565 pixel write), `AF 60 ...` (uncompressed pixel write), `AF 6A`/`AF 62` (rectangle copy), and `AF A0` (flush). The source describes a frame-buffer command stream on bulk OUT `0x01`. These commands are included as a protocol comparison only; their presence in a public DL-1xx implementation is not evidence that the P21 `ff18` function accepts them.

The legacy source is valuable for identifying the kind of reverse engineering required, but it is not evidence that any of those requests work on `ff18`. No public P21 stream framing, command sequence, compression format, or panel-brightness request was found. The correct next step is descriptor capture and passive comparison while a known DisplayLink driver changes state; active fuzzing or arbitrary control writes would risk the device.

## Camera: use UVC, then discover vendor extensions

The P21 camera can be handled through standard UVC. USB-IF publishes the [USB Video Class 1.5 document set](https://www.usb.org/document-library/video-class-v15-document-set); Linux's [uvcvideo documentation](https://www.kernel.org/doc/html/v4.12/media/v4l-drivers/uvcvideo.html) explains that vendor-specific Extension Units (XUs) must be discovered from descriptors and can be queried through `UVCIOC_CTRL_QUERY`. The current Linux UVC userspace interface is also documented in the [kernel UVC driver API](https://cdn.kernel.org/doc/html/latest/userspace-api/media/drivers/uvcvideo.html).

The standard control-transfer building blocks documented by the UVC class headers are:

| Direction | Setup | Meaning | Constraint |
|---|---|---|---|
| IN | `bmRequestType=0xA1`, `GET_CUR=0x81` | Read current control value | `wValue`, `wIndex`, and length come from the descriptor. |
| IN | `0xA1`, `GET_MIN=0x82`, `GET_MAX=0x83`, `GET_RES=0x84`, `GET_LEN=0x85`, `GET_INFO=0x86`, `GET_DEF=0x87` | Discover value/range/permissions | Query the control's unit ID and selector first. |
| OUT | `bmRequestType=0x21`, `SET_CUR=0x01` | Write current control value | Only write when `GET_INFO` reports writable and the control is not disabled by an automatic mode. |

These values are generic UVC class requests, not P21-specific bytes; the request-code definitions are in the [Linux UVC USB header](https://github.com/torvalds/linux/blob/master/include/uapi/linux/usb/video.h), while the USB-IF specification is authoritative for the class. A control request is normally addressed with `wValue=selector<<8` and `wIndex=unit<<8 | video-control-interface`; the unit and selector must be read from the P21's descriptors rather than guessed.

On Linux, the least fragile interface is V4L2: enumerate `/dev/video*`, formats, and controls with `v4l2-ctl` or the [V4L2 control API](https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/control.html). On macOS, use AVFoundation/IOKit to enumerate the UVC camera and its formats. Use a raw XU query only for a feature that is absent from the standard UVC controls, after recording the XU GUID, unit ID, selector, length, and `GET_INFO` permissions.

The local P21 probe found a UVC control interface and a streaming interface, with terminal ID 1 and processing unit ID 3; the measured control map and readback results are in [protocol.md](protocol.md). That is sufficient to build a camera controller around descriptors and standard requests. It does not prove that every Lens image setting has a standard UVC selector or that a software privacy control actuates the physical shutter.

## Microphone and speakers: use UAC/ALSA/CoreAudio

USB Audio Class is the corresponding standard path for the P21 microphone and speakers. The [USB Audio Class 1.0 specification](https://www.usb.org/sites/default/files/audio10.pdf) defines class-specific descriptors, controls, requests, and audio formats; the USB-IF's [Audio Class document page](https://www.usb.org/document-library/usb-audio-devices-release-40-and-adopters-agreement) describes the class as applying to functions that manipulate audio, including gain and tone.

On Linux, [`snd-usb-audio`](https://docs.kernel.org/sound/alsa-configuration.html) creates the normal ALSA USB audio devices. Use ALSA/PipeWire (`wpctl`, `alsamixer`, or the relevant API) to enumerate capture/playback endpoints, mute, and volume. On macOS, use CoreAudio to select the P21 input/output and control the streams. The UAC class's `GET_CUR`/`SET_CUR` style controls are addressed to descriptor-defined entities and control selectors; no P21 entity IDs or vendor DSP packet layout were found, so a raw transfer implementation must parse the AudioControl descriptor first.

The local inventory reports P21 audio control interface 0, streaming interfaces 1/2, and an additional HID interface 3 ([protocol.md](protocol.md)). This supports separating standard audio streaming from the button/feature channel. Physical mute and headset-button behavior may be represented by HID or firmware state in addition to the UAC Feature Unit; the public documentation does not identify the event transport.

## Buttons, status LEDs, and vanity lights

### Documented behavior

The P21 User Guide documents these status-light states: solid white for USB connected/idle, blue expansion while the wireless charger is charging, pulsing amber during firmware update, green for incoming/active call states, pulsing red for a held call, solid red when muted, and sea-foam while adjusting volume ([User Guide, pp. 7–8](https://kaas.hpcloud.hp.com/pdf-public/pdf_8708481_en-US-1.pdf)). It also documents a physical mute button, headset toggle, volume controls, and a rear touchpad for vanity-light brightness ([User Guide, pp. 12–13](https://kaas.hpcloud.hp.com/pdf-public/pdf_8708481_en-US-1.pdf)).

Lens configuration exposes Rocket Button assignment, App Button softphone selection, status-light brightness, per-state status-light toggles, and automatic/manual vanity-light levels ([Lens Help, pp. 43–44](https://kaas.hpcloud.hp.com/pdf-public/pdf_8545851_en-US-1.pdf)). These are documented product behaviors, not a report of how the host controls them.

### Transport evidence and safe boundary

USB HID is the most plausible host input/output surface for buttons and feature controls, but the public P21 material does not publish a HID report descriptor or report map. The [USB HID 1.11 specification](https://www.usb.org/sites/default/files/hid1_11.pdf) defines report descriptors and `GET_REPORT`/`SET_REPORT`; Linux's [hidraw documentation](https://docs.kernel.org/hid/hidraw.html) describes reading and writing raw reports without imposing a semantic parser.

Local measurements in [protocol.md](protocol.md) found:

* a camera-side HID interface with vendor usage pages `ffa0` and `ff99`;
* an audio/control HID interface with raw feature reports `01`, `05`, `06`, and `9a`;
* standard LED-page output reports whose IDs alone do not establish which physical light they drive.

Those report IDs are inventory evidence only. No output bytes should be invented from the report names or usage pages. To map a function, save the complete report descriptor, capture read-only input reports while pressing one button, and correlate one known state transition at a time. Only after a report's fields and permissions are established should a controller attempt `SET_REPORT` or an interrupt-OUT report. The side vanity lights may be driven wholly inside the device: the published IQS269A source is an internal I²C touch-controller driver, not a P21 host-control protocol.

## Documented protocol candidates and their limits

| Candidate | Evidence | Safe use in a P21 implementation |
|---|---|---|
| UVC standard requests (`GET_*`, `SET_CUR`) | USB-IF UVC documents and the Linux UVC header/API linked above | Parse the P21 descriptor, then use standard controls; do not assume unit IDs/selectors on another firmware. |
| UVC XU query (`UVCIOC_CTRL_QUERY`) | Linux `uvcvideo` documentation | Use only after obtaining XU GUID/unit/selector/length and `GET_INFO`; unknown XUs are not safe to write. |
| UAC entity controls | USB Audio Class 1.0 specification | Parse AudioControl entities and use ALSA/CoreAudio first; raw setup values need the P21 descriptor. |
| HID `GET_REPORT`/`SET_REPORT` | USB HID specification | Read descriptors/reports first. P21 report IDs observed locally have no public field map; do not write them yet. |
| DisplayLink `0x40/0x12` channel-key request and `0xC0/0x02` EDID request | EspUsbHost notes for legacy `17e9:0360` | Historical comparison only. Do not send to P21 `17e9:ff18` until the USB descriptor and chip generation are proven compatible. |

There is no documented P21-specific command for status LED color/state, vanity-light level, display brightness, display stream framing, or DisplayLink panel initialization in the sources reviewed. The product UI proves that such controls exist; it does not make their packet format public.

## Recommended app-free implementation boundary

1. **Camera:** enumerate the UVC node and use AVFoundation/V4L2. Discover standard controls first; preserve automatic-mode semantics and verify readback. Add XU support only from a captured descriptor.
2. **Audio:** enumerate P21 UAC capture/playback endpoints through CoreAudio or ALSA/PipeWire. Treat mute/volume as UAC controls when exposed and separately log HID button events.
3. **Buttons/lights:** obtain report descriptors and build a read-only event logger. Correlate mute, headset, volume, Rocket, app, charging, and call-state transitions. Keep status LEDs and vanity lights as separate hypotheses until reports prove the mapping.
4. **Screen:** use an independent DisplayLink driver if “no Poly app” is the requirement. If no third-party display software is allowed, plan a separate DisplayLink protocol project: capture descriptors, observe the proprietary driver's traffic, identify the P21 generation, and implement only after packet framing is understood. EVDI can provide the virtual display plumbing but cannot replace the proprietary USB encoder/transport by itself.
5. **Validation:** keep captures passive and reversible. Do not reuse legacy DisplayLink keys, P21 DFU IDs, or raw HID report IDs as commands without descriptor/provenance evidence.

## Unknowns that require live capture

* Full configuration descriptors for every runtime interface, including alternate settings, endpoint directions, and HID report descriptors.
* P21 UVC XU GUIDs and selectors, if any; mapping from Lens settings to standard Processing Unit versus XU controls.
* P21 UAC entity topology, Feature Unit selectors, and firmware DSP controls.
* Which HID reports represent button inputs, call-state feedback, status LEDs, and vanity-light levels; whether output is interrupt, control, or internal-only.
* DisplayLink `17e9:ff18` generation, stream initialization, compression/framing, EDID path, and display-brightness control.
* Whether the `095d:9298` ID observed at runtime is shared by camera and DFU mode on this firmware; fwupd's `095d:9298/9299` entries alone cannot answer that.

No public source reviewed supplies those P21-specific packet maps. The parent task's live measurements make descriptor-first, passive capture the highest-value next step.

## Sources

Primary/vendor sources:

* [Poly Studio P21 User Guide (HP/Poly PDF)](https://kaas.hpcloud.hp.com/pdf-public/pdf_8708481_en-US-1.pdf)
* [Poly Lens Desktop for Windows and Mac Online Help (HP/Poly PDF)](https://kaas.hpcloud.hp.com/pdf-public/pdf_8545851_en-US-1.pdf)
* [Poly Studio P21 Release Notes (HP/Poly PDF)](https://kaas.hpcloud.hp.com/pdf-public/pdf_14780118_en-US-1.pdf)
* [Poly Open Source Offer](https://kaas.hpcloud.hp.com/pdf-public/pdf_9121719_en-US-1.pdf)
* [Poly Lens Desktop 1.4.0 release page](https://info.lens.poly.com/lens-dt-rn/2024/05/16/version-1.4.0)
* [Poly Lens Desktop release index, including 1.3.2 and 1.4.0](https://info.lens.poly.com/lens-dt-rn/page/2)
* [Poly Lens supported devices](https://info.lens.poly.com/docs/lensapps/Studio%20Desktop/desktop-supported-dev)
* [USB-IF USB Video Class 1.5 document set](https://www.usb.org/document-library/video-class-v15-document-set)
* [USB-IF USB Audio Class 1.0 specification](https://www.usb.org/sites/default/files/audio10.pdf)
* [USB-IF USB HID 1.11 specification](https://www.usb.org/sites/default/files/hid1_11.pdf)
* [DisplayLink EVDI documentation](https://displaylink.github.io/evdi/)

Public source implementations/reference material:

* [Linux UVC USB header](https://github.com/torvalds/linux/blob/master/include/uapi/linux/usb/video.h)
* [Linux UVC driver API](https://cdn.kernel.org/doc/html/latest/userspace-api/media/drivers/uvcvideo.html)
* [Linux V4L2 control API](https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/control.html)
* [Linux USB audio configuration (`snd-usb-audio`)](https://docs.kernel.org/sound/alsa-configuration.html)
* [Linux IQS269A I²C touch-controller driver](https://android.googlesource.com/kernel/common/+/e626cb02ee8399fd42c415e542d031d185783903/drivers/input/misc/iqs269a.c)
* [Linux hidraw raw HID API](https://docs.kernel.org/hid/hidraw.html)
* [DisplayLink EVDI source](https://github.com/DisplayLink/evdi)
* [displaylink-rpm udev/service packaging](https://github.com/displaylink-rpm/displaylink-rpm/blob/master/displaylink.spec)
* [EspUsbHost legacy DisplayLink protocol notes](https://github.com/tanakamasayuki/EspUsbHost/blob/main/docs/usb-display-spec.md)
* [fwupd P21 DFU quirks](https://github.com/fwupd/fwupd/blob/main/plugins/dfu/dfu.quirk)
* [HP Community post linking the legacy 1.4.0 macOS artifact](https://h30434.www3.hp.com/t5/Poly-Software/Software-Poly-Lens-Version-2-1-1/td-p/9367076)
* [Vendor-hosted Poly Lens Mac 1.4.0 ZIP](https://swupdate.lens.poly.com/ZippedModelFirmware/Lens_Desktop/Poly%20Lens%20Mac%20-%201.4.0.zip)
* [Vendor-hosted Poly Lens Mac 1.3.2 ZIP](https://swupdate.lens.poly.com/ZippedModelFirmware/Lens_Desktop/Poly%20Lens%20Mac%20-%201.3.2.zip)
* [HP Community field report about 1.4.0 ZIP corruption](https://h30434.www3.hp.com/t5/Poly-Software/Poly-Lens-Mac-1-4-0-zip-is-corrupt/td-p/9486618)
