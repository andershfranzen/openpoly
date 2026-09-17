# Poly Studio P21 vendor analysis

This note records read-only static analysis of the installed Poly Studio 5.1.0.1803 helper stack and the P21 settings catalog. It describes the reusable BladeRunner/Deckard (BR) packet format and the P21 lighting/display setting mappings. No vendor binary was modified and no setting write was issued by this analysis lane.

## Provenance

Application and binary paths:

- Application: /Applications/Poly Studio.app (bundle id com.poly.lens.client.app, version 5.1.0.1803).
- BR implementation: /Applications/Poly Studio.app/Contents/Helpers/LegacyHostApp.app/Contents/Components/libPLTDeviceManager.dylib.
- P21 catalog archive: /Applications/Poly Studio.app/Contents/Helpers/LegacyHostApp.app/Contents/Resources/Plantronics/Hub4G/DeviceSettings.zip.
- Catalog member: 431a.json. Reproduce the extracted catalog with:
  unzip -p '/Applications/Poly Studio.app/Contents/Helpers/LegacyHostApp.app/Contents/Resources/Plantronics/Hub4G/DeviceSettings.zip' 431a.json
- Catalog SHA-256: 23476a736d7fb9d8f97a3ac02d78ac67cc05d9a55f86979232bfc5ecc126c7d9.
- BR library SHA-256: 4c8d51455453e108092fe6f05ac9827b91694fc8f1ffb4a104357192bdeb09f1.

The static addresses below are virtual addresses in the arm64 dylib, as reported by nm -aC and otool -tvV. They are provenance anchors for later re-checks, not a supported ABI.

## BR packet serialization

BRPacket::BRPacket() at 0x152a8c initializes packet type 1 and a BRType1Address containing four zero bytes. BRPacket::serialize(br_deque&) at 0x152ec8 does the following:

1. Compute total length as address length plus payload length. The two-byte header itself is excluded.
2. Append ((packetType & 0xf) << 4) | ((totalLength >> 8) & 0xf), then totalLength & 0xff.
3. Serialize the address. The default BRType1Address length is four bytes (BRType1Address::getLength at 0x150188).
4. Replace the last address byte with lastAddressByte + (messageType & 0xf). With the default all-zero address this is 00 00 00 messageType.
5. Append payload elements in insertion order.

Therefore the common default body is:

    [10 LL] [00 00 00 MT] [payload bytes...]

where LL is 4 plus the payload byte count and MT is the low nibble of the message type. The parent agent's read-only report-DE response de 01 01 10 07 00 00 00 0a 0e 01 01 parses exactly as transport chunk de 01 01 followed by BR body 10 07, address 00 00 00 0a, and payload 0e 01 01.

DeckardPayload::serialize at 0x15036c invokes each element serializer consecutively. Primitive element evidence:

- BRElement<bool>::serialize at 0x14c700 emits one byte; getLength at 0x14c808 returns 1.
- BRElement<uint16_t>::serialize at 0x14cccc emits high byte then low byte; deserialize at 0x14cdc4 reconstructs the same big-endian order.
- BRElement<uint32_t>::serialize at 0x14d2ac emits four bytes most significant first.
- pBRBool is exposed at 0x153e9c and pBRUInt16 at 0x153b8c. Other pBRUInt8/pBRUInt32 constructors are used by the same wrappers.

Host setting wrappers establish message types and element order:

- getAudioSensing(bool&) at 0x3cedc sets message type 2 and adds a uint16 setting id as payload element 0. The response value is read from payload element 1.
- setAudioSensing(bool) at 0x3d264 sets message type 5 and adds uint16 setting id, then the typed value.
- BRPacket::deserialize's jump table maps message type 3 to SettingSuccessPayload, type 4 to ExceptionPayload, type 6 to CommandSuccessPayload, and type 7 to ExceptionPayload. The corresponding constructor call sites are 0x153530 (setting success), 0x1534d0 (exception), 0x1534b0 (command success), and 0x153550 (exception); ExceptionPayload::deserialize is at 0x152664.
- BRHostVersionNegotiation at 0x226c0 sends message type 1 with three uint8 payload values 01 02 00; it expects a type 8 response. This is a separate initialization path; the parent agent's direct P21 setting GET/SET probes succeeded without first issuing version negotiation.

The report-DE transport is the HID usage page 0xffa2, usage 0xbe path selected by BRDeviceSettings::InitDevice at 0x22320. The report length is 62. BRDeviceSettings::writeToHIDInternal (0x3903c) uses three leading bytes per report (report id, one-based chunk index, total chunk count), then reportLen - 3 payload bytes, zero padded. A BR body shorter than 59 bytes is one report:

    de 01 01 <BR body> 00 ... 00    (62 bytes total)

The transport wrapper is separate from the BR body; do not include de 01 01 when calculating LL.

## P21 setting catalog

The catalog deliberately distinguishes globalSettingID (host-facing id) from deckardId (wire id). For this P21, the wire packet must use deckardId. This distinction explains the read-only wrong-id probe: requesting 0xc83 directly returned an ExceptionPayload (message type 4) with payload 0c 83 00 12. 0xc83 is the global id; the actual ranged Deckard id is 0x0e34.

### Vanity and status brightness

All three scalar brightness settings have range 0..100, step 1, and messaging rangedDeckard. They share wire id 0x0e34 and use a one-byte selector:

| global setting | name | wire id | GET selector | SET payload after wire id |
| --- | --- | --- | --- | --- |
| 0xc83 | leftVanityBrightness | 0x0e34 | 0x13 | 0x13, 0xff, percent |
| 0xc8f | rightVanityBrightness | 0x0e34 | 0x14 | 0x14, 0xff, percent |
| 0xc82 | statusBrightness | 0x0e34 | 0x12 | 0x12, 0xff, percent |

The catalog's GET request payload is uint16_be(wire id), selector. The GET response payload is selector, 0xff, current percent. The SET request payload is uint16_be(wire id), selector, 0xff, percent. Example BR bodies (percent 50 shown only as a serialization example):

    GET left:   10 07 00 00 00 02 0e 34 13
    GET right:  10 07 00 00 00 02 0e 34 14
    GET status: 10 07 00 00 00 02 0e 34 12
    SET left:   10 09 00 00 00 05 0e 34 13 ff 32
    SET right:  10 09 00 00 00 05 0e 34 14 ff 32
    SET status: 10 09 00 00 00 05 0e 34 12 ff 32

The SET examples are packet recipes recovered from the catalog, not writes performed here.

### Ambient light controls

| global setting | name | wire id | value type |
| --- | --- | --- | --- |
| 0xc8b | independentAmbientLight | 0x0426 | BOOLEAN |
| 0xc8a | lightSensor | 0x0427 | BOOLEAN |

GET payloads are uint16_be(wire id); SET adds one boolean byte. Examples:

    GET independent ambient: 10 06 00 00 00 02 04 26
    SET independent ambient true: 10 07 00 00 00 05 04 26 01
    GET sensor: 10 06 00 00 00 02 04 27
    SET sensor true: 10 07 00 00 00 05 04 27 01

### Status LED state masks

The status state toggles c84 through c89 use common wire id 0x0e33 (global IDs are 0xc84, 0xc85, 0xc86, 0xc87, and 0xc89). The catalog gives masks and unsigned-int values:

| global setting | name | mask/value |
| --- | --- | --- |
| 0xc84 | statusLEDidle | 0x00000001 |
| 0xc85 | statusLEDincoming | 0x00000002 |
| 0xc86 | statusLEDactive | 0x00000004 |
| 0xc87 | statusLEDheld | 0x00000008 |
| 0xc89 | statusLEDcharge | 0x00000020 |

GET uses uint16_be(0x0e33). SET carries the catalog's two uint32 elements: for each bit, false is [0, mask] and true is [mask, mask], all big-endian. This is a mask/value form rather than a single boolean byte.

### Legacy LED-status query (not a vanity-light setter)

`nm -aC` exports `PLTDeviceManager::BRDeviceSettings::getLedStatus(std::vector<uint16_t>&)` at `0x5797c`. Its disassembly creates a BR packet with message type 2, adds one `pBRUInt16` containing `0x0e20`, and sends it through `BRDeviceSettings::Request`. On success it reads payload element 1 with `BRConvert::getSArrayValue` into the caller's `vector<uint16_t>`. With the default four-byte BRType1 address, the exact read-only body is:

    10 06 00 00 00 02 0e 20

The legacy library has no corresponding `setLedStatus` export; the nearby `setFindHeadsetLEDAlert(bool)` is a different headset feature. A parent-agent read-only probe of this `0x0e20` request on the P21 returned an ExceptionPayload with status `0x0012` (`10 08 00 00 00 04 0e 20 00 12`), so this generic status-list query is not a usable P21 master vanity-light power command. The catalog's independent-ambient boolean and the ranged brightness selectors remain stored settings; their successful readback does not establish an active lamp-power path.

### Other P21 controls in the same catalog

- hotshotRocket (global 0xc8e) uses wire id 0x041a and one BYTE mode: holdResume 0x05, playPause 0x00, statusLight 0x07, lens 0x0a, vanity 0x08, answerEnd 0x06, videoMute 0x09.
- relativeDisplayBrightness (global 0xc90) uses wire id 0x0429. GET has only the uint16 wire id; the catalog describes response values as unsigned int 0 (up) and 32 (down). SET has BYTE 0x01 followed by UNSIGNED_SHORT 0x0001 (up) or 0x0002 (down). Bodies:

      GET up/down: 10 06 00 00 00 02 04 29
      SET up:      10 09 00 00 00 05 04 29 01 00 01
      SET down:    10 09 00 00 00 05 04 29 01 00 02

- restoreDefaults (global 0x90a) is a separate catalog command (wire id 0x0f13) and is outside this lighting analysis.

## Clockwork LED symbols and limits

Both native clockwork drivers contain P21-relevant names:

- /Applications/Poly Studio.app/Contents/Helpers/LensService.app/Contents/MacOS/clockwork/PolyUsbCableDeckard.dylib
- /Applications/Poly Studio.app/Contents/Helpers/LensService.app/Contents/MacOS/clockwork/PolyStudioDriver.dylib

Each contains Status Light Enable/Disable, Vanity Light Enable/Disable, Led Id Cove Status Light, Led Id Vanity Left Light, Led Id Vanity Right Light, Led Id Backlight, Led Id Camera Light, Led Id Lcd Screen, and state names Off, On, Flash Show, and Flash Fast. Useful symbols in PolyUsbCableDeckard.dylib include:

- DeviceProperty::Id::LEDStatusId at 0x2ec6e8 (LED Status)
- RestOverHid::LedBrightnessId at 0x2ecd88 (LED Brightness)
- RestOverHid::OnScreenDisplayEnableId at 0x2ecdb8 (On Screen Display)
- RocketButton::Mode::StatusLight / VanityLight at 0x2ed880 / 0x2ed888
- CustomSliderSelection::Mode::StatusLight / VanityLight at 0x2ee4e8 / 0x2ee4f0
- DeckardDeviceProperty::SetPropertyNEW at 0x96d30, SetDeckardE at 0x9929c, and SetDeckardProperty at 0x9aef0

SetPropertyNEW dispatches a callback by property name. SetDeckardE constructs a DeckardProtocolMessage with runtime message type and uint16 id, adds a uint16 BRElement, then sends it. The clockwork binaries do not contain the P21 catalog's concrete 0x0e34/0x0426/0x0427/0x0429 values; the resource catalog is the authoritative mapping for these settings. The old SetProperty entry point at 0x96ca8 logs that it is obsolete.

HPWebcamDriver.dylib also exposes labels such as rest_led_brightness, rest_led_brightness_red/green/blue/mode, and rest_osd, plus LED entity names. Static strings alone do not establish a P21 wire packet for those REST properties; the generic BR catalog path above does.

## Unknowns and safe next step

- The catalog establishes BR body bytes. The report-DE transport owner must still select the device's root address and correlate responses; version negotiation is available in the library but was not required by the parent's direct setting probes.
- The catalog identifies relative display brightness and the LCD-screen LED entity name, but it does not expose an absolute screen brightness scalar. The exact absolute display-backlight property, if supported by this P21 firmware, remains unknown.
- A type-4 response is an ExceptionPayload. The observed 0x0012 code is recorded as an error/status value; its semantic name was not found in the static catalog.
- No arbitrary writes, vendor process invocations, installers, or firmware operations were used in this lane.

### Reproducible static commands

    nm -aC '/Applications/Poly Studio.app/Contents/Helpers/LegacyHostApp.app/Contents/Components/libPLTDeviceManager.dylib' > /tmp/libPLTDeviceManager.nm
    otool -tvV '/Applications/Poly Studio.app/Contents/Helpers/LegacyHostApp.app/Contents/Components/libPLTDeviceManager.dylib' > /tmp/libPLTDeviceManager.otool
    strings -a -t x '/Applications/Poly Studio.app/Contents/Helpers/LegacyHostApp.app/Contents/Components/libPLTDeviceManager.dylib' > /tmp/libPLTDeviceManager.strings
    unzip -p '/Applications/Poly Studio.app/Contents/Helpers/LegacyHostApp.app/Contents/Resources/Plantronics/Hub4G/DeviceSettings.zip' 431a.json

These commands read the installed files only; they do not execute the vendor helper.
