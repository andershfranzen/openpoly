# P21 (047f:431A) host DFU flash path — validation + wire protocol (static)

2026-09-15. Static RE only; no device touched, no vendor binary run. Addresses are
virtual addresses in the arm64 Mach-O targets named below. Confidence stated per point.

Targets:
- `.../LensService.app/Contents/MacOS/DfuValidation.dll`, `DfuExecution.dll` (.NET, LensControlService)
- `.../LensService.app/Contents/MacOS/eDfu/LegacyDfu` (native arm64 executor, CLI11)
- `.../LegacyHostApp.app/Contents/Components/libDFUManager.dylib` (C++, `TIDFU` class — the real USB wire code)
- `.../LegacyHostApp.app/Contents/Resources/dfu.config`; extracted pkg `/tmp/p21-official-firmware-static/rules.json`

## 0. Host stack topology (high)

431A is routed to the **TIDFU** handler. Two facts pin this:
- `dfu.config` PID `431A` (`DeviceDescription:"HotShot-Manatee"`): `DFUHandlers.USB = "TIDFU"`, `Base=TIDFU`, `Camera=USBDFU`, `Language=TIDFU`, `SetID=SetID`.
- `eDfu/LegacyDfu.supportedDevices.json` line 1327: `pid:17178 (0x431a) → LensProductId "431a"`.

Runtime chain (evidence in strings): **DfuExecution.dll (.NET)** builds a command line
(`BuildExecutorArguments`, `GetExecutorPath`) and spawns the native **`eDfu/LegacyDfu`**
executor → `LegacyDfu` is a thin client that connects over a POSIX socket / pipe named
`LegacyHostDfuServer` (`MacSocketConnection`, `STARTDFU_REQUEST/RESPONSE`,
`Canot send command: %s to LegacyHostApp`) to the resident **LegacyHostApp**, which owns
the USB HID and runs `libDFUManager.dylib` → `TIDFU`. So the byte-level USB protocol lives
in `TIDFU::*` (§B), not in the .NET DLLs.

---

## A. Package validation on the host — CRC32 only, no signature, locally-modifiable (high)

**No signature / no key / no server hash gate on the image.**
- `DfuValidation.dll` is **not** image validation — its types are all scheduling/policy
  (`DfuAvailabilityBackgroundService`, `PostponeDfuManager`, `ValidatePostponeStatus`,
  battery/in-call/postpone checks). No signature/cert/RSA/ECDSA symbols. One `SHA256` token,
  no `expected/mismatch/hash-verify` companions → not an image-integrity check.
- `DfuExecution.dll` downloads the package from a cloud URL (`get_FirmwareUrl`,
  `get_ArchiveUrl`, `IWebFileDownloader`, `DownloadFirmware`) and also keeps a **local repo**
  (`ILocalDfuRepository`, `get_LocalDfuRepoRootPath`). Its lone `SHA256` has no
  mismatch/expected strings; treat as download dedup, not a firmware signature. It exposes
  `get_Rules` (rules.json) and passes device targeting + file path to the executor.
- The native executor **`LegacyDfu`** is a CLI11 tool (`N3CLI*` symbols) whose full option
  set is: `-f,--file`, `--extracted_dfu`, `--rules_path`, `-s,--serial`, `-a,--address`,
  `--vid`, `--pid`, `--language_id`, `--ignore_version_check`, **`--ignore_crc`**, `--force`,
  `--wait`/`--no_wait`, `--loglevel`, `--version`, `--help`. Help text:
  `--extracted_dfu` = "file parameter should point to selected file extracted from zip dfu
  package"; only integrity error is `"CRC error"` / `"Ignore CRC checking"`.
- Device-side integrity in `TIDFU::verify_image_header` (0x9d6bc): reads the file, checks
  `len > 0x47`, byte-swaps a 72-byte header (u32 @0,4,8,0xC,0x10; u64 @0x14 → stored
  this+0x588..0x5a0) and does a device-id match (`"DFU file is targeting different device"`).
  **No hash/MAC computed here.** Container CRC32 is the only integrity (matches
  `firmware-patch-feasibility.md`).

**Answers:**
- Signature / server manifest hash required? **No.** CRC32 only, and `--ignore_crc` bypasses
  even that.
- Locally-modified zip (only `dfu_image.bin` changed, CRCs fixed) accepted? **Yes** — provided
  the 72-byte header device-id/type still matches and container + section CRC32 are fixed
  (already the plan). Nothing else is checked.
- Point the vendor updater at a local package? **Yes**, two ways: (1) invoke
  `eDfu/LegacyDfu --file <dfu_image.bin> --extracted_dfu --rules_path <rules.json>
  --vid 047f --pid 431a` (it then talks to LegacyHostApp); (2) drop the package in the local
  DFU repo. Simplest for our goal is to **skip the vendor stack** and speak §B directly over
  libusb. Confidence high.

---

## B. Wire protocol for the "usb" component on 431A (`TIDFU`) (high unless noted)

All from `libDFUManager.dylib` `TIDFU::*`. The device state object holds:
`+0x460` output report-ID, `+0x461` input report-ID, `+0x468..+0x470` output report buffer
(std::vector), `+0x480..` input report buffer, `+0x4f0` (u16) per-report data capacity,
`+0x4f2` (u8) rolling sequence number, `+0x570/+0x578` firmware begin/end,
`+0xe8` current PID, `+0xec` post-update PID.

### Transport / enumeration (high)
- USB `047f:431A`, **HID vendor usage page `0xFFA2`, usage `0x30`**. Report IDs are **read from
  the HID report descriptor**, not hardcoded: `switch_to_dfu_mode` (0x9ba64) calls
  `DeviceUsage::GetReportID(0xffa2, 0x30)` on the OUTPUT collection → `+0x460`, and on the
  INPUT collection → `+0x461` (0x9bacc / 0x9bae4). A libusb tool must parse the descriptor to
  learn both IDs. (This is the same vendor page 0xFFA2 the settings channel uses; DFU is a
  different usage 0x30 vs settings usage 0xBE.)
- Reports are **HID feature/output reports** via `DeviceUsage::WriteReport(vector)` in
  `write_output_report` (0x9dd10); responses read from `+0x480` (an event-driven input report
  callback, `ManualResetEvent`).
- **Per-report data capacity** `+0x4f0 = outputReportLength − 8` (0x9beb4: `sub w8,w1,8;
  strh w8,[x19,0x4f0]`), where report length comes from `GetDeviceCaps`. Header is 8 bytes.

### Output report layout (high)
```
[0] report-ID (+0x460)
[1] command byte
[2] sequence number (+0x4f2, post-incremented every report)
```
Data-carrying reports (`init_output_report_with_dfu_data`, 0x9deb4) add:
```
[3]     chunk length (u8)
[4..7]  target address (u32, LITTLE-endian)
[8..]   firmware bytes (chunk length of them)
```
Command-only reports (`init_output_report`/`send_command`, 0x9dcac/0x9db0c) stop at [2].

### Commands (byte at [1]) (high)
| cmd  | method | meaning |
|------|--------|---------|
| 0x91 | `enter_dfu` (0x9da6c) | enter DFU (alt/legacy entry) |
| 0x92 | `switch_to_dfu_mode` (0x9ba64) / `exit_dfu` (0x9d9cc) | switch into DFU mode |
| 0x94 | `init_dfu` (0x9dc0c) / start of `write_firmware` | init / begin firmware write |
| 0x97 | `reset_device` (0x9c554) | reset device after write |
| 0x99 | data chunk, in `write_firmware` (0x9c3e0) | write a data block |

### Input (response) report layout + ack (high)
`verify_input_report` (0x9e2fc):
```
[0] report-ID  (must equal outReport[0])
[1] command echo (0x90..0x9e; must equal outReport[1])
[2] sequence echo (checked only when verify-seq flag set; must equal outReport[2])
[3] status/result code
```
Accepted status: `(1<<status) & 0x4003` ⇒ status ∈ {0x00, 0x01, 0x0E} pass; anything else is
an error and the run logs the status byte. ACK timeouts: mode/init commands **30 s**
(`read_and_verify_input_report(0x7530,1)`); **each data chunk 10 s** (`0x2710`) — see
`write_firmware` 0x9c418. There is one ACK **per chunk** (synchronous), gated on the input-
ready event; this is the slow discipline noted in `icon-push-transport.md`.

### Chunk sequencing (high)
`write_firmware` (0x9c174):
1. send **0x94** (start), wait ACK 30 s.
2. loop over firmware `[+0x570,+0x578)`; each chunk `len = min(remaining, +0x4f0)`;
   `target address = cumulative byte offset starting at 0` (source offset == target address,
   both advance by `len`); build 0x99 report; write; wait ACK 10 s; report % progress.
3. addresses are **plain running offsets from 0**, LE, not flash absolute addresses.

### Full `Start()` order (0x9b02c) (high)
`read_dfu_file` → `verify_image_header` → `attach_device(vid,pid)` → `is_legacy_device` →
`switch_to_dfu_mode` (cmd 0x92) → `write_firmware` (0x94 then 0x99…) → `reset_device`
(cmd 0x97) → `detach_device` (close HID) → `wait_and_attach_device` → `check_component_version`.
There is **no host-side end/verify/CRC command** — the device verifies internally
(RECEIVE→WRITE→VERIFY→PROMOTE, firmware side) and promotion is device-driven.

### Re-enumeration (medium)
After reset the handler re-attaches to `get_post_update_pid()` (0x9c5dc): returns `+0xec`
(post-update PID) if set, else `+0xe8` (current PID = 0x431A). The audio/HID MCU DFU is
HID-tunnelled in-application (not USB-DFU-class), so 431A is expected to **stay 047f:431A**
across the flash (unlike the camera, whose corrupt/DFU PID is 095D:9299 per dfu.config).
Medium confidence — the exact `+0xec` value is not resolvable statically; a libusb tool should
just wait for 047f:431A to re-appear and re-read the version.

### setid step (high)
`SetID` is a **separate handler** (`SetID::Start` 0x991b0), invoked after the image DFU per
`rules.json` (`"type":"setid"`). It is **not** part of the image transfer: it issues a
HostCommand `HostCommandInternal::setSetID(u16,u16,u16,u16)` with
`setSetIDWriteMode(true/false)` around it, then re-reads (`getSetID`) to confirm
(`"New SetID not correct"`, `"Performing SetID update."`). `DFUManager::is_setid_up_to_date`
gates whether it runs. For a one-shot APP_MAIN code patch that keeps the same version, setid
is **optional** — it only writes the 4×u16 setID metadata (`1.1165.71.2094`) and does not
touch APP_MAIN. Skipping it leaves the stored setID unchanged.

---

## C. Can `dfu_image.bin` be sent alone? — Yes (high)

`rules.json` lists 5 components (usb, bootloader, tuningpackage, camera, setid) but each is an
independent handler run: `TIDFU` handles the `usb` image; `bootloader`/`tuningpackage` are
separate TIDFU images, `camera` is `USBDFU` (095D:9298→9299), `setid` is the metadata write.
`TIDFU::Start` flashes exactly the one file it is given (`--file`) and re-enumerates; nothing
requires the sibling components. So a libusb tool can send **only** the patched
`dfu_image.bin` (usb component) and skip bootloader/tuning/camera/setid. The device's A/B
trial-with-fallback (firmware side) still protects a bad image.

---

## Minimal libusb recipe (derived)
1. Open 047f:431A; parse HID report descriptor; find report IDs for usage-page 0xFFA2 usage
   0x30 on the OUTPUT and INPUT collections; note output report length `L`; chunk cap `= L−8`.
2. (optional) send 0x91/0x92 to enter DFU; send **0x94**, await ACK (status∈{0,1,0xE}).
3. For each chunk: `[id,0x99,seq++,len, addr_le32, data…]`, write output report, await input
   report `[id,0x99,seq,status]` within 10 s. `addr` and source offset both start 0, += len.
4. Send **0x97** (reset). Wait for 047f:431A to re-enumerate; read version to confirm.
5. setid step not required for a same-version APP_MAIN patch.

Confidence: high on report layout, command bytes, chunk framing, sequence/ack, and CRC-only
validation (all directly disassembled). Medium on post-update PID constancy and on the exact
device-side status-code semantics. The header field names at +0x588.. were not fully resolved
(only that they are byte-swapped u32/u64 and drive a device-id match, no MAC).
