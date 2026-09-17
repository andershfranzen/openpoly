# Poly Studio P21: measured USB controls

Measured on the connected unit on 2026-09-15. The tool uses native CoreAudio and the already-installed libusb; it does not load Poly libraries or call Poly services. Vendor processes were running during initial tests, so those tests alone do not establish behavior after uninstalling Poly.

## Bottom RGB breakthrough

BR SET `031b` accepts a diagnostic `I2C` payload in normal mode. It exposes bottom KTD2061 chips `69/6a` on mux `76`, channel mask `04`. Direct RGB writes, spectrum cycling, palette selectors, fade, and restoration passed hardware register readback. No firmware or test-mode changes are needed. The CLI commands and limits are in [README](../README.md#bottom-bar-direct-rgb-and-cycling); exact packets and static addresses are in [bottom protocol research](bottom-protocol-static.md), with [live measurements](../evidence/bottom-rgb-2026-09-15.txt).

Purple is visually confirmed. Firmware can override the colors, and mux checks are separate from transfers: reused addresses on other channels prevent an exclusive-access guarantee. The controller checks before and after access, reports detected channel changes, and verifies restored registers. Neither chip-family ID nor readback alone resolves this race.

## Immediate side lights

`lights sides LEFT RIGHT` uses native SET `0317` under the temporary `0300` RAM gate. On/off is physically confirmed without the rear pad, and independent 0/30% transitions pass register readback. Brightness rounds up to 10% steps. See [side-light firmware evidence](side-lights-firmware.md).

## Interfaces

| Function | VID:PID | Interface | Protocol |
|---|---|---|---|
| Camera | `095d:9298` | 0 control, 1 streaming | USB Video Class 1.0 descriptor |
| Camera vendor channel | `095d:9298` | 3 | HID, pages `ffa0`, `ff99` |
| Audio | `047f:431a` | 0 control, 1/2 streaming | USB Audio Class |
| Audio/vendor controls | `047f:431a` | 3 | HID, consumer/telephony/vendor collections |
| Display | `17e9:ff18` | 0 | DisplayLink vendor interface |

The webcam and audio enumerate in macOS. The DisplayLink device enumerates over USB but the P21 was absent from `SPDisplaysDataType` during inventory. Raw serial numbers and unrelated hardware details are omitted from repository evidence.

## Camera

UVC camera terminal ID 1; processing unit ID 3; video control interface 0. The CLI checks that layout against the live configuration descriptor before accessing controls.

- Read: `bmRequestType=0xa1`, `bRequest=GET_*`, `wValue=selector<<8`, `wIndex=unit<<8 | interface`.
- Write: `bmRequestType=0x21`, `bRequest=0x01` (`SET_CUR`), same value/index.
- Requests: current `81`, minimum `82`, maximum `83`, resolution `84`, information `86`, default `87`.
- Multi-byte fields are little endian. Brightness and hue are signed 16-bit; pan/tilt are two signed 32-bit fields.
- Control information bit 0: readable; bit 1: writable; bit 2: disabled by automatic mode. The tool refuses disabled writes.
- No interface claim, kernel-driver detach, or elevated privileges were needed on this Mac.

Exact selectors are in `src/camera.c`; measured ranges in `evidence/camera-controls.txt`.

### Confirmed firmware behavior

Brightness 128 → 129 → 128 worked. Zoom 10 → 20 → 10 worked. At zoom 20, pan/tilt 0,0 → 3600,0 → 0,0 worked. Original settings were restored.

The device advertises zoom step 1 but quantizes values: 11 reads back as 10; 15 reads back as 13. The CLI returns a failure on any non-matching readback and shows the actual value. It does not claim the requested setting applied. Pan/tilt at zoom 10 was ignored, while the same request at zoom 20 applied.

`auto-exposure` supports modes 1 (manual) and 8 (aperture priority), as reported by GET_RES bitmask `09`. This is a mode bitmask, not a numeric step. `exposure` is in 100-microsecond units. `power-line` 1 is 50 Hz, 2 is 60 Hz. `privacy` is a UVC software control; it is not proof of a physical privacy shutter position or complete capture isolation.

## HID inventory

Audio/control feature reads: `bmRequestType=0xa1`, `bRequest=1` (GET_REPORT), `wValue=0x0300|reportID`, `wIndex=3`. The response includes the report ID.

| Report | Total bytes | Meaning established so far |
|---|---:|---|
| `01` | 2 | Vendor feature bits; raw read only |
| `05` | 3 | Vendor feature/status bits; raw read only |
| `06` | 12 | Vendor feature/status fields; raw read only |
| `9a` | 62 | Vendor command channel; raw read only |

Descriptor also exposes standard LED-page output reports `09`, `17`, `18`, `1e`, `20`, `2a`. Their HID names alone do not prove which physical LED they drive. Do not conflate status LEDs with the side vanity lights.

No arbitrary report writes, firmware flashing, factory resets, or USB fuzzing are included.

## Protocol references

- [libuvc UVC control selector definitions](https://github.com/libuvc/libuvc/blob/master/include/libuvc/libuvc.h)
- [libusb synchronous control transfers](https://libusb.sourceforge.io/api-1.0/group__libusb__syncio.html)
- [USB-IF video class document library](https://www.usb.org/documents?search=video)

## Verified status indicator writes

HID `SET_REPORT`: `bmRequestType=0x21`, request `09`, value `0x0200|reportID`, interface 3, two bytes `[reportID, onOff]`.

- Mute indicator: output report `09`; feature `05` byte 1 bit 2 mirrors the value.
- Call/off-hook indicator: output report `17`; feature `05` byte 1 bit 3 mirrors the value.

Both were toggled for five seconds and restored; both readbacks matched. The user confirmed the bottom status light visibly changed during the mute test. This does not establish vanity-light control or microphone audio muting. Use CoreAudio for microphone mute. See [USB-IF HID Usage Tables, LED page](https://www.usb.org/sites/default/files/hut1_12.pdf) for standard usage semantics.

## CoreAudio and screen verification

Audio reads select the exact P21 name and the matching input/output stream scope, refusing ambiguity. Microphone gain/mute use the master element; speakers expose separate channel 1 and 2 controls. Setters preflight all channels and attempt restoration on partial failure. They read back changes; scalar volume allows half a percentage point of rounding.

Verified on this unit: microphone 75% → 50% → 75%; both speakers 100% → approximately 50.174% → 100%; microphone mute and both speaker mutes off → on → off. A 74% microphone request did not match closely enough and was restored. No audio was recorded. Default-device setters are implemented but were not exercised, to preserve routing.

A later inventory identified the active screen as EDID vendor `4199` (PLY), model 1, at 1920×1080/60 Hz. `screen status` and `screen modes` use CoreGraphics, selecting only that identity and refusing ambiguity. Applying the already-current mode succeeded. Other mode changes are not yet physically verified. DisplayLink Manager was observed running in that later inventory; this task did not install it or replace its USB graphics driver.

## P21 vendor setting catalog recovered

The local LegacyHostApp log contains a P21 `DeviceSettingsValues` catalog. The filtered catalog (without device identifiers) is preserved in `evidence/vendor-setting-catalog.json`.

| ID | Vendor name | Advertised values |
|---|---|---|
| `0c82` | statusBrightness | 0–100, step 1 |
| `0c83` | leftVanityBrightness | 0–100, step 1 |
| `0c8f` | rightVanityBrightness | 0–100, step 1 |
| `0c8a` | lightSensor | false / true |
| `0c8b` | independentAmbientLight | false / true; described as independent manual vanity control |
| `0c84`–`0c87`, `0c89` | status LEDs idle/incoming/active/held/charging | false / true |
| `0c90` | relativeDisplayBrightness | up / down |

The user reports side lights switch on when the camera becomes active. This is an observed coupling, not yet proof of which setting controls that behavior.

Static `BRDeviceSettings::InitDevice` checks HID page `ffa2`, usage `be`, which the live descriptor maps to output/input report `de`, total length 62. `writeToHIDInternal` serializes `[report ID, 1-based fragment index, fragment count, up to 59 payload bytes]`, padding the rest with zeros. GET_REPORT for input `de` succeeds on this hardware. The setting payload construction and verified writes are described below. Earlier identification of feature report `9a` as REST was unproven; JSON responses have instead been observed on the camera's feature report `05`.

## BR setting mapping and read/write experiments

The important mapping is in the installed app's `Resources/Plantronics/Hub4G/DeviceSettings.zip`, entry `431a.json`. The global setting IDs in logs are **not** wire IDs. Extracted lighting definitions are in `evidence/lighting-wire-metadata.json`.

BR packet: two-byte big-endian header `(packetType=1 in upper nibble, 12-bit body length)`, four-byte root address `00 00 00 messageType`, then payload. GET message type 2, GET reply 3, setting exception 4, SET command 5, command acknowledgement 6, command exception 7, event 10. Payload starts with a big-endian uint16 wire ID.

| CLI | Wire ID | GET extra bytes | SET extra bytes |
|---|---|---|---|
| lights manual | 0426 | none | bool byte |
| lights sensor | 0427 | none | bool byte |
| lights left | 0e34 | 13 | 13 ff percent |
| lights right | 0e34 | 14 | 14 ff percent |
| lights status | 0e34 | 12 | 12 ff percent |
| relative screen brightness (not yet CLI) | 0429 | none | 01 00 01 up / 01 00 02 down |

Initial readback: manual off, sensor off, left 50%, right 50%, status 100%. Brightness GET replies contain selector, ff, percentage. The initial right GET echoed selector 12 instead of 14; later reads echoed 14 correctly. Queries are fenced by a different bool-setting reply to avoid taking an old GET_REPORT result. The command channel has no transaction IDs; another program's simultaneous requests can interfere. A per-user lock coordinates p21ctl processes only.

**SET acknowledgement must be awaited before sending another request.** Sending GET immediately after SET caused dropped GETs. Waiting for type 6 resolved that failure. Wrong global IDs (c83 etc.) gave setting exception 0012; the error's exact human meaning is not yet mapped.

Direct manual and brightness writes receive acknowledgements and matching subsequent reads. The user saw **no physical change** in repeated left-off/right-100% tests, including a test after manually lighting the lamps. These are stored-setting controls, not yet verified active-lamp controls. The rear touch pad can turn the lamps on with the camera off, without changing the stored settings above or emitting a captured BR event. All our temporary settings were restored (50/50/100, manual off, sensor off). Do not claim physical vanity control is solved.

Relative screen GET 0429 returned exception 0012. The shared SDK LED map names LCD selector 19 and backlight 11, but brightness GET 0e34 with either selector returned no value; no writes were sent to those selectors.

On 2026-09-15 the user visually confirmed bottom-light brightness after a repeated five-second test: `lights status 10` dimmed the bottom light and `lights status 100` restored it. Both device readbacks also matched. This verifies the status selector `12` on wire setting `0e34`; it does not verify the side selectors `13` and `14`.

### Side-light activation finding (2026-09-15)

With manual on, left 0%, and right 100% stored, the user cycled the lamps using the rear touch pad and confirmed **just one side lit**. This establishes a physical effect from the stored side settings. The left/right physical orientation was not separately identified by the user. Next, while the lamps remained on, we set right 0% and left 100% for 12 seconds. The user confirmed the same side stayed lit. Restoring stored left/right 50% and manual off succeeded, but a touch-pad cycle is needed to apply those restored settings physically. Immediate application and software-only side-lamp power remain unverified. Manual-on necessity has not been isolated from touch-pad activation.

### Alternate JSON channel investigation

Static analysis of the installed `PolyStudioDriver.dylib` identifies `RestMessagePackageComposer::GetPackage` at `0xdc1d0`, `JsonMessageRequests::CreateMessageHeader` at `0xd721c`, and `SendRestMessageRequest` at `0xe6ef4`. The header uses string fields `type`, `url`, and `msg_id`. The generic SDK's URL map at `0x19b148` maps LED brightness to `led_brightness`, and at `0x19b334` maps the capability list to `supported_urls`.

The P21 camera (`095d:9298`) interface 3 feature report `05` returned a framed JSON response; feature `06` and `08` reads stalled. Compiled C probes sent only GET requests for the two catalogued paths above. Short and full 512-byte requests, plus an empty-body completion-flag variation, returned `404 Not Found`, `msg_id: "0"`, and `diag_info: "Fail"`. Because the message ID did not match the requests, this does not establish a valid request exchange or prove that either endpoint is unsupported. No JSON setting writes were attempted. This channel is not yet a usable lighting control.

No vendor library was loaded or executed for these probes. The earlier crash-producing Python memory-introspection scripts were disabled; static binary inspection and compiled libusb calls replaced that approach.

Failed UVC, HID-indicator and CoreGraphics writes now attempt restoration and verify it. A real zoom request 15 quantized and failed validation; the CLI restored the original 10 and a fresh read confirmed 10.
