# Side-light control in P21 firmware 2094

## Live verification, 2026-09-15

The primary executed this route successfully. The user confirmed both sides on, one side on during an independent-off test, and both restored. No rear-pad action was needed. CLI commands `sides 0 30`, `sides 30 0`, and `sides 30 30` all pass register verification at addresses `69/6a` on each side and restore the prior gate. Firmware-configured address `68` rejects both one-byte and 15-byte reads on channel `02` (type 7, payload `00 01 49 32 00`); physical population is unresolved, so the CLI verifies only the responding pair.

GET `0300` error `0012` is the explicit mode-zero permission response; silence and other errors remain failures. Changed SET replies must accept type-10 state echoes as described below.

## Static conclusion

BR SET `0317` with payload `[13 or 14, 08, brightness]` reaches a direct side LED register writer. It does not call the rear touch-pad handler. This is the strongest supported route for an immediate side-light test. It requires the RAM test-interface permission enabled by SET `0300 [01]`; the long `031b` I²C bridge does not require that mode, but raw side writes would require changing the shared mux and are a less suitable first route.

This is static evidence. This worker performed no hardware operations. The parent reports that purple on the bottom bar is visually confirmed; preserving that state is part of the side-light experiment.

## Reproduction and addresses

Input is the official `dfu_image.bin`, SHA-256 `bd3e11161f0440d20dba19a8f01cd5a0b58357ea822c494c5f588adeaf1c52e5`. APP_MAIN loads at `50000`; firmware virtual address = container file offset + `4ff80`. The offline extractor is [firmware-inspect.rb](../script/firmware-inspect.rb). Static disassembly uses Cortex-M0 Thumb.

The full route is:

1. `0317` SET dispatcher `64932` compares literal `64bcc=0317`, then reaches `65254`.
2. `65254` requires five bytes including the command, hence exactly three payload bytes. `652b8..652be` accepts selectors `13` and `14`; `652f6..652f8` accepts color `08`; `6532c` requires brightness at most 100.
3. `65350..65356` queues indicator-task event `08e7` (literal `656b0`), with the three values. `6535a..6536a` returns an empty BR ACK type 6. This acknowledges event submission rather than verified physical illumination.
4. Indicator event dispatcher `61168..6116e` recognizes `08e7`, reaches `615ae`, and calls `5f41c` with the three bytes.
5. `5f41c` calls `683d8` (`SetSysEvent`, event `15`). `683fe` sets the controller's current state byte `+8` to forced state `12`; `67200` stores selector at `+22`, converted color at `+23`, and brightness at `+24`.
6. `67f48` state-12 table entry `68398` calls `66f08`. Its selector table at `b17b4` maps `13` to `66fc0`, `14` to `6704e`.

### Exact brightness normalization

`5f424..5f444` preserves zero. For nonzero brightness `b`, division helper `a406c` returns the remainder `b % 10` in `r1`. If nonzero, the code adds `10 - remainder`; otherwise it keeps `b` unchanged. Thus brightness rounds **up** to the next multiple of ten: `1→10`, `41→50`, `99→100`, and `50→50`.

Color `08` converts to internal palette zero (white) in `671c4`; palette table `b39a0` defines white as `(192,192,192)`. A 50% test therefore requests component register values `(96,96,96)`; a 100% test requests `(192,192,192)`.

## Physical side objects and register effects

The table uses firmware IDs. User observation confirmed selector `14` is **left as facing the screen**, and selector `13` is right. The public `lights sides LEFT RIGHT` command corrects this orientation.

| Selector | Globals of LED objects | Internal chip IDs | PCA9548 channel | Device addresses |
| --- | --- | --- | --- | --- |
| `13` | `20002258`, `2000218c`, `2000214c` | 0, 1, 2 | 0, selector `01` | `69`, `6a`, `68` |
| `14` | `20002178`, `20002240`, `200021d0` | 3, 4, 5 | 1, selector `02` | `69`, `6a`, `68` |
| Bottom `12` | `2000222c`, `200021a8` | 6, 7 | 2, selector `04` | `69`, `6a` |

Object constructors `6ea94..6eb3c` all call `CLedsKtd2061` constructor `69e48`, each with 12 outputs. Side ID/address mapping follows the corresponding bus-wrapper constructors `6e796`, `6e800`, `6e838`, `6e870`, `6e8a8`, `6e8e0`; bottom constructors are `6e91a` and `6e954`. The bottom and side objects therefore share chip family ID `a4`; it is not a unique bottom identifier.

For nonzero brightness, selector `13` at `66fc0..67020` and selector `14` at `6704e..670ae` each:

- Call virtual slot `30` (`69da4`) on their three objects, with brightness and mask `0fff` (all 12 outputs). This loops the output descriptors at `b34d8`, sets white component intensity via `69d20`/`69ccc`/`6a234`, and calls `69f40` to write paired output controls.
- Call virtual slot `34` (`6a048`) with the converted color and brightness. `6a048` builds 12 bytes: identical scaled RGB triples for both palette banks, followed by six `88` output-control bytes. `6a13e` calls `6a020` to write registers `03..0e` as one span.

Zero brightness takes the selector-specific branch at `67022` or `670b0`, calls slot `30` with brightness/mask both zero, and does not call slot `34`; output controls are cleared.

These side branches bypass the bottom-only component writer at `66f14..66f4a`. There is no direct bottom register write in either side branch. Normal firmware status activity can still change lighting later.

## `0300` mode snapshot, effects, and restoration

SET `0300` has exactly one payload byte, interpreted as boolean. `6b344..6b36c` explicitly permits SET `0300` before the permission is enabled. The dispatcher `64c46..64c74` reads getter `63e84` and updates RAM byte `CTestInterfaceTask +55` through setter `646a0`. If the requested boolean already matches, `64c60..64c64` takes the early empty ACK path `658e2`.

GET `0300` has no payload and returns one boolean byte via `63f22..63f26` (`0305` literal `641d4`, minus five), handler `6400c..64028`. **Its GET permission gate `6b370..6b38e` requires `+55` already enabled.** A successful pre-GET confirms a prior value of one; an absent reply does not independently establish zero. A mode-zero restore is appropriate only when zero is already established by the session's prior operations/state.

Disabling via `[00]`:

- Clears `+55` in `646ae..646b2`.
- Clears auxiliary `+56` through `64674`, which also calls `6bf5c` to clear global `20002d5a`.
- Takes the early ACK path `64c80..64c86 → 658f0`, without issuing a Teams event or re-rendering LEDs.
- **Does not restore controller current state `+8`, last forced selector/color/brightness, or remembered normal state `+9`.** The side forced state persists until a normal firmware event changes it.

Enabling can queue event `36c8` to indicator task `44` at `64c8a..64c90`, depending on getter `68848` (RAM `20002d52`). The indicator dispatcher filters only events `36c4..36c8` while `+55` is set (`61032..61078`), logging `TE: Turn off Icon` at string `b06c4`. Normal event `36c8` is Teams-icon OFF (`6128e→613b0`, string `b0700`); this is not a scheduler or I²C freeze. There are also mode-sensitive charging/touch branches at `62ac0..62ad0`. Neither mode getter guards the shared mux selector `6a69c` or the side renderer. These are known behavior changes rather than exclusive bus ownership.

The direct mode setter/handler has no flash-write or reset call. This does not establish the semantics of unrelated factory commands or of short `031b` mode events `0867/0868`; those should not be used for this test.

## Bounded packet test for the primary

Use the established audio `047f:431a`, interface 3, report `de`, 62-byte BR transport. Request frame starts `[de,01,01,10,06+payloadLen,00,00,00,type,commandHi,commandLo]`, with payload at byte 11 and remaining bytes zero.

| Operation | BR type | Command | Payload |
| --- | --- | --- | --- |
| Attempt mode snapshot | GET 2 | `0300` | empty; success must be type 3, exactly `[01]` |
| Enable, when prior zero is already established | SET 5 | `0300` | `01` |
| Verify enabled mode | GET 2 | `0300` | empty; require type 3 `[01]` |
| Side selector `13`, white at 50% | SET 5 | `0317` | `13 08 32` |
| Side selector `14`, white at 50% | SET 5 | `0317` | `14 08 32` |
| Restore session-established mode zero | SET 5 | `0300` | `00` |

For `0300`, accept a matching empty type-6 ACK **or** a matching type-10 message with exactly the requested one-byte payload. A changed mode sends both in succession, so waiting only for type 6 can miss completion. For `0317`, require its matching empty type-6 ACK. Reject BR error types 4 and 7. Establish that the queued side event has applied before reporting success: visual observation is needed because an ACK alone is not a brightness measurement. Preserve the purple bottom register snapshot and verify it before/after the side test; these side event branches themselves do not write the bottom objects. If mode was previously one, leave it one. If its previous state is unknown, report that uncertainty instead of treating silence as a snapshot.

This sequence should test immediate side illumination without rear-pad cycling. Until verified by the parent, it remains a static-supported hypothesis, not a live-confirmed replacement for stored setting `0e34`.

## Mode-change response and outer-router correction

The first parent experiment received type-4 error `0012` for initial GETs of `0300`, `031b`, and `1000`; SET `0300 [01]` and cleanup `[00]` timed out in a waiter that accepted only type 6. No `0317` was sent. These observations do not establish that SET `0300` is unsupported or that the mode stayed zero.

Static routing confirms SET `0300` reaches the test task without a prior mode permission:

- ROOT router `5948c` first checks general command predicate `6b28c`; its table `b3d78` contains the 14 normal SET commands, excluding `0300`. The feature getter `68a74` simply returns one in this image.
- `594d8` checks test-mode-54 predicate `6b2ac`, then `594ec` checks `6b344`. The latter explicitly permits `0300` unconditionally. `594f4..59528` forwards the SET event to task `1f`.
- Test task `65d72..65d94` recognizes SET event `1c1e` and calls `64860`. Its `64906..6490c` comparison uses `0305 - 5`, reaching the `0300` handler at `64c10`.

The actual mode-change response explains the timeout. `64c4c` saves the old normalized flag in `r8`, and `64c5e` saves the new normalized flag in `r11`. Common completion `659e0..659ec` sends the empty type-6 ACK first. `659f0` compares old and new; if different, `65a30..65a4e` sends a second message with **type 10, command `0300`, and the original one-byte request payload**. This follows `r5 - 2 = 1` and payload pointer `r9 + 2`. An unchanged value sends only the ACK. With requests `[01]` and `[00]`, the state echo is exactly `[01]` or `[00]`.

GET `0300` while mode zero is expected to fail its separate permission gate. GET `031b` is allowed into the test task but lacks a matching read handler; GET `1000` is not unconditionally allowed. Those read errors therefore do not contradict the SET route. The parent subsequently observed the unchanged-zero empty ACK live and identified the changed-state type-10 reply. A corrected experiment must accept the state echo, then verify GET `0300 [01]` before sending any side event.
