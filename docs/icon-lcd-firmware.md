# Icon LCD driver (LT7735 / ST7735-class) — static findings

2026-09-15. Static reverse-engineering only. No USB/HID, no flashing, no vendor code.
Input `dfu_image.bin` SHA-256 `bd3e11161f0440d20dba19a8f01cd5a0b58357ea822c494c5f588adeaf1c52e5`,
APP_MAIN load `0x50000`, VM = container file offset + `0x4ff80`. Disassembly with
`objdump -d --triple=thumbv6m-none-eabi /tmp/p21-main-thumb.elf`. Confidence stated per item.

## Summary

The "icon" LCD is an ST7735/LT7735-class SPI panel driven by an object at RAM `*0x20002170`.
It is an **RGB565** panel, native **82(W)×160(H)** (an 80×160 module with the usual offset),
run in landscape (MADCTL MV=1 → 160 wide × 82 tall). Built-in icons live in a **separate,
memory-mapped QSPI "ICON image" at `0x60140000`** (flash offset `0x140000`); a name→bitmap
table is parsed at boot. The only `draw()` caller is the **indicator task**
(`c_indicator_task.cpp`); a host "set icon" request must set the current-icon byte and post an
indicator-task event, not call the driver directly.

## 1. draw() — `0x69684`  (confidence: high)

C++ signature (`this` in r0, 4 GPR args + 2 stack args):

```
int Icon_draw(disp *this, int x, int y, int w, int h, const void *pix565);
//              r0          r1     r2     r3    [sp+0x30]  [sp+0x34]
```

Returns 0 on success; nonzero = failure (each step logs a distinct error). Behavior:

- `0x69690` gate: `ldrb [this,#0xc]; cmp #5` — panel **ready/format state must be 5**
  (set by the init state machine, see §2). Also requires `w>0, h>0, pix!=0`. Else logs
  `"Invalid format for icon %d x %d"` (`0xb2a24`) with w,h and returns.
- `0x696c0` reads MADCTL flags at `[this,#0xa]`, bit5 = **MV** (`0x20`). Two clip calls to
  helper `0x69228` bound each axis:
  - MV=0 (native): x/w clipped to max **`0x52`=82**, y/h clipped to max **`0xa0`=160**.
  - MV=1 (rotated): x/w clipped to **160**, y/h clipped to **82** (axes swapped).
  - Failures log `"Icon MV = {0|1} {W|H} failed"` (`0xb2a48..0xb2a90`).
- `0x69748` orientation mirror: if MV(bit5) set and mirror(bit6 `0x40`) clear,
  `x = 0xa0 - x - w` (MADCTL MX/MV handling).
- `0x6975e → bl 0x69168` set address window (CASET/RASET): `(x, y, x+w-1, y+h-1)`.
  Fail → `"Icon set region failed"` (`0xb2aa8`).
- `0x6978c → bl 0x690c0` enter RAM-write / data mode (RAMWR `0x2C`).
  Fail → `"Icon enable RS failed"` (`0xb2ac0`).
- `0x697a2` final blit: `r0 = *this` (SPI transport object at `this+0`), `r3 = (*r0)->vtable[0x20]`,
  length `r2 = w*h*2` (**`<<1` → 2 bytes/pixel = RGB565**), `r1 = pix565`, `blx`.
  Fail → `"Icon Write failed"` (`0xb2ad8`).

**Byte order / pointer**: `pix565` is passed straight into a generic block-copy SPI writer
(`(*transport)->vtable[0x20](transport, ptr, w*h*2)`) that streams bytes sequentially. It reads
`w*h*2` bytes in order; the panel COLMOD is RGB565 (§2), so bytes are big-endian RGB565 pairs as
the panel expects. **The buffer may be RAM or flash** — nothing requires flash; built-ins simply
happen to point into memory-mapped flash. Injected code can pass a RAM buffer.

## 2. Panel object, resolution, init  (confidence: high)

- **Global instance**: display object pointer at **`*0x20002170`**. Constructed/stored at
  `0x6e6ac` (`str r4,[0x20002170]`), then `0x69594` runs panel init; failure logs
  `"ICON display init failed."` (`0x6e704`) tagged `c_indicator_task.cpp`.
- Object fields: `+0x00` = SPI transport object ptr (its vtable slot `0x20` = block write, slot
  used by set-window/RS helpers too); `+0x0a` = **MADCTL byte** (bit5 MV `0x20`, bit6 MX `0x40`);
  `+0x0c` = init/ready-state field, value **5 = ready** (draw's format gate).
- **Init sequence** state machine `0x69454` issues the ST77xx command set (confirms panel class):
  `0x11` SLPOUT, `0x26` GAMSET, **`0x36` MADCTL with parameter = `[obj+0x0a]`** (`0x694ee`),
  `0x3a` COLMOD (RGB565), `0x29` DISPON, stepping `[obj+0x0c]` 2→3→4→…→5.
- **Resolution**: native **82×160**, active icon area used is **60×60 at (x=54, y=9)** in the
  landscape (MV=1, 160×82) orientation — see the single draw call §3.

## 3. Built-in icons: ICON image + name table  (confidence: high)

- **Storage**: a separate, memory-mapped QSPI flash region, base **`0x60140000`**
  (`0x60000000 + 0x140000`; literals at `0x60608`=`0x140000`, `0x6060c`=`0x60000000`, summed at
  `0x60546`). It is NOT inside `dfu_image.bin` (which is APP_MAIN only). DFU path validates it —
  `"DFU-APPL: detected valid ICON image"` (`0x5d240`); `0x140000` also referenced at
  `0x5c2c8`, `0x5c78c`.
- **Header** (walker `0x60538`): `+0x00` u16 magic == `0x48ea`, `+0x02` u16 magic == `0x544f`,
  `+0x06` u16 entry count (must be ≤ 7 → up to 8 entries), first entry at `+0x08`.
- **Entry** stride **0x14 (20 B)**: `+0x00` u16 (id/type, unused by walker), `+0x02`
  NUL-terminated **name**, `+0x12` u16 **bitmap offset** (absolute bitmap ptr = `0x60140000 + off`).
- Walker maps name→pointer into the **icon-manager object** (`*0x20002168`) at
  `manager + (0x6a+idx)*4`:

  | idx | name  | manager offset | name literal |
  | --- | ----- | -------------- | ------------ |
  | 0 | `black` | `+0x1a8` | `0xb0624` |
  | 1 | `poly`  | `+0x1ac` | `0xb062c` |
  | 2 | `call`  | `+0x1b0` | `0xb0634` |
  | 3 | `teams` | `+0x1b4` | `0xb063c` |
  | 4 | `zoom`  | `+0x1b8` | `0xb0644` |
  | 5 | (unfilled) | `+0x1bc` | — |

  Bitmaps are raw RGB565, 60×60×2 = 7200 B each, read directly (XIP) — draw passes the stored
  pointer through to the SPI writer. No dedicated SPI-flash read routine is involved for icons;
  the CPU reads mapped flash.

## 4. Task/context and the "set icon" path  (confidence: high for structure, medium for HID number origin)

- **Only caller of draw()** is `0x60a44`, inside the icon render routine of the **indicator task**
  (`c_indicator_task.cpp`, `0xb055c`; SPI-fault/WDT logic `"SPI error detected: Firing WDT"`
  `0xb064c`, `"Exceeded Icon retry count"` `0xb066c` live here). draw() therefore runs in
  indicator-task context, which owns the SPI bus, retry counter, and WDT. **Do not call draw()
  from a USB/HID handler.** Post an indicator-task event instead (same event-queue architecture as
  the side-light event `0x08e7` in `side-lights-firmware.md`).
- **`SetIcon(manager, index)` = `0x607a8`** is the intended entry. It: validates `index ≤ 5`,
  checks display obj present (`*0x20002170`), checks the icon's bitmap slot
  `manager[(0x6a+index)*4]` is non-null (icon exists in the ICON image), writes the **current-icon
  byte `*0x20003a1d = index`**, then **posts an event** via `0x8803c(*0x60804, 3)` that wakes the
  indicator task to render (the render routine reads `0x20003a1d` at `0x60af0` and calls draw).
- **HID report 0x0d value 22/23 ↔ icon**: `SetIcon` cross-maps app icons to values **22/23**:
  `index==4` (zoom) → `0x88dbc(22)` (`0x607d4`), `index==3` (teams) → `0x88dbc(23)` (`0x607e0`),
  else → `0x88dbc(0)` (`0x607e8`). So **22=zoom, 23=teams, 0=none**, matching the report 0x0d
  values. `0x88dbc` is the host-notify/state hook for that value. The inbound direction
  (host report 0x0d=22/23 → SetIcon) uses the same table but was not traced end-to-end from the
  HID report parser here; the value↔icon association itself is firm.

### Recommendation for the patch (arbitrary host pixels)

Two viable injection points, both must execute in / hand off to the indicator task:

1. Call `Icon_draw(*0x20002170, x, y, w, h, ramBuf)` directly from indicator-task context with a
   RAM RGB565 buffer (pointer may be RAM — §1). Simplest; bypasses the ICON-image table.
2. Repurpose the unfilled slot `manager+0x1bc` (index 5) or an existing slot to point at a RAM
   buffer, then `SetIcon(*0x20002168, index)` so the normal event/render path draws it.

Route the trigger through an indicator-task event (mirror `0x8803c(*0x60804,3)` / the `0x08e7`
mechanism); a HID/BR handler should post that event, not touch the SPI panel itself.

## Reproduce

```
objdump -d --triple=thumbv6m-none-eabi --start-address=0x69684 --stop-address=0x697c8 /tmp/p21-main-thumb.elf   # draw
objdump -d --triple=thumbv6m-none-eabi --start-address=0x69454 --stop-address=0x69594 /tmp/p21-main-thumb.elf   # panel init (ST77xx cmds)
objdump -d --triple=thumbv6m-none-eabi --start-address=0x60538 --stop-address=0x60608 /tmp/p21-main-thumb.elf   # ICON-image name walker
objdump -d --triple=thumbv6m-none-eabi --start-address=0x607a8 --stop-address=0x60800 /tmp/p21-main-thumb.elf   # SetIcon (index→22/23)
```
