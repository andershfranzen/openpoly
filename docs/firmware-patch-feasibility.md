# P21 APP_MAIN patch feasibility (static, offline)

Scope: can a patched APP_MAIN (adds an icon-LCD "draw host pixels" command) be
built and installed safely, flashed once, never reflashed. Static RE only — no
device touched. Confidence stated per finding.

Memory map (derived):
- Bootloader `APP_BTLR_A/B` load base **0x10000** (VM = fileoff + 0x10000; string-pointer vote 295/? for K=0x10000; reset 0x13414, SP 0x2000ffe4). High confidence.
- `APP_MAIN` load base **0x50000** (VM = fileoff + 0x4ff80; reset 0x5ced8, SP 0x2000ffe4). Given.
- SRAM 0x20000000..0x20010000 (64 KB); both SPs 0x2000ffe4.
- Container: "FIRMWARE" magic, 32-byte section entries; section checksum = zlib CRC32(section bytes); header 0x1c = CRC32(bytes[0x20:end]). Given/verified.

---

## 1. Integrity checks end-to-end — CRC32 ONLY. High confidence.

Evidence it is *only* CRC32, no hash/signature/key/version gate:
- Crypto-constant scan of `dfu_image.bin`, `dfu_btlr.bin`, `tf.bin`: **no** SHA-256/SHA-1/MD5 IV, **no** secp256r1/ECDSA constants. Only the reflected CRC32 polynomial `edb88320` appears — dfu_image.bin @ file 0x69a2c (×1), dfu_btlr.bin @ file 0x17c40 (×2).
- Entropy scan of APP_MAIN: **0** high-entropy 256-byte blocks → no embedded public key, no signature blob, no compressed/encrypted payload.
- APP_MAIN DFU dispatcher (VM ~0x5ac80–0x5ad14, `refs.py`) logs `detected valid appl image` (0xaf314 ref @ 0x5ad84) / `detected invalid image` (0xaf368 ref @ 0x5ad98) purely off an image **type-enum** compare (values 0x440b / 0x440c, see §5) — not a MAC.
- Bootloader validates the running image by CRC: `detected valid working ARM image` / `detected corrupt working ARM image`, `detected valid working DSP image` / `corrupt`. No signature strings anywhere in either binary.

Implication: to install a patched APP_MAIN you must fix **two** CRC32s — the
`APP_MAIN` section checksum (entry @ container 0x3c) and the header rollup CRC
@ 0x1c. Nothing else gates acceptance. Confidence: **high** (absence proof from
constant + entropy scans, plus no crypto call sites near verify strings).

## 2. Trial/stable A/B fallback — automatic, brick risk LOW. High confidence.

Bootloader (`dfu_btlr.bin`, strings): `VerifyNoDfu`, `VerifyDfuImage`,
`HandleDfuState`, dual `APP_BTLR_A`/`APP_BTLR_B`, `_COMBO_A_SIZE == _COMBO_B_SIZE`.
On boot it CRC-checks the working combo; on corruption it recovers:
- `detected corrupt working ARM image`
- `detected dirty combo flash area and no stable image`
- `could not find stable version of ARM and/or DSP`
- `detected explicit disable of stable image recovery`
So a bad-CRC or crashing trial image → bootloader falls back to the **stable**
combo automatically (unless recovery was explicitly disabled — default is enabled).

Trial→stable **promotion** happens only after the trial image proves itself.
APP_MAIN promotion guards (strings @ 0xaf0f4–0xaf1f0):
- `Error promoting, APP_MAIN not found in TRIAL combo`
- `Error promoting, APP_DSP not found in TRIAL combo`
- `Error promoting, DSP version message not received`  ← DSP must boot & report version
- `Error promoting, HID enumeration not detected`      ← device must enumerate USB HID
Plus telemetry `HID enumeration result: %x`, `Dsp verification result: %x`.

Net: promotion requires the patched trial to (a) enumerate HID to the host and
(b) receive a DSP version message. If the patch breaks either, it is **never**
promoted; the device keeps running stable. Combined with CRC boot-fallback, the
practical brick risk of a single trial flash is low. Confidence: **high**.

## 3. Free space for injected code — ample, no section growth needed. High confidence.

Inside APP_MAIN (already covered by the section CRC, flat 0x00 flash):
- **0xbef7f–0xcaa80, 0xbb01 = 47,873 bytes** contiguous 0x00 — the injection target.
- smaller gaps: 0xbe3e5 (879 B), 0xbdcdd (131 B), 0xbe35f (113 B).
Section ends at VM 0xce84c; real data resumes after the big gap (tail at ~0xcaa80+).

Recommendation (ponytail): put the new handler in the 47 KB internal padding and
keep `APP_MAIN` length **byte-identical** — this sidesteps every partition-size
question. Growing the section is possible but bounded by the combo partition:
bootloader has `DFU-BTLR: error, image is too large` (str @ 0x269ac, ref @ 0x1266a)
checked against `_COMBO_A_SIZE`/`_COMBO_B_SIZE`; exact byte cap not resolved
statically (linker symbols only, no literal). Don't grow — no need to.

RAM scratch for a pixel buffer: 64 KB SRAM, stack top 0x2000ffe4. There is an
existing instrumentation buffer (`smuiMaxInstrumentationSize_bytes`, strings
0xb9ef0/0xb9f40) you can size against. A P21 icon LCD frame is tiny (order 1–2 KB),
so a static buffer in the injected region or reuse of an existing DFU/HID packet
buffer (`nullptr != pucHidPacket` @ 0xb6d24) is sufficient. Confidence: high on
free flash; medium on exact reusable RAM buffer (needs one more trace).

## 4. DFU transport the host must speak — proprietary HID + "BR" (Boson) framing, NOT USB-DFU class. Medium-high confidence.

Findings in APP_MAIN:
- No USB-DFU-class artifacts (no DnLoad/GetStatus/Manifest/bInterval/DFU-descriptor strings). The 431a device is **not** a standard DFU-class target. fwupd's dfu quirks for 095d:9298/9299 are the **camera**, irrelevant here.
- USB stack is **Synopsys** (`UsbDrvSynopsys.c`, `c_usb_da14195.cpp`, `CUsbDa14195`) exposing **HID** (`nullptr != pucHidPacket`, `nullptr != poHidUsage`, `c_usb_pid_handler.cpp`).
- Application messaging is Plantronics **"BR" gateway** (Boson Relay): `BR: Gateway Task, Session Initialization / Transport Availability / Transmit Data to output ...` (0xae700–0xae924). DFU is driven by BR messages.
- DFU is entered via a message, not a USB request: `PltMessageIdNamespace::eTfEnterDfuState` (0xaf938). The state machine then walks `RECEIVE_TRIAL → WRITE_TRIAL → VERIFY_TRIAL → PROMOTE_TRIAL` (state strings 0xafaa4–0xafc68), with `received message - exit dfu` / `reset dfu` (0xaf284/0xaf2ac).

So a host tool must: open the 047f:431a **HID** interface, run the BR/Boson
session handshake, send `eTfEnterDfuState`, stream the combo image in BR data
frames through the WRITE/VERIFY states, and issue the promote trigger. This
matches the old Poly Lens **TIDFU** (`dfu.config`) model (HID-tunnelled, not
USB-DFU-class).

**What's still missing for a working host tool** (needs live capture or deeper
trace, not resolvable from these 5 files): the exact HID report ID(s) and report
length, the BR frame opcode/enum numbers, and the DFU chunk size / sequencing.
The *mechanism* is identified; the *wire constants* are not. Confidence:
medium-high on mechanism, low on the concrete byte-level protocol.

## 5. Separate "ICON image" DFU type — yes, same CRC validation. Medium-high confidence.

- `DFU-APPL: detected valid ICON image` (0xafd84, ref @ 0x5d240).
- Dispatcher @ 0x5d1d0: image type-enum compared to `0x440b` (→ generic appl path) and `0x440c` (→ ICON path). `0x440c` routes to an ICON-specific handler `bl 0x6d440` then logs the ICON string. Same code path as appl — **same CRC32 container validation, no extra check**.
- Related section-name strings present: `ICONLCD` (0xb1278), `SOFT_ICON` (0xb1990), `BUTTON_SOFTICON` (0xb1be8), plus `ICON display init failed.` (0xb5818).
- This shipped package contains only `APP_MAIN` + `APP_DSP` sections — **no ICON section is included**, so the on-flash ICON section name/magic can't be confirmed from these files; the image *type* is the enum `0x440c` inside the DFU message, validated by CRC like everything else.

Design consequence: instead of patching APP_MAIN code, the host-pushed-pixels
feature *may* be deliverable as an **ICON image** DFU type the stock firmware
already accepts — worth confirming whether `0x440c` ICON images carry raw LCD
frames (that would avoid touching APP_MAIN entirely). Confidence: medium-high
that the type exists and is CRC-only; low on ICON payload format.

---

## Bottom line
- Integrity is **CRC32 only** — no signatures, keys, or version locks. Patch is buildable by fixing the section CRC + header CRC. (high)
- **A/B auto-fallback + guarded promotion** make a single trial flash low-risk; a broken patch reverts to stable and never promotes. (high)
- Inject into the **47 KB of 0x00 padding at 0xbef7f** with the section length unchanged — no partition-size fight. (high)
- Transport is **HID + BR/Boson (TIDFU-style)**, entered via `eTfEnterDfuState`; a host tool needs the HID report IDs and BR opcodes, which require a live capture to pin down. (mechanism high, constants low)
- An **ICON DFU type (enum 0x440c)** already exists and is CRC-validated — possibly a cleaner delivery path than patching code. (medium-high)
