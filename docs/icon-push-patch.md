# Icon-LCD host-push firmware patch (APP_MAIN)

2026-09-15. Offline static + unicorn-emulated. No USB/HID, no flashing, no vendor
code executed on hardware. Input `dfu_image.bin` SHA-256
`bd3e11161f0440d20dba19a8f01cd5a0b58357ea822c494c5f588adeaf1c52e5`; APP_MAIN load
`0x50000`, container file offset = VM − `0x4ff80`. Builder/asm/test in
`script/icon-patch/`.

Adds a `0x031b` sub-label **`PLCD`** that lets the host stream arbitrary RGB565
pixels into a RAM framebuffer and blit a rect to the icon LCD, repeatedly, with no
reflash. Chosen over the SetIcon/indicator-event route because the stock firmware
already draws to the panel **directly from this same BR-task context** (label
`ICONLCD`, `0x63674` → fill primitive `0x69288`), so a direct `Icon_draw`
(`0x69684`) call is proven-safe here and redraws unconditionally on every `Show`
(exactly what a looping GIF needs — no index-unchanged skip to defeat).

## Wire format (exact bytes)

Transport unchanged (`src/lights.c` `br_send`/`br_parse`): audio `047f:431a`, iface
3, report `de`, 62 B; SET = control `0x21/9`, `wValue 0x02de`, `wIndex 3`. Send
**`br_send(h, type=5, id=0x031b, data, n)`**. Frame:
`de 01 01 10 LL 00 00 00 05 03 1b <data…>` pad-62, `LL = 6+n`.

`data` layout (what firmware sees at payload `r9+2`):

| off | bytes | meaning |
|-----|-------|---------|
| 0   | `00 00` | reserved (payload `r9+2`, unused by label dispatch) |
| 2   | `50 4C 43 44 00 00 00 00` | 8-byte label field = `"PLCD"` NUL-padded (`r9+4`) |
| 10  | body… | op + args (`r9+0xc`) |

Body ops (`u8` unless noted). All host values are bounds-checked in firmware.

| op | body bytes | `n` | action |
|----|------------|-----|--------|
| Begin | `42 x y w h` (`'B'`) | 15 | validate & latch rect; alloc framebuffer once |
| Data  | `44 offLo offHi len pix[len]` (`'D'`, offset u16 LE) | 14+len | `memcpy(fb+off, pix, len)` |
| Show  | `53` (`'S'`) | 11 | `Icon_draw(*0x20002170, x,y,w,h, fb)` |
| Query | `51` (`'Q'`) | 11 | data reply, 8-byte magic (build detect) |

Begin limits: `w≥1, h≥1, x+w≤160, y+h≤82, w*h*2 ≤ 7200` (60×60 cap). Data limits:
`1 ≤ len ≤ 37` (report ceiling) and `off+len ≤ w*h*2`; Data/Show require a prior
successful Begin. Pixels are copied raw and streamed to the panel in order —
byte order is the host's (big-endian RGB565 pairs, as the panel's COLMOD expects,
per `docs/icon-lcd-firmware.md §1`).

Examples (`data`, hex):
```
Begin 60x60 @ (54,9):  00 00 50 4C 43 44 00 00 00 00 42 36 09 3C 3C
Data  16px @ off 0:    00 00 50 4C 43 44 00 00 00 00 44 00 00 20 <32 pixel bytes>
Show:                  00 00 50 4C 43 44 00 00 00 00 53
Query:                 00 00 50 4C 43 44 00 00 00 00 51
```

Replies use the stock `0x031b` reply builder (`0x659e0`), same as every sibling
label. **Query** returns a type-10 data reply — mechanism-identical to the I2C
**read** reply the host already parses — payload `00 01 50 4C 50 32 31 4c 43 44 76 31`
= `00 01` + label `"PL"` + magic `"P21LCDv1"`; absence/`type 7` = unpatched build.
Begin/Data/Show return the builder's success acknowledgement (handler status 0);
Data is intended fire-and-forget (host need not poll each chunk).

Per-frame cost: Begin once, then ~200 Data + 1 Show for a 60×60 frame (~0.1 s
fire-and-forget) — ample for looping a Doom-face GIF.

## RAM proof

- **State (16 B) @ `0x20001200`** — inside gapA `0x20001188..0x20001470`, the hole
  between `.data` end and `.bss` start from the reset init (`0x5cf94/0x5cf98` =
  `.data` `0x200000c0..0x20001188`; `0x5cfc4/0x5cfc8` = `.bss`
  `0x20001470..0x20002d81`). gapA is neither copied nor zeroed by startup. A
  word-aligned scan of the whole image for any constant in gapA finds **only** the
  boundary word `0x20001188` (3 refs, all the section marker); the interior is
  referenced **nowhere**. On ARMv6-M an absolute address can only be formed via a
  word-aligned literal (no `movw/movt`), so zero literals ⇒ no instruction can
  address `0x20001200`. Layout: `+0` magic `0x42313250`, `+4` fb ptr, `+8` w u16,
  `+0xa` h u16, `+0xc` x u8, `+0xd` y u8.
- **Framebuffer (7200 B)** from the firmware pool allocator `0x84c40` (freed pair
  `0x84ce4`) — the exact allocator the I2C label handler already calls from this
  BR-task context (`0x637e4`). Allocated once on first Begin, reused for every
  frame; sized to the 60×60 cap. 160×82 (26 240 B) is left unclaimed because
  runtime heap headroom can't be proven statically.

## Hook

One 4-byte edit. The `0x031b` label dispatcher (`0x649ba`) indexes a first-char
jump table at `0xb0e5c` by `(firstChar-'C')`. Slot 13 (`'P'`, `0xb0e90`) is stock
`0x64b0e` (default reply — no stock label starts with `'P'`). Repoint it to the
injected code at **`0xbf000`** (VM even; reached via `mov pc`). Injected
`my_dispatch` confirms the label is exactly `"PLCD"` (two `ldrh` compares) and, on
mismatch, `bx`-es to the stock tail `0x64b0f`, so every non-`PLCD` `'P'` message
behaves exactly as before. On match it calls `my_handler` with the stock label-ABI
(`r1`=body `r9+0xc`, `r2`=`&sp[0x1c]` data-ptr slot, `r3`=`sp+0x2e` len slot), stores
the status at `sp+0x34`, then falls into `0x64b0e` — identical to the I2C block at
`0x64a3e`. Every firmware call is `blx`/`bx` through a literal-pool address with
bit0 set (Thumb); the 364-byte blob is position-independent (no relocations).

Injected at VM `0xbf000` (file `0x6f080`) inside the 47 744-byte zero pad
`0xbef7f..0xcaa80` (all `0x00`, covered by the section CRC); APP_MAIN length is
**unchanged**. Builder asserts every overwritten byte's original value
(pad = `0x00`, hook = `0x00064b0e`), then fixes the APP_MAIN section CRC32
(container `0x3c`) and the header CRC32 (container `0x1c`, over `[0x20:end]`) and
re-parses to verify both.

Reproduce:
```
python3 script/icon-patch/build_patch.py <official dfu_image.bin> --output-dir OUT
ruby script/firmware-inspect.rb --expected-sha256 <patched sha> --output-dir E OUT/dfu_image.bin
objdump -d --triple=thumbv6m-none-eabi --start-address=0xbf000 --stop-address=0xbf16c E/APP_MAIN.thumb.elf
```

## Test results

`script/icon-patch/test_emulation.py` (unicorn) loads the **patched** APP_MAIN at
`0x50000`, runs the real dispatcher from `0x649b4` (so routing + `my_dispatch` +
`my_handler` all execute against real bytes), hooks `malloc/memcpy/draw`/stock I2C
handler, and stops at `0x64b0e`. **35/35 pass**:
- Begin→Data→Data→Show→Query: geometry latched `(54,9,60,60)`, `malloc(7200)` once,
  fb pointer stable, pixels land at the right offsets, `Icon_draw` called once with
  `this=*0x20002170`, correct rect, `pix=fb`, streaming our bytes; repeated Show
  redraws; Query returns `count=8`, data `"P21LCDv1"`.
- Rejections (status 1, no side effects): Begin `w*h*2>7200`; rect off-panel (x, y);
  `w=0`; Data/Show before Begin; Data `off+len>fb`; Data `len>37` (fb untouched);
  unknown op; non-`PLCD` `'P'` label falls through to the default reply running no
  handler.
- Stock `0x031b` `"I2C"` still routes to `0x63778` and never touches injected code.

Emulation caught two real bugs pre-fix: `blx` to an even literal (would HardFault
on M0 — now bit0-set) and the magic byte typo.

## Remaining risks

- **Direct draw vs indicator task.** Show blits from BR-task context. The stock
  `ICONLCD` label does the same, so this introduces no new SPI-bus/WDT interaction,
  but a concurrent indicator-task redraw could still interleave on the bus (a
  pre-existing vendor condition). One-shot/low-rate use is unaffected.
- **Cold-boot state.** gapA is uninitialized at power-on; the magic word gates all
  ops. A false-positive (random magic + plausible fb ptr + sane geometry, all before
  any Begin) is ~2⁻⁵⁰ and the host always sends Begin first. Not zeroed by startup —
  documented, accepted.
- **No-data ACK type byte** for Begin/Data/Show is not pinned statically (the
  `0x659e0` builder path wasn't fully reversed). Host step should confirm the ACK
  against the device, or rely on Query (type-10, confirmed by I2C-read equivalence)
  for detection and on visible pixels for success.
- **Promotion gate.** Trial→stable promotion still requires HID enumeration + DSP
  version (`docs/firmware-patch-feasibility.md §2`); the patch touches neither.
  CRC-only integrity means a bad flash falls back to stable.
```
