# Icon-LCD push: host→firmware transport (static)

2026-09-15. Static disassembly only. No USB, no vendor code, no device writes.
Firmware `dfu_image.bin` SHA-256 `bd3e11161f0440d20dba19a8f01cd5a0b58357ea822c494c5f588adeaf1c52e5`;
APP_MAIN VM base `0x50000`, so **file offset = VM − 0x4ff80**. Disassembled from
`/tmp/p21-main-thumb.elf` with `objdump -d --triple=thumbv6m-none-eabi`.

This lane maps the transport for a firmware patch that lets the host stream pixels
to the icon LCD. It does not analyze the draw function (`0x69684`, other lane).

## 1. BR command dispatcher and hook points (high confidence)

The host BR frame arrives as a task message; the task message-handler at `0x65c90`
switches on message-id field `[msg+0x16]` and, for **id `0x1c1e` (BR SET)**, calls the
SET dispatcher `0x64860` (`bl` at `0x65d98`, args `r0`=task obj, `r1`=message).
Id `0x1c1f` (BR GET) routes to `0x63e8c`. (`0x1c1e`/`0x1c1f` read from literals
`0x66018`/`0x6601c`.)

Dispatcher `0x64860` prologue:
- `0x64882` `bl 0x84d2c` → `r9` = payload ptr (`[msg+0x18]`, else `msg+4`).
- `0x64886` `bl 0x84d18` → `r4/r5` = payload length (`[msg+0x10]`, 17-bit).
- `0x6489a` loads `[r9]`, byte-swaps → `r6` = **big-endian uint16 wire command ID**.
- `0x648b0` `cmp r5,#2 / bhi` → payloads ≤2 bytes get an exception; else fall to the
  compare cascade at `0x648e6` (`sxth r3, r3` = command ID).

The cascade is a **binary-search of `cmp`/`beq`/`bl` against a 32-bit literal table at
`0x64bb8`** (file `0x14c38`), NOT a jump table. Exact decode points:

| VM     | Instr                         | Command | Target |
|--------|-------------------------------|---------|--------|
| `0x648e8`/`0x648ea` | `ldr r2,[0x64bb8]` `cmp` `beq 0x649b4` | `0x031b` | I²C/diag label family |
| `0x648f0`/`0x648f4` | `[0x64bbc]` `beq→0x64e3a` | `0x0307` | — |
| `0x648fa`/`0x648fe` | `[0x64bc0]` `beq→0x64ca4` | `0x0305` | — |
| `0x64906`/`0x6490a` | `sub#5` `beq→0x64c10` | `0x0300` | test-gate SET |
| `0x64912`/`0x64916` | `[0x64bc4]` `beq→0x650ca` | `0x0311` | — |
| `0x6491c`/`0x64920` | `sub#9` `beq→0x64f1a` | `0x0308` | — |
| `0x64928`/`0x6492c` | `[0x64bc8]` `bl 0x651d2`  | `0x0312` | — |
| **`0x64932`/`0x64936`** | `[0x64bcc]=0x0317` `bne+2` **`bl 0x65254`** | `0x0317` | palette color |
| `0x64940`/`0x64944` | `[0x64bd0]` `bl 0x653ea` | `0x03b9` | — |
| `0x6494c`.. | `[0x64bd4]` `bl 0x6551e` | `0x0321` | — |
| `0x64958`.. | `sub#1` `bl 0x6544c` | `0x0320` | — |
| `0x64966`.. | `0xc9<<2=0x0324` `bl 0x655ae` | `0x0324` | — |
| `0x64972`.. | `[0x64bd8]` `bl 0x65642` | `0x03a1` | — |
| `0x64980`.. | `0x80<<5=0x1000` `bl 0x656e8` | `0x1000` | — |
| `0x6498e`.. | `[0x64bdc]` `bl 0x6536e` | `0x03ba` | — |
| `0x6499c`.. | `[0x64be0]=0x1002` `bl 0x65756` | `0x1002` | — |
| `0x649a6`.. | `[0x64be4]=0x1007` `bl 0x65852` | `0x1007` | — |
| default | `bl 0x658c6` | any other | **type-7 exception reply** |

Dispatched SET IDs: `0300 0305 0307 0308 0311 0312 0317 0320 0321 0324 03a1 03b9 03ba 1000 1002 1007`.

**Minimal-change hook options (in order of preference):**

1. **Add a sub-op under `0x031b` (best template).** The `0x031b` branch (`0x649b4`)
   already does a variable-length, ASCII-labelled sub-dispatch of the message body:
   at `0x64a3e` it `memcmp`s the body's first bytes against `"I2C"` (`0xb1274`, len 3)
   and, on match, calls the I²C bridge parser `0x63778`; sibling labels `"CONTROLR"`
   (`0x649e8`) and others share the pattern. A new label (e.g. `"LCD"`) is a bounded
   insertion: one `memcmp` + `bl <new_handler>` block modelled byte-for-byte on
   `0x64a3e..0x64a68`. The body already carries a length-prefixed payload at `r9+0xc`,
   which is exactly what a chunked pixel command needs (see §3). The first-char jump
   table is at `0xb0e5c` (`[0x64be8]`).
2. **Retarget one handler `bl` (4-byte patch).** Repoint e.g. `0x64938`
   `f000 fc8c` (`bl 0x65254`) — or an unused ID's `bl` — to a new handler in free
   flash. Cheapest single edit, but consumes that command ID.
3. **Claim a fresh top-level ID** = harder: the cascade has no spare `cmp` slot, so a
   genuinely new ID means editing both a literal-table word and inserting a compare.
   Not recommended vs. option 1.

## 2. Framing, payload cap, USB path, throughput (high confidence)

Transport is unchanged from the working lights path (`src/lights.c` `br_send`/`br_parse`):

- **USB:** audio device `047f:431a`, **interface 3**, HID **report ID `0xde`**, report
  size **62 bytes**. SET = control `bmRequestType 0x21`, `bRequest 9 (SET_REPORT)`,
  `wValue 0x02de`, `wIndex 3`. Reply is polled via `bmRequestType 0xa1`,
  `bRequest 1 (GET_REPORT)`, `wValue 0x01de`, `wIndex 3`.
- **Frame layout** (`br_send`): `de 01 01 10 | LL | 00 00 00 | MT | idHi idLo | data…`
  padded to 62. `LL = 6 + n`. `MT` = message type (SET `05`). Wire ID is BE uint16.
- **Max payload:** `br_send` caps `n ≤ 51` (`0x33`). So **≤51 application bytes per
  message**, of which 2 are the wire ID → ~49 body bytes; after a per-chunk sub-op +
  offset header (~4 B) ≈ **~45 usable pixel bytes/msg ≈ 22 RGB565 px/msg**. The
  firmware side allows more (the `0x031b` body parser permits counts to 49, side-light
  doc), but the 62-byte report is the hard ceiling; there is no multi-report
  fragmentation on the `de` channel in this codebase.
- **Throughput:** 80×160 RGB565 = 25 600 B → ~545 messages.
  - *Current ACK-per-message discipline* (host waits for the type-6/type-3 reply,
    polled on a 25 ms `nanosleep` grid, `br_wait`): ~25–50 ms/msg → **~15–25 s/frame**.
    Too slow for animation; usable for a one-shot icon.
  - *Fire-and-forget chunks* (patch replies only once, at frame commit): back-to-back
    EP0 SET_REPORTs are ~0.5–1 ms each → **~0.3–0.6 s/frame (~2 fps)**; a 64×64 icon
    (~175 msgs) ≈ 0.2 s. **Strongly recommend a `begin / chunk* / commit` design where
    only `begin` and `commit` emit a reply**, so the host is not gated per chunk.

## 3. Incoming buffer RAM + task context (high confidence)

- Incoming bytes live in the **heap task-message object** (`r4`/arg1). Fields:
  `+0x10` length (17-bit), `+0x16` message-id, `+0x18` payload ptr (or inline at `+4`).
  Payload base `r9` = `0x84d2c(msg)`. The parsed BR payload begins with the BE wire ID;
  the `0x031b` sub-handlers take the label at `r9+4` and the length-prefixed body at
  **`r9+0xc`** (`adds r1,#0xc` at `0x64a50` etc.).
- **Lifetime = the handler call only.** The dispatcher releases the message
  (`0x84ce4`) as it returns; a chunk handler must copy pixel bytes into its own
  accumulation buffer before returning. (The `0x031b` parser already heap-allocates a
  scratch object at `0x637e4`/`0x637f2` for its transfer.)
- **Task context:** runs in the thread of the host/BR-command task whose message
  handler is `0x65c90` (entered for SET via event `0x1c1e`). Replies are assembled in a
  **single shared global scratch at `0x20002060`** (`[0x64bb4]`/`[0x65a24]`) and
  enqueued through the task's output port `[taskobj+0x50]` via `0x590fc` (tail
  `0x659e0`). The shared reply buffer means replies are serialized — another reason to
  avoid per-chunk replies.

## 4. Unused IDs and host detectability (high confidence)

- Any command ID **not** in the §1 list reaches the default `bl 0x658c6`, which builds a
  **BR command exception (type 7)** in the shared buffer (header `0x80<<5`, len field 7)
  and sends it. So an unknown ID is **rejected with a reply the host can see**.
- Therefore a patched build is **trivially host-detectable**: probe with your chosen new
  ID (or `0x031b` + `"LCD"` label); stock firmware returns type-7 exception, a patched
  build returns your success reply. No silent-drop ambiguity.
- **Safe to claim:** any ID outside the dispatched set. Cleaner still, adding a `"LCD"`
  sub-label under `0x031b` claims **no** new top-level ID and cannot collide with a
  future stock ID. If a top-level ID is preferred, pick well away from the `03xx`/`10xx`
  clusters (e.g. `0x03f0`); confirm absence with a full-image literal scan before use.

## 5. HID output report `0x0d` as an alternate hook (low value — reject)

`src/hid.c` drives the softphone icon: **output report `0x0d`**, control `bmRequestType
0x21 / bRequest 9`, `wValue 0x020d`, `wIndex 3`, 4-byte payload `[0d, 00, val_lo,
val_hi]` (usage `f0`, 16-bit value in bits 8–23); state reads back in feature report
`06` bytes 10–11. This path carries a **single 16-bit enum** (zoom=22, teams=23), not a
byte stream, and has no length/offset framing. It is unsuitable for pixel transport and
not worth patching; the BR `de` channel (§1–3) is the correct lane.

## Confidence

High for the dispatch map, literal table, payload cap, USB path, exception behavior,
buffer fields, and task routing — all directly disassembled. Throughput figures are
estimates from the report size and the two host reply disciplines; the fire-and-forget
number assumes a patch that defers its reply, which this lane specifies but did not test.
No firmware was executed and no packets were sent.
