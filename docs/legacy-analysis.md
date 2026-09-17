# Poly Lens Desktop 1.4.0: P21 legacy metadata

This is a read-only static analysis of the official Poly Lens Desktop 1.4.0
macOS package. It is scoped to P21 vanity/status LEDs and display settings. The
DMG was mounted read-only; the app was not installed or launched, and no USB or
device setting write was issued.

## Artifact and verification

- Vendor download: [Poly Lens Mac - 1.4.0.zip](https://swupdate.lens.poly.com/ZippedModelFirmware/Lens_Desktop/Poly%20Lens%20Mac%20-%201.4.0.zip)
- Working directory: `/tmp/p21-legacy-research.Oiw4Y2`
- ZIP size: `179,668,400` bytes
- ZIP SHA-256: `c6a784f773546beccc0ecee78e3d1ad24b1d4748420c3d2791245739454abb7d`
- `unzip -t` passed. The ZIP contains `PolyLens-1.4.0.dmg` only.
- DMG extraction path: `/tmp/p21-legacy-research.Oiw4Y2/extracted/PolyLens-1.4.0.dmg`
- `hdiutil imageinfo` identifies a checksummed, compressed read-only UDZO image.
- Mounted app: `/Volumes/Poly Lens 1.4.0/Poly Lens.app`
- Bundle metadata: `com.poly.lens.client.app`, version `1.4.0`, build
  `1.4.0.20240516.11`.

The embedded catalog was copied to
`/tmp/p21-legacy-research.Oiw4Y2/device-settings/DeviceSettings.zip` and
extracted read-only. Its SHA-256 is
`d71392e1c122f5384d756558ca024151520d9fb54e7688f4534c2a69d26fe99c`; the
extracted P21 member `431a.json` has SHA-256
`dc87128492b6a6e13d70143d0b993552ab3f2fe26bf83d38af3c6c2d39064bd0`.

## P21 catalog mapping (`431a.json`)

`431a.json` has PID `0x431a` and 18 settings. The catalog distinguishes the
app-facing `globalSettingID` from the command-side `deckardId`. `messaging` is
also significant: `deckard` and `rangedDeckard` are different generic SDK
handlers.

### Vanity and status brightness

All three settings are `rangedDeckard`, with range `0..100` and step `1`. They
share Deckard ID `0x0e34`; the first payload byte selects the LED and the second
is `0xff`:

| catalog ID | setting name | selector | documented get-response/set value |
| --- | --- | --- | --- |
| `0xc83` | `leftVanityBrightness` | `0x13` | `BYTE 0x13`, `BYTE 0xff`, `BYTE currentValue` |
| `0xc8f` | `rightVanityBrightness` | `0x14` | `BYTE 0x14`, `BYTE 0xff`, `BYTE currentValue` |
| `0xc82` | `statusBrightness` | `0x12` | `BYTE 0x12`, `BYTE 0xff`, `BYTE currentValue` |

For GET, the catalog lists the selector as the possible-value payload. For
SET, it lists selector, `0xff`, and the percent byte. These are documented
metadata payload elements, not a claim about the outer BR/HID framing.

### Ambient and status-state controls

| catalog ID | setting name | messaging / Deckard ID | documented value |
| --- | --- | --- | --- |
| `0xc8b` | `independentAmbientLight` | `deckard` / `0x0426` | `BOOLEAN false` or `BOOLEAN true` |
| `0xc8a` | `lightSensor` | `deckard` / `0x0427` | `BOOLEAN false` or `BOOLEAN true` |

Status-state settings use Deckard ID `0x0e33` and a 32-bit mask/value pair:

| catalog ID | setting name | mask |
| --- | --- | --- |
| `0xc84` | `statusLEDidle` | `0x00000001` |
| `0xc85` | `statusLEDincoming` | `0x00000002` |
| `0xc86` | `statusLEDactive` | `0x00000004` |
| `0xc87` | `statusLEDheld` | `0x00000008` |
| `0xc89` | `statusLEDcharge` | `0x00000020` |

For each mask, the catalog's SET values are two unsigned integers: false is
`[0, mask]`; true is `[mask, mask]`. This is a mask/value operation rather
than a one-byte boolean.

### Display controls and the missing absolute brightness entry

The only display-related setting in P21 `431a.json` is:

| catalog ID | setting name | messaging / Deckard ID | documented values |
| --- | --- | --- | --- |
| `0xc90` | `relativeDisplayBrightness` | `deckard` / `0x0429` | GET response `0` (`up`) or `32` (`down`); SET `[BYTE 1, UNSIGNED_SHORT 1]` or `[BYTE 1, UNSIGNED_SHORT 2]` |

Despite its name and the copied description “Status LED for charging state”,
`0xc90` is an up/down relative control. It is not a scalar display-backlight
brightness setting. An archive-wide exact search found no `0xc80` setting and
no `absoluteDisplayBrightness`/`screenBrightness` setting. Other product files
in the same archive contain generic `brightness` (`0xc00`) metadata, showing
how a scalar control is represented where applicable; this comparison does not
prove that P21 firmware has no undocumented route.

The renderer bundle declares `DISPLAY_SCREEN_BRIGHTNESS="0xC80"` and labels it
“Screen Brightness”, but that constant occurs only in the declaration. It also
declares `DISPLAY_BRIGHTNESS="0x0C90"` and `DISPLAY_CONTRAST="0x0C81"`; the
catalog-backed P21 `0xc90` entry remains the relative `0x0429` control. The
legacy static evidence therefore does not identify a P21 absolute LCD
brightness command.

## Legacy SDK implementation evidence

Relevant files inside the mounted app:

- `Contents/Resources/app.asar.unpacked/node_modules/@poly/hub-native/hub-native/api-impl/messaging/communicator/addon/mac/Resources/Plantronics/Hub4G/DeviceSettings.zip`
- `.../Components/libNativeLoader.dylib`
- `.../Components/libPLTDeviceManager.dylib`
- `.../hub-native/api-impl/device-settings-manager.js`
- `Contents/Resources/app.asar`, renderer file
  `build/renderer/main.2e135996961ce8ac9d38.js`

`libNativeLoader.dylib` exports/contains the generic metadata path:

- `DeviceSettingStore::getSettingsArchive()`
- `DeviceSettingStore::getSettingsForDevice(...)`
- `DeviceSettingStore::decodeSettingsJSON(...)`
- `DeviceSettingsModule::getSingleSettingValueDeckard(...)`
- `DeviceSettingsModule::getSingleSettingValueRangedDeckard(...)`
- `DeviceSettingsModule::setRangedSettings(...)`
- `DeviceSettingsModule::setRestOverHIDRangedSettings(...)`
- `DeviceSettingsModule::setXUSettings(...)`
- `DeviceSettingsModule::VirtualToRealSettings(...)`

There is no `setVanity...` or `setAmbient...` symbol. This supports using the
catalog-driven generic handlers rather than looking for a dedicated P21 vanity
setter. `libPLTDeviceManager.dylib` does contain
`HostCommand::setScreenBrightness`, `setScreenContrast`, and their
`BaseVideoHostCommand` virtuals, but the symbols are generic video-host APIs;
they do not establish a P21 `0xc80` route and no P21 absolute-brightness
metadata was found.

The JavaScript manager's `setDeviceSetting` calls `setDeviceSettings`, converts
the setting ID to unpadded hex, and sends a generic `SetDeviceSettings` message
through the native addon. It does not encode the Deckard bytes in JavaScript;
the native SDK and `DeviceSettings.zip` supply that translation.

## Naming conflict and evidence limits

The renderer constant names conflict with the old catalog:

```text
renderer: VANITY_LED_LEFT = 0xC8F, VANITY_LED_RIGHT = 0xC83
431a.json: leftVanityBrightness = 0xC83 (selector 0x13)
            rightVanityBrightness = 0xC8F (selector 0x14)
```

The selector values are stable in the catalog, but the physical left/right
orientation is unresolved. Use a live readback or a controlled visual check to
assign physical sides; do not infer that from the renderer labels alone.

The metadata establishes command IDs, types, ranges, masks, and nested payload
elements. It does not establish the outer transport session, report framing,
checksum, or whether a direct BR GET using a global ID is valid. A type-4
exception for direct global-ID probes is consistent with confusing
`globalSettingID` and `deckardId`, or with an uninitialized Deckard session; it
is not evidence that the catalog mapping is invalid.

## Actionable handoff

1. For vanity/status brightness, route through ranged Deckard `0x0e34` and
   retain the selector mapping `status=0x12`, metadata-left=`0x13`,
   metadata-right=`0x14`, then `0xff` and a percent byte.
2. For manual/ambient booleans, use Deckard IDs `0x0426` and `0x0427` with
   the catalog's boolean payloads. For status-state bits, use `0x0e33` with
   the catalog mask/value pairs.
3. Treat P21 `0xc90`/`0x0429` as the documented relative display control.
   There is no legacy catalog evidence for an absolute LCD brightness scalar;
   the LCD-screen LED entity and generic `setScreenBrightness` symbols do not
   supply that missing P21 mapping.
4. Preserve the distinction between catalog IDs and Deckard IDs when building
   a direct controller, and validate any candidate packet only after the parent
   agent's session/framing layer is initialized.
