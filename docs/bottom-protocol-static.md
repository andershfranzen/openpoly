# P21 bottom light: static protocol findings

2026-09-15. This lane read files and disassembly only. It did not access USB, invoke vendor code, load a dylib, inspect process memory, install software, or change device settings.

## Current outcome

Later firmware analysis recovered the working `031b` I2C bridge described below. Direct RGB and cycling pass register readback; the user visually confirmed purple. The initial SDK-only findings below are retained as history.

## Initial SDK result

No supported BR packet for arbitrary bottom-light RGB or animation was recovered. The P21-specific evidence supports brightness on `0e34`, selector `12`, and phase-enable flags on `0e33`. The generic SDK's `LEDStatus` animation names belong to a **read-only** `0e20` query, whose SET callback is absent and whose GET was already rejected by this P21. They are not an animation setter.

The three-byte brightness tuple is established as `[LED ID, ff, percentage]`. The meaning of `ff` is **unresolved**: the P21 catalog names it only as a literal `BYTE`. Neither a color-channel meaning nor a segment-mask meaning was established. Do not substitute another value based on the RGB REST strings.

## Static provenance

Addresses are unslid arm64 virtual addresses from the existing `nm -aC` / `otool -tvV` dumps.

| Binary | Full installed path | SHA-256 |
| --- | --- | --- |
| Cable Deckard | `/Applications/Poly Studio.app/Contents/Helpers/LensService.app/Contents/MacOS/clockwork/PolyUsbCableDeckard.dylib` | `a904ee45e06d2e8121d44ceca2737032d8a04a24581568da4d1ee3bef9bfd1b1` |
| Studio driver | `/Applications/Poly Studio.app/Contents/Helpers/LensService.app/Contents/MacOS/clockwork/PolyStudioDriver.dylib` | `64ffd923cf0b47f79916b0eb0f4011ca8da5596bbfea9a1cdb219fc22ba2c1bf` |
| Legacy BR | `/Applications/Poly Studio.app/Contents/Helpers/LegacyHostApp.app/Contents/Components/libPLTDeviceManager.dylib` | `4c8d51455453e108092fe6f05ac9827b91694fc8f1ffb4a104357192bdeb09f1` (recorded in `vendor-analysis.md`) |

Catalog: `/Applications/Poly Studio.app/Contents/Helpers/LegacyHostApp.app/Contents/Resources/Plantronics/Hub4G/DeviceSettings.zip`, member `431a.json`, SHA-256 `23476a736d7fb9d8f97a3ac02d78ac67cc05d9a55f86979232bfc5ecc126c7d9` (recorded earlier). Among archive JSON members, only `431a.json` contains textual wire ID `0e34`. Its three brightness definitions all fix their second payload byte at `0xff`; none exposes a named channel/segment parameter.

## Why LEDStatus is not a SET route

In Cable Deckard:

1. `DeviceProperty::Id::LEDStatusId` at `0x2ec6e8` points to the string `LED Status` at `0x2a09b2`. These on-disk pointer words are Mach-O chained fixup encodings; they must not be interpreted as loaded process pointers.
2. The wire/property map initializer at `0x780f8` stores `0xe20`, then loads `LEDStatusId` at `0x78104`–`0x78110`. This independently confirms the legacy library's wire ID.
3. The corresponding `DeckardDeviceProperty::PropertyDispatcherData` construction at `0xac654`–`0xac684` supplies `0xe20` in the GET-side stack arguments, while the initial unsigned parameters `w1`, `w2` and callback words `x4`–`x7` are zero.
4. `PropertyDispatcherData::PropertyDispatcherData(...)` at `0x9e6a8` stores `x4` and `x5` to object offsets `0x20`, `0x28` (`0x9e710`). It stores the next callback pair at `0x30`, `0x38` (`0x9e714`). Thus the absence is structural, not inferred from symbol names.
5. `DeckardDeviceProperty::SetPropertyNEW(...)` at `0x96d30` calls `FindGlobalPropertyCallback`, loads the callback words at `0x20`, `0x28` (`0x96d70`), tests them (`0x96d74`–`0x96d7c`), and returns host `LibResult` value `5` at `0x96de4` when null. It never reaches a send routine for this entry. The semantic name of host result `5` was not established here; it is distinct from device exception `0012`.

The generic output shape is `LEDs`, a structure array of unsigned byte `ID` and unsigned byte `State`. Anchors: `LEDStatus::LEDs::StructArrayPayloadDetails` at `0x321488`, `LEDStatus::PropertyInfoDetails` at `0x3214d0`, and `LEDStatus::UInt8Properties` at `0x3214e8`. The metadata initializer beginning at `0x24e100` describes `ID` as the SDK's UInt8 type; the following element describes `State` the same way. The parent library's `getLedStatus(vector<uint16_t>&)` at `0x5797c` reads its generic packed/status-array result. This lane did not establish a compatible P21 reply array framing because the query does not succeed on P21.

Exact known GET body, after the three transport bytes:

```text
10 06 00 00 00 02 0e 20
```

Earlier P21 response recorded in `protocol.md`:

```text
10 08 00 00 00 04 0e 20 00 12
```

There is no corresponding legacy `setLedStatus` export in the supplied symbol/disassembly material. The clockwork dispatch evidence above is stronger than the absence of that symbol alone.

## Generic enum values, with exact anchors

The IDs are uint8 names-to-values maps, not device capabilities. The initializer at `0x24e6c0` loads `LedIdCoveStatusLight`; `0x24e6dc` stores value `12`. Nearby initializers store vanity-left `13`, vanity-right `14`, backlight `11`, camera-light `18`, LCD-screen `19`.

| LED | Cable Deckard string-pointer symbol | Value assignment |
| --- | --- | --- |
| Cove status light | `DeviceProperty::LEDStatus::LEDs::ID::LedIdCoveStatusLight`, `0x2ee930` | `0x24e6dc`, `12` |
| Vanity left | `...::LedIdVanityLeftLight`, `0x2ee938` | `0x24e6f8`, `13` |
| Vanity right | `...::LedIdVanityRightLight`, `0x2ee940` | `0x24e710`, `14` |

| State | String-pointer symbol | uint8 value |
| --- | --- | --- |
| Off | `LEDStatus::LEDs::State::LedStateOff`, `0x2ee9b8` | `00` |
| On | `...::LedStateOn`, `0x2ee9c0` | `01` |
| Flash slow | `...::LedStateFlashSlow`, `0x2ee9c8` | `02` |
| Flash fast | `...::LedStateFlashFast`, `0x2ee9d0` | `03` |
| Breathing | `...::LedStateBreathing`, `0x2ee9d8` | `04` |
| Crossing | `...::LedStateCrossing`, `0x2ee9e0` | `05` |

The map is constructed at `0x24e904`–`0x24e9c8`; breathing's value assignment is `0x24e990`, crossing's `0x24e9ac`. The human string for the slow flash has a vendor typo, `Led State Flash Show`; the exported symbol is `LedStateFlashSlow`.

Studio driver duplicates this generic metadata: `LEDStatusId` at `0x3086e8`, Cove ID at `0x30a930`, state pointers at `0x30a9b8`–`0x30a9e0`, structure metadata at `0x33e718`. Cove value initializer at `0x26aa98` mirrors Cable Deckard `0x24e6c0`; breathing initializer at `0x26ad5c` mirrors `0x24e984`. This duplication is SDK reuse, not independent P21 firmware support.

## P21-supported BR layouts

Audio device `047f:431a`, interface 3, report `de`, 62 bytes. Default root address, one fragment:

```text
de 01 01 10 LL 00 00 00 MT <wire ID high> <wire ID low> <data> <zero padding>
```

`LL = 4 + 2 + len(data)`; message types: GET `02`, GET reply `03`, SET `05`, acknowledgement `06`, command exception `07` (GET exception is `04`).

Catalog-grounded bottom brightness examples (packet recipes; no writes in this lane):

```text
GET:          de 01 01 10 07 00 00 00 02 0e 34 12
SET 10%:      de 01 01 10 09 00 00 00 05 0e 34 12 ff 0a
SET 100%:     de 01 01 10 09 00 00 00 05 0e 34 12 ff 64
GET reply:                ... 00 00 00 03 0e 34 12 ff <percent>
```

Every report is padded to 62 bytes. Percentage range is 0–100. Earlier physical brightness verification is documented in `protocol.md`. The matching enum ID `12` establishes that the first tuple byte is the LED/entity selector; it does not resolve `ff`.

`0e33` takes `[uint32_be(value), uint32_be(mask)]` after the wire ID. P21 catalog bits: idle `01`, incoming `02`, active `04`, held `08`, charge `20`; known bits total `2f`. Enabling a phase uses value=mask; disabling uses value=0 with the same mask. This selects which firmware status phases show the light. It supplies no colors, durations, frequency, or animation states.

`evidence/br-startup-metadata.txt` lists command IDs:

```text
0403 0405 0419 041a 0426 0427 0429 0a1d 0a21 0a3a 0e0d 0e33 0e34 0f13
```

`0e20` is absent from command, setting, and event lists in that captured response. The supported lists plus the earlier exception are direct P21 evidence against treating the generic LED-status schema as available. `0e0d` remains unknown; its successful GET value `1` does not establish an LED write or a bottom-light color mode.

## RGB REST evidence and model limits

Cable Deckard contains separate generic webcam REST names `rest_led_brightness`, `rest_led_brightness_red`, `rest_led_brightness_green`, `rest_led_brightness_blue`, `rest_led_brightness_mode` at cstring addresses `0x29960f`, `0x299623`, `0x29963b`, `0x299655`, `0x29966e`. Its human property-label initializer at `0x1ba868`–`0x1ba900` maps labels to host property enum values `12e`–`132`; these are **host enums**, not BR wire IDs. Studio driver has matching REST names initialized at `0x190d48`–`0x190de0`, and exported `WebCameraApi::GetRESTProperty` at `0x916c8` / `SetRESTProperty` at `0x91850`.

These names do not provide a BR payload. Neither clockwork disassembly dump contains an immediate `#0xe34` or `#0xe33`; the P21 resource catalog is still the concrete BR mapping. The generic property availability function `properties::getAllSupportedMainProperties(vid,pid)` at `0x16c900` looks up `properties::devicesMasksToVidPid` (`0x31d980`), then filters entries against a device mask (`0x16c954`–`0x16c968`, `0x16c9d0`–`0x16c9d8`). This establishes that property names alone do not bypass model filtering. This lane did not statically recover an RGB-property mask entry identifying `047f:431a` or `095d:9298`.

Earlier camera REST reads of `led_brightness` and `supported_urls` yielded a non-correlated `404` response with message ID `0`; that is neither support nor definitive non-support. A usable RGB route still requires a validated REST request framing, a correlated capability/brightness reply from P21, and actual endpoint/payload metadata. The existing REST investigation is the bounded lead; guessing new bytes on supported BR `0e34` is not justified by the static evidence.

## Reproduce without running vendor code

Use `nm -aC`, `otool -tvV`, `strings -a -t x`, `shasum -a 256`, and Python `zipfile`/`json` reads on the paths above. Inspect the listed address ranges in `/tmp/PolyUsbCableDeckard.otool` and `/tmp/PolyStudioDriver.otool`. Those tools parse files; no vendor dylib is loaded or executed.

## Follow-up: unknown 0e0d and report 50

### 0e0d remains unidentified

The supplied disassembly dumps contain no immediate `0xe0d` in Cable Deckard, Studio driver, or legacy BR. A static scan of each clockwork binary's 32-bit words also found no arm64 MOVZ immediate `0xe0d`. No archive JSON member contains textual `e0d`. These bounded negative searches do not exclude dynamically supplied metadata, a computed ID, or a different SDK implementation; they do prevent assigning a semantic name from this material.

The generic **named** test-mode properties map to other IDs:

| Generic property | Wire ID | Cable Deckard anchor |
| --- | --- | --- |
| `DeviceProperty::Id::FactoryTestModeId` | `03aa` | wire assignment `0x77824`, label load `0x77838` |
| `DeviceProperty::Id::DUTTestModeId` | `03a9` | wire assignment `0x77844`, label load `0x77858` |
| `DeviceProperty::Id::TouchpadTestModeId` | `03c8` | dispatcher assignment `0xa8610`, label load `0xa8634` |

None identifies `0e0d`, and none is in the captured P21 command list. The `LEDStatus` enum's `LedIdTestMode` is merely LED ID `10`, assigned at `0x24e694`, and is not a factory command. No test-mode writes are warranted by these findings.

### Report 50 is a legacy HID pipe

`evidence/hid-descriptors.json` assigns audio report `50` (hex) to page `ffa2`, usage `30`, with 61 payload bytes plus report ID, input and output. Report `de` uses usage `be` on that page. They are separate descriptor usages.

The legacy binary provides semantic evidence for `ffa2:30`:

- `PLTDeviceManager::BaseDeviceEvents2::InitReportIDs()` at `0x1fa028` discovers usage `30` (`0x1fa0e8`/`0x1fa0ec` and `0x1fa160`/`0x1fa164`).
- The host-command construction path discovers that usage at `0x2097d0`/`0x2097d4`, then calls `HidPipeDataEncode::HidPipeDataEncode(IDeviceSettings*,int,unsigned char)` at `0x209800`.
- `BaseHostCommand2::getSerialNumberThroughHidPipe(...)` at `0x21ae00` checks usage `ffa2:30` (`0x21ae38`/`0x21ae3c`) and also requires feature usage `ffa2:81` (`0x21ae58`/`0x21ae5c`). The captured P21 descriptor does not expose feature usage `81`, so this particular read path fails its capability prerequisites even though report `50` exists.
- `BaseHostCommand2::requestSerialNumber(...)` at `0x22c548` resolves usage `30` at `0x22c59c`; `setSerialNumber(...)` and `setPassword(...)` also use the pipe. This is a general transport, not a dedicated LED test report.

`HidPipeDataEncode::sendmsg(HIDPipeCommand,vector<uint8_t>)` at `0x1f4314` establishes a generic message frame. For a payload of at most report length minus nine (53 bytes on P21), its header is:

```text
50 ff 01 CMD 01 LENlo LENhi LENlo LENhi <payload> <zero padding to 62>
```

Evidence: report ID store `0x1f4360`; little-endian `01ff` store at header offset 1 (`0x1f4364`/`0x1f4368`); command byte offset 3 (`0x1f4378`); constant `01` offset 4 (`0x1f437c`/`0x1f4380`); little-endian length copies at offsets 5 and 7 (`0x1f4384`–`0x1f4390`). It appends body bytes at `0x1f467c`–`0x1f468c`, zero-pads to the configured report length, then sends at `0x1f4884`–`0x1f4898`. Longer messages use first-header chunk length and a continuation header `[report ID, ff, fragment index, 10]` at `0x1f4430`–`0x1f4440`.

Named encoder operations include `SetPresence`, `SetDefaultSoftphone`, `SetSoftphoneName`, `SetLocale`, `SetDateTime`, `SetDateTimeFormat`, `SetMultiCallState`, `SendCallerName`, `SendFriendlyName`, and `SetDfuData`. Incoming decoding at `HidPipeDataDecode::setHidPipeInputReport` (`0x1f73c4`) dispatches call state, caller names, and fragmented display data. No named LED/RGB/animation/test encoder method was found. Call-state messages could affect firmware status presets, but the binary evidence does not establish arbitrary color/animation controls or P21 support for these encoder operations. No pipe packets were sent in this lane.


## Official firmware: LED controller and color route

Static analysis of `/tmp/p21-official-firmware-static/dfu_image.bin`, SHA-256 `bd3e11161f0440d20dba19a8f01cd5a0b58357ea822c494c5f588adeaf1c52e5`, adds evidence that the P21 firmware contains a host-facing **preset color** route beyond the advertised BR brightness settings. The parent core-dispatch analysis identifies **BR SET command `0x0317`**, with exact payload `[indicator, color, brightness]` and brightness `0..100`. Dispatch at `0x64932` compares command literal `0x64bcc=0x0317`; handler `0x65254` validates five total bytes including the two-byte command and emits internal event `0x08e7` at `0x65350`. Event comparison at `0x61168` loads literal `0x61458` and branches to `0x615ae`. This static lane sent no packets.

### Address mapping and reproduction

The `FIRMWARE` container describes `APP_MAIN` at file offset `0x80`, length `0x7e84c`. Its validated load address is `0x50000`, so original-container file offset = VM address minus `0x4ff80`. Reset VM `0x5ced8` maps to file `0xcf58` and begins Thumb `push {r4,r5,r6,lr}; cpsid i`, followed by an MSP write and CRT initialization. The `CLedsKtd2052` vtable at VM `0xb31b8` (file `0x63238`) has 14 of 15 pointers landing on PUSH prologues under this mapping. Address `0x10000` was an initial hypothesis and is rejected.

The analysis uses the parent's `/tmp/p21-main-thumb.elf` wrapper and Apple's LLVM disassembler with `--triple=thumbv6m --mcpu=cortex-m0`. Full static disassembly is `/tmp/p21-bottom-main-disassembly.txt`; the controller slice is `/tmp/p21-bottom-controller.txt`. No firmware code was executed or emulated.

### Named functions and inbound chain

| Address (VM) | Evidence and behavior |
| --- | --- |
| `0x67b98` | Initial `SetStatusAndSidePanelBrightness`: log literal `0xb1f54`; arguments `r1=internal LED ID`, `r2=brightness`. Stores left/right/bottom values at object offsets `0x12`, `0x14`, `0x16`. |
| `0x68724` | Applying form of the same function: same log literal; internal IDs `0`, `1`, `2`; updates brightness and invokes driver methods. Direct setting-update callers `0x61dc4`, `0x61dde`, `0x61df8` load consecutive bytes from global setting storage and supply IDs `0`, `1`, `2`. |
| `0x683d8` | Log `SetSysEvent eEvent: %d, uiIndicator: %d, uiColor: %d` at `0xb2088`. Accepts only event `0x15`; sets current LED state `0x12`, calls `0x67200` with indicator/color/extra, then renders via `0x67f48`. |
| `0x5f41c` | Sole direct caller of `0x683d8`, at `0x5f452`. Takes indicator, color, and an 8-bit third parameter; normalizes nonzero third parameter toward a multiple of ten before passing it as uint16 extra. Always supplies event `0x15`. |
| `0x615ae` | Inbound branch reads payload indices `0`, `1`, `2` through `0x84d38`, truncates each to uint8, then calls `0x5f41c` at `0x615d2`. This is the three-byte handler reached from BR SET `0x0317` through event `0x08e7`. |
| `0x67200` | Stores indicator at object `+0x22`, translated color at `+0x23`, and uint16 extra at `+0x24`. Calls the palette translation helper `0x671c4`. |

The LED IDs in the brightness function are internal zero-based IDs; they must not be directly substituted for BR wire selectors `0x12`, `0x13`, `0x14`. Physical scope of the separate `uiIndicator` enum also needs dispatch/enum evidence.

### The color input is an enumerated palette

`0x671c4` compares input to `8` and dispatches through the nine-entry jump table at `0xb1810`. Unsupported IDs log `un-support color: %d` (`0xb19b8`) and return internal color `0`, which is white, rather than rejecting the host command.

The driver palette at `0xb39a0` is nine triples of little-endian uint32. The shared vtable slot `0x2c` implementation at `0x6a2d0` selects a triple, multiplies each component by brightness divided by `100`, truncates to uint8, and writes LED chip registers `3`, `4`, `5` via `0x69f18` (`0x6a334`–`0x6a34e`). This is concrete RGB-capable hardware code, but the inbound branch selects a palette entry rather than accepting three arbitrary RGB components.

| Host color ID | Internal palette ID | Stored component triple | Color inference |
| --- | --- | --- | --- |
| `0` | `8` | `(0,0,0)` | off / black |
| `1` | `2` | `(7,80,15)` | green |
| `2` | `1` | `(143,0,0)` | red |
| `4` | `3` | `(5,5,112)` | blue |
| `6` | `6` | `(192,138,17)` | amber |
| `8` | `0` | `(192,192,192)` | white |
| `3`, `5`, `7`, or `>8` | `0` with unsupported-color log | `(192,192,192)` | fallback white |

The remaining unselected palette entries are `4=(20,40,35)`, `5=(10,10,10)`, `7=(132,192,192)`. Color names above are inferred from the component triples. They are not recovered enum names.

`0x66f08` renders the saved indicator: indicator `0x12` uses the saved color and low byte of extra as brightness, accepts internal colors `0..3`, `6`, `8`, and calls two driver objects through vtable slot `0x2c` at `0x66f38` and `0x66f4a`. This proves a color-plus-brightness branch for that indicator. Its two target object-pointer globals are `0x2000222c` and `0x200021a8`. Indicators `0x13` and `0x14` each drive three objects and use vtable slot `0x34` for color/brightness; the left/right brightness IDs likewise drive three objects per side. The constructor confirmation below ties `0x12` to the bottom/status hardware; `0x13`/`0x14` correspond to the left/right object groups. Other indicator branches select individual/group outputs or patterns.

### Pattern controller remains internal

Firmware includes `CVanityLedPatternGen` RTTI at `0xb26a0`; `0x68ca4` logs `DBG SetPattern Called - pattern id %d` using literal `0xb26c8`. It stores a pointer to a pattern structure, a state/value argument, an extra argument, and a callback pointer. The pattern processor around `0x68cf8` reads pattern steps and writes control, color0, color1, and isela bytes with error strings at `0xb2708`–`0xb28d0`. This supports built-in firmware animation sequences. No arbitrary user-supplied pattern buffer or RGB setter on an identified host command was established by this bounded lane.

The inbound dispatch branch `0x615ae` is now tied to BR SET `0x0317`, and indicator `0x12` is tied to the bottom/status driver pair. This route is stronger evidence than generic SDK `LEDStatus` or an unsupported BR GET, because it is present inside the official P21 firmware and reaches its LED driver.


### Constructor confirmation and bounded segment/RGB search

Object construction now ties indicator `0x12` to the bottom/status pattern hardware:

- `CLedsKtd2061` constructor `0x69e48` installs vtable `0xb34a0`, stores chip ID at object `+0x0c` and LED output count at `+0x10`.
- Allocation/initialization at `0x6eb14`–`0x6eb2a` passes chip ID `6`, output count `12`, and stores the new object in pointer global `0x2000222c`. The next allocation at `0x6eb2c`–`0x6eb42` passes chip ID `7`, output count `12`, and stores global `0x200021a8`.
- The LED controller constructor at `0x66ea2`–`0x66eac` reads those two globals into `CVanityLedPatternGen` fields `+0x14` and `+0x18`; vtable/RTTI identifies that pattern generator.
- The named bottom brightness field (controller `+0x16`, logged by `Get bottom LED brightness` at `0xb1fd4`) feeds the pattern generator, for example at `0x6837c`–`0x68388`. The preset-color renderer for indicator `0x12` targets the identical two objects.

Thus the color route and bottom/status pattern route share the same two KTD2061 chips. This confirms their physical scope through object identity rather than merely assuming the generic SDK Cove enum applies.

A private arbitrary-component driver method exists: shared vtable slot `0x1c` at `0x69ccc` splits argument `r2` as `0xRRGGBB`, clamps each byte to `0xc0`, then invokes the concrete driver's slot `0x08`. KTD2061 slot `0x08` at `0x6a234` writes components to registers `3`, `4`, `5`; its fourth argument selects one of two internal output/control groups. However, the identified caller at `0x69d92` constructs its components from the fixed palette at `0xb39a0` and brightness. No direct call to `0x69ccc` or `0x6a234` appears in the full disassembly; they are virtual methods. Searches of the two bottom driver globals find controller rendering, pattern initialization, and allocation references, with no additional direct host-handler reference.

This bounded search establishes internal component and output-group capability, but does **not** recover an external per-segment RGB command. The verified BR SET `0x0317` / event `0x08e7` branch offers whole-bottom preset colors through indicator `0x12`. Any claim that a host can pass raw RGB or independently address its internal groups would require another inbound handler reaching the private driver methods.


### Forced color state and restoration

Every `0x0317` color command takes the same `SetSysEvent` branch at `0x683d8`; instruction `0x683fe` writes current controller state `+0x08=0x12`. Neither off/black nor white changes this behavior. The command preserves remembered normal state at `+0x09`, so white is a neutral color rather than a return to automatic status behavior.

Normal status-event processing at `0x68474` accepts events `0..0x14`, chooses a normal state, and calls `SetCurrentSysState` (`0x6842c`) at `0x6860e`. That function writes current `+0x08` and, except transient states `6`, `7`, `0x0f`, `0x10`, `0x11`, remembered `+0x09`. Its event jump table at `0xb1904` includes event `5` (idle state `1`, or `0x0e` when remembered state is `0x0b`), `10` (incoming state `8`/`9`), `11` (incall `0x0a`/`0x0b`), `12` (idle/outcall), and `14` (held `0x0c`/`0x0d`). Thus a real normal HID/status transition that reaches this function exits forced color mode. Whether an unchanged HID report retriggers that transition depends on the upstream handler and was not established here.

Callback `0x68634` explicitly gets remembered `+0x09` through `0x66efc`, then re-applies it via `0x6842c`; this is an internal exact-previous-state restoration path, without an identified external command.

`SetStatusLEDBehavior` at `0x68650` changes the behavior flags and then re-applies **current** `+0x08` through `0x6842c`. If called while current state is forced `0x12`, this also copies `0x12` into remembered `+0x09`. Therefore a phase/behavior update while forced should not be treated as a restoration route; it can replace the remembered normal state. Actual status-event restoration should occur before reapplying behavior flags.


## Factory/test gates and I²C bridge targets

The color command is behind a separate test-interface gate. `CTestInterfaceTask` singleton getter `0x6359c` reads global `0x200020e4`. Getter `0x63e7c` reads object byte `+0x54`; getter `0x63e84` reads byte `+0x55`. Both default to zero at constructor `0x63518`/`0x6351c`. These are RAM flags, separate from captured BR brightness/behavior settings.

The parent allow-list analysis distinguishes them: `+0x54` uses command table `0xb3f08`, which does not allow SET `0x0317`; `+0x55` uses table `0xb3eb0`, which includes it. Gate `0x6b344` permits `0x0300` unconditionally; other commands require nonzero `+0x55` and table membership through `0x6b22c`. Thus `0x0300`, rather than the separate `+0x54` mode, is the relevant gate.

`0x0300` SET handler at `0x64c10` requires three total command bytes (two-byte command plus one-byte boolean). Nonzero payload normalizes to one. It calls `0x646a0` at `0x64c6c`, which sets `+0x55`. Disabling also clears auxiliary byte `+0x56` through `0x64674` and global `0x20002d5a` through `0x6bf5c`. Handler `0x64c70` repeats the `+0x55` store. Enabling reads RAM flag `0x20002d52` via `0x68848`; subsequent control flow can emit task 31 event/notification `0x44`, argument `0x36c8`, at `0x64c90`. The direct handler contains no flash, reset, firmware-write or factory-store call, but the downstream notification's full effects were not established in this lane. Do not equate the simple volatile flag with proof that the entire mode has no other behavior.

An earlier provisional attribution of the `0x656e8` setter to command `0x031b` was wrong and is rejected. Actual `0x031b` dispatch compares literal `0x64bb8` at `0x648e8`, reaches `0x649b4`, and its short three-byte branch at `0x64b78` emits task 6 events `0x0867`/`0x0868`; it does not directly call the `+0x54` setter. The parent's long-payload trace identifies an ASCII I²C bridge: comparison against string `0xb1274` at `0x64a3e`, followed by `0x63778` with payload `+12`. Exact bridge syntax and mode-entry effects are documented by the parent's dispatch lane.

### Bottom bus topology recovered from construction

| Target | Driver object global | Bus wrapper global | Device address | PCA9548 channel |
| --- | --- | --- | --- | --- |
| Bottom KTD2061 chip ID `6`, 12 outputs | `0x2000222c` | `0x20002210` | `0x69` | `2` |
| Bottom KTD2061 chip ID `7`, 12 outputs | `0x200021a8` | `0x20002214` | `0x6a` | `2` |

Bus-wrapper construction `0x6e8e8`–`0x6e920` passes address `0x69`, channel `2`; `0x6e922`–`0x6e95a` passes `0x6a`, channel `2`, into `CMuxPca9548` constructor `0x6a528`. Their pointers feed the KTD2061 constructors at `0x6eb24` and `0x6eb3c`.

Shared PCA9548 base object construction `0x6e70c`–`0x6e76a` sets device address `0x76` at `0x6e724`/`0x6e726`, using underlying bus global `0x200021c4`. Channel selection `0x6a69c` writes `1 << channel` (`0x6a6b0`/`0x6a6b2`), so channel `2` is selector byte `0x04`. The wrapper caches selected channel in global `0x20003a26` and avoids rewriting it when the cache matches. A raw bridge operation that changes the physical mux without updating this cache can leave firmware's cached selection inconsistent with hardware.

These are firmware address values; the bridge's address encoding must be confirmed before using them, including whether its input expects seven-bit addresses or shifted wire addresses.

### Component and output-control register anchors

The bottom color writer uses RGB component registers `0x03`, `0x04`, `0x05`. The output descriptor table at `0xb34d8` contains 12 descriptors of 20 bytes: output IDs `1..12` pair into control registers `0x09..0x0e`, each pair carrying group selector `1` then `0`. The raw component setter at `0x6a234` sets control mask `0x08` for selector zero or `0x80` for nonzero before writing the three components; the whole-bottom palette setter `0x6a2d0` loops all six control registers and writes `0x88`.

Therefore exact, bounded targets for initial static-informed register snapshots are mux address `0x76`, channel selector `0x04`, and bottom chip addresses `0x69`/`0x6a`, component/control range `0x03..0x0e`. Component/control state and the mux selector need preservation when evaluating a raw bridge route. Firmware's pattern engine can update these same registers concurrently. This lane performs no reads or writes to hardware.


## Live-confirmed raw RGB route: long `0x031b` I²C bridge

The parent's bounded hardware test confirms that the **long-form `0x031b` bridge works in normal mode**, without `0x0300`, `0x031b` short-mode entry, factory-state writes, or resets. The gated `0x0317` palette command is therefore unnecessary for raw component control. This worker did not perform hardware operations; the exact request/reply format below is recovered from `/tmp/p21-bottom-rgb-test.c`, and live results were reported by the parent.

### Exact request payload

Send BR SET type `5`, command `0x031b`, with this payload:

| Payload offset | Size | Value |
| --- | --- | --- |
| `0..1` | 2 | `00 00` |
| `2..4` | 3 | ASCII `I2C` (`49 32 43`) |
| `5..12` | 8 | zero |
| `13` | 1 | operation: `03` read, `04` write |
| `14` | 1 | device address: `76`, `69`, or `6a`, as unshifted firmware values |
| `15` | 1 | starting register; `00` for the mux's registerless operation |
| `16` | 1 | register-address length: `00` for mux `76`, `01` for KTD2061 `69`/`6a` |
| `17` | 1 | byte count |
| `18..19` | 2 | zero |
| `20..` | byte count on write | bytes to write; absent for read |

Read payload length is exactly `20`; write payload length is `20 + count`. The scratch implementation bounds count to `1..24` and the entire request payload to the BR capacity of `51` bytes. Example: three-byte read at chip `69`, register `03`:

```text
00 00 49 32 43 00 00 00 00 00 00 00 00 03 69 03 01 03 00 00
```

Example: three-byte write of blue `(0,0,60)` to the same chip/register:

```text
00 00 49 32 43 00 00 00 00 00 00 00 00 04 69 03 01 03 00 00 00 00 3c
```

### Reply validation

All replies must match BR command `0x031b` before interpreting their payload. The live scratch accepts:

- Read: BR type `10`, payload length exactly `count + 4`, prefix `00 01 49 32`, followed by the returned bytes. The prefix is four bytes, including ASCII `I2`; it does not include `C`.
- Write: BR type `6`, exactly five bytes `00 01 49 32 01`.
- An alternate write reply: BR type `10`, length equal to the original request payload, exact byte-for-byte echo of that request.
- BR error/type `7`: reject the operation rather than treating it as a timeout or success.

The descriptor/report transport remains the established audio `047f:431a` interface `3`, report `de`, 62 bytes including report ID. The scratch drains/queries before sending, uses the existing BR sender/parser, and reads report `de` through control GET_REPORT. It does not use the generic report `50` pipe.

### Verified register results and restoration

The parent checked mux address `76` with a registerless one-byte read and required selector `04`; it did **not** change the mux. It read 15-byte snapshots from each bottom chip, required ID register `00=a4`, and observed register `02=82`, component registers `03..05=1e 1e 1e` and controls `09..0e=88`.

It then wrote blue `(0,0,60)` and magenta `(60,0,60)` to register range `03..05` on **both** chip addresses `69` and `6a`, read each range back, and verified exact byte equality. Finally, it restored each chip's original three component bytes and verified both restorations through readback. This establishes arbitrary component transport beyond the preset palette, with existing output selection left intact. Visual confirmation of the user's observed light colors remains pending as of this update; register readback alone does not establish perceived color calibration.

The scratch acquires the shared BR lock, checks the mux before each component operation, and uses SIGINT/SIGTERM to end the timed color display and proceed to restoration. The known snapshots, ID checks, mux check, readbacks, and restoration are necessary concrete guards for this demonstrated route. Firmware animations can still overwrite these registers; the experiment establishes a raw I²C route, not exclusive ownership of the LED controller.

## Reproducible offline extraction tool

`script/firmware-inspect.rb` parses the local firmware container and builds an ARM ELF wrapper solely for static disassembly. It does not download, flash, load, execute, or emulate vendor code. By default it requires the exact documented official-image SHA-256; `--expected-sha256` explicitly supplies a different known hash. The fixed load base `0x50000` is specific to the validated P21 APP_MAIN mapping and must not be inferred for another firmware merely because its header parses.

Usage (with a fresh output directory):

```sh
ruby script/firmware-inspect.rb --self-test --output-dir /tmp/p21-bottom-repro dfu_image.bin
xcrun llvm-objdump -d --triple=thumbv6m --mcpu=cortex-m0 --start-address=0x5ced8 --stop-address=0x5cee4 /tmp/p21-bottom-repro/APP_MAIN.thumb.elf
```

Without `--output-dir`, it prints inspection results and hashes without writing artifacts. It validates container/section signatures, section bounds/non-overlap, SRAM stack address, and Thumb reset-vector range. The self-test additionally checks the official APP_MAIN hash, reset prologue mapping, named LED string anchor, and exact ELF wrapper hash. Existing output files are rejected.

Verified against the local official image:

| Artifact | SHA-256 |
| --- | --- |
| Container `dfu_image.bin` | `bd3e11161f0440d20dba19a8f01cd5a0b58357ea822c494c5f588adeaf1c52e5` |
| Extracted APP_MAIN, offset `0x80`, length `0x7e84c` | `89d66525c9bf51c96ba949f31e98a39dc26c60710a2299b09c3608ea8177f689` |
| ELF wrapper, load `0x50000`, entry `0x5ced9` | `e3cb113a4c575107a29411088b00ecfc1f9a6b538160f20829bbf42f0a4e4219` |

Validation passed: Ruby syntax, official-image self-test, LLVM reset disassembly, and rejection of bad hash, changed signature, oversized section, and output overwrite. The generated ELF is byte-identical to the original static wrapper.
