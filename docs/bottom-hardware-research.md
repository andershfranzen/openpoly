# P21 bottom light bar: hardware and firmware evidence

Research date: 2026-09-15. Read-only research and static document/package inspection. No USB calls, vendor-app execution, native-library loading, firmware flashing, or external changes were performed in this lane.

## Result

**Later breakthrough:** static tracing and live tests recovered a working normal-mode USB-to-I2C bridge. Arbitrary component writes and restoration are now verified on both bottom chips; see [the decoded bridge and measurements](bottom-protocol-static.md). The sections below record the earlier research evidence, before that live validation.

The bottom bar supports multiple colors and spatial animation in stock firmware. An unauthenticated query using the old app's firmware-catalog request obtained the **official P21 firmware package**, including audio ARM/DSP firmware. Static inspection found KTD2052/KTD2061 LED drivers, an LED controller, and an LED pattern generator inside that image. Public evidence still does **not** establish an arbitrary RGB or per-segment host command. The published FCC photos identify a separate LED-board connection, but do not supply a readable LED/driver part number or wiring schematic.

The parent's measured status commands remain the only validated host route: audio USB `047f:431a`, interface 3, brightness BR `0x0e34` selector `0x12`, and HID mute/call/ring/hold states. These select firmware behavior; they do not establish RGB values.

## Primary product documentation

The [HP-hosted Poly Studio P21 User Guide](https://kaas.hpcloud.hp.com/pdf-public/pdf_8708481_en-US-1.pdf), LED Status Indicators section, documents white idle, blue charging expansion from the middle, amber firmware-update pulse, green incoming/active calls, red held/muted states, and sea-foam volume feedback. The guide proves stock multicolor and spatial patterns. It does not name RGB LED hardware, quantify independently driven segments, or document an arbitrary-color control.

**Inference:** an animation expanding from the middle requires spatial control of the light output somewhere inside the product. It does not prove that the host can address individual LEDs or that all 24-bit RGB colors are available.

The [P21 Release Notes, May 2022](https://kaas.hpcloud.hp.com/pdf-public/pdf_14780118_en-US-1.pdf) list release family `1.1165.71` and earlier `1.1162.68`/`1.1161.67`. Their color-temperature feature is described as warm/cool image configuration through Lens; it is not an RGB bottom-bar feature. The document does not publish firmware file URLs or LED wire commands.

## Polycom's FCC hardware exhibits

FCC ID: `M72-PS21`, Polycom Inc., personal meeting display, application May 2021.

The primary retrieval URL for Polycom's submitted internal-photo exhibit is [FCC attachment 5250796](https://apps.fcc.gov/eas/GetApplicationAttachment.html?id=5250796). The FCC endpoint returned HTML rather than the PDF in this session. The same submitted exhibit was obtained from this [PDF mirror](https://fccid.io/M72-PS21/Internal-Photos/Internal-Photos-5250796.pdf), with [exhibit metadata](https://fccid.io/M72-PS21/Internal-Photos/Internal-Photos-5250796).

The PDF is titled `CONSTRUCTION PHOTOS OF EUT`, reference `BHBR-WTW-P21030508_INT`, 16 pages. Downloaded size: 2,237,237 bytes. SHA-256: `cddd872e50bd4e4c1da679c46590573ad9e15f284167c00820bfacdf403ca9be`, matching the mirror's stated hash. All 16 pages were rendered and inspected.

Relevant visual observations, not schematic interpretation:

- Page 2, lower mainboard close-up: connector silkscreen `BOT-LED` is visible.
- Pages 5-6 show two long white boards with yellow phosphor LED packages.
- Page 7, lower photo: a longer white board has repeated pale LED packages and a connector near its center.
- Pages 10-11 show long black boards whose reverse sides contain large electrode traces.

**Inference:** the yellow-phosphor boards are consistent with the side vanity lights; page 7's board is consistent with the bottom status strip. The photos alone do not positively map each board to a physical location. No bottom LED/driver part number, RGB pin assignment, exact segment count, I2C address, PWM map, or addressable-LED protocol can be read reliably from the exhibit. Upsampling the PDF does not create missing component detail.

The primary confidentiality exhibit is [FCC attachment 5250802](https://apps.fcc.gov/eas/GetApplicationAttachment.html?id=5250802), also obtained from its [PDF mirror](https://fccid.io/M72-PS21/Letter/LT-Confidentiality-5250802.pdf). Polycom's May 4, 2021 letter requests permanent confidentiality for schematics, block diagram, and operational description. The [filing index](https://fccid.io/M72-PS21) accordingly lists those exhibits as metadata only. This is a specific reason the FCC route supplies photos but no public wiring/control description.

## Open-source offer and firmware acquisition

The [HP-hosted P21 open-source offer](https://kaas.hpcloud.hp.com/pdf-public/pdf_9121719_en-US-1.pdf), dated June 2021 for `1.1161.67.2044`, lists cJSON (MIT), IQS269A Driver `V2.3.0` (BSD), and uC/OS-II (Apache 2.0). It directs source requests to `Open.Source@poly.com` and states an offer lasting at least three years after distribution of the applicable product/software. This does not promise proprietary P21 LED code or a schematic. The touch-controller driver is not evidence for an LED-control protocol. No request was sent.

Poly publishes an exact offline-software workflow in its [December 1, 2023 announcement](https://info.lens.poly.com/blog/page/8): an account administrator can use Lens **Manage > Software Versions**, select a device/version, and download for local use. Only currently supported software appears there; the announcement directs missing models to HP Customer Support. [Current desktop compatibility documentation](https://info.lens.poly.com/docs/lensapps/Studio%20Desktop/desktop-supported-dev) states that P21 support was removed from Lens Desktop 2.0 and Studio Desktop 5.0, so current desktop support must not be assumed.

The [official ports-and-protocols page](https://info.lens.poly.com/docs/begin/ports-and-protocols) identifies `swupdate.lens.poly.com` as the device-software HTTPS host. It gives a host, not a P21 package path.

Read-only byte searches of the already-mounted vendor Lens 1.4.0 `app.asar` found a separate firmware query, `lensDesktopFirmwareUpdateCheck`, also using `availableProductSoftwareByPid`. The old renderer supplies `pid.toString(16)`. Its production endpoint is `https://api.silica-prod01.io.lens.poly.com/graphql`. On 2026-09-15 at 14:49:59 UTC, one model-only request with no credentials, cookies, or authentication returned HTTP 200 and the package URL below. No account, policy, tenant, or private-device query was made.

```graphql
query lensDesktopFirmwareUpdateCheck($pid: ID!) {
  availableProductSoftwareByPid(pid: $pid) {
    productBuild {
      archiveUrl
      rules { document }
    }
  }
}
```

Variables: `{"pid":"431a"}`. Saved request/response: `/tmp/p21-firmware-public-query.json`, `/tmp/p21-firmware-public-response.json`.

**[Official Studio P21 1.1165.71.2094 DFU package](https://swupdate.lens.poly.com/431a/1.1165.71.2094/0/StudioP21_PID431A_V1.1165.71.2094_DFU_PACKAGE.zip)**

The download returned HTTP 200, length 1,442,694 bytes, Last-Modified `Thu, 19 May 2022 13:52:50 GMT`, ETag `"0x8DA399EDCED9A5F"`. SHA-256 of the downloaded ZIP: `a1065d73aee8970c130b733cbc7c2595412caf0502c61abcceff5211a7faf3db`. This is a locally computed hash, not a vendor-signed integrity statement. `unzip -t` passed for all five members.

Local ZIP: `/tmp/StudioP21_PID431A_V1.1165.71.2094_DFU_PACKAGE.zip`. Static extraction: `/tmp/p21-official-firmware-static/`.

| Manifest member | Bytes | Target/type | Manifest description |
| --- | ---: | --- | --- |
| `dfu_image.bin` | 612,120 | `431A`, USB, version `2094` | USB FW including ARM and DSP |
| `dfu_btlr.bin` | 224,916 | `431A`, bootloader, version `0003` | ARM bootloader dual images |
| `tf.bin` | 1,408 | `431A`, tuningpackage, version `0028` | DSP Tuning File Package |
| `Camera_Image_P21.dfu` | 602,146 | `9298`, camera, version `0197` | Camera FW Update |
| `rules.json` | 1,580 | package manifest | set ID `1.1165.71.2094` |

The mounted old app's `Resources/dfu.config` independently maps PID `431A` (`HotShot-Manatee`) to `TIDFU` for USB/base/language and `USBDFU` for camera. Its separate PID `9298`, VID `095D` webcam entry uses `USBDFU`. The SDK's TI handler name is not itself a physical chip identification.

The [fwupd project's DFU quirks](https://github.com/fwupd/fwupd/blob/main/plugins/dfu/dfu.quirk) name P21 IDs `095d:9298` and `095d:9299`, with `manifest-poll`, `allow-zero-polltimeout`, `unsigned-payload`, and a 9000 ms removal delay. This is source evidence for fwupd's update handling of that USB function. `unsigned-payload` is not proof that every internal P21 processor accepts modified firmware, and those camera-vendor IDs do not establish an update route for the audio/HID LED controller `047f:431a`.

## LED implementation inside the official firmware

`dfu_image.bin` SHA-256: `bd3e11161f0440d20dba19a8f01cd5a0b58357ea822c494c5f588adeaf1c52e5`. Its header begins `FIRMWARE` and contains `APP_MAIN`; plaintext diagnostics/source paths show the `zeus-hotshot-dev-mainline-DA14195` build. [Renesas's DA14195 product documentation](https://www.renesas.com/en/products/da14195) identifies that audio processor as Cortex-M0 plus HiFi-3 DSP with USB and I2C interfaces. The build name is strong firmware-target evidence, rather than an independently read silicon marking.

Selected absolute file offsets, obtained without running the image:

| Offset | String/evidence |
| --- | --- |
| `0x61a38` | `un-support color: %d` |
| `0x61a50` | source path ending `handlers/src/c_led_controller.cpp` |
| `0x61fd4` | `SetStatusAndSidePanelBrightness led_id: %d, brightness: %d` |
| `0x62108` | `SetSysEvent eEvent: %d, uiIndicator: %d, uiColor: %d` |
| `0x62720` | RTTI name `20CVanityLedPatternGen` |
| `0x627f0` / `0x62850` | pattern writer errors for `color0` / `color1` bytes |
| `0x63220` / `0x632c0` | `12CLedsKtd2052` / source path ending `drivers/src/c_leds_ktd2052.cpp` |
| `0x63508` / `0x63848` | `12CLedsKtd2061` / source path ending `drivers/src/c_leds_ktd2061.cpp` |
| `0x63940` through `0x63a10` | names `RGB10` through `RGB36` |
| `0x63aac` | source path ending `drivers/src/c_mux_pca9548.cpp` |

The LED-controller diagnostic strings also name stock power/idle/sleep/update/volume/call/mute/charging states. These match the user-guide behavior. Driver names establish that this firmware contains Kinetic RGB-driver implementations; they do not yet prove which driver controls which physical strip or how many chips are populated.

[Kinetic's KTD2061 product page](https://www.kinet-ic.com/ktd2061/) describes up to 12 RGB modules per chip, I2C color-palette and per-module color/on-off selection, and independent fade engines. The [full KTD2061/58/59/60 datasheet, revision 04e](https://www.kinet-ic.com/uploads/web/KTD2058,%20KTD2059,%20KTD2060,%20KTD2061/KTD2061-58-59-60-04e.pdf) publishes the internal register set, with color-setting and selection registers. [Kinetic's KTD2052 datasheet](https://www.kinet-ic.com/uploads/web/KTD2052/KTD2052-04b.pdf) describes the related four-RGB driver and pattern generator. Those are **internal chip protocols**, not a P21 USB-to-I2C bridge. No USB command should be invented from their addresses or registers.

**Inference:** KTD2061 is the stronger candidate for a long multicolor status strip, while KTD2052 is a candidate for button indicators. This remains a hypothesis until firmware references, constructors, and callers positively map their instances to bottom/button outputs.

## Bounded next step

Continue **static** analysis of `dfu_image.bin`: resolve the ARM section's load address, find references to the KTD2061 and LED-controller strings/RTTI, then follow the LED controller into the Deckard/HID command dispatch. Determine whether a host command accepts color/pattern/register values or only the already measured state/brightness operations. Also recover the existing RGB lookup table and physical chip/segment mapping. The official package has now resolved the missing-artifact step and located the correct implementation image.

If static analysis finds no host-accessible RGB/pattern operation, the bounded result is that stock state colors and patterns are documented and measured, with arbitrary RGB still requiring a new route. Hardware probing or custom firmware would be a separate task requiring the exact controller/LED mapping and a recovery path.

Search scope: official HP/Poly documentation and download pages; exact `Studio P21` + firmware/ZIP/swupdate/RGB/API/schematic/open-source terms; Polycom's FCC filing; fwupd source; mounted Lens 1.4.0 archive byte searches. This is not a claim that no private or undocumented RGB command exists.
