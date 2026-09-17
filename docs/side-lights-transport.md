# Side-light transport: bounded static findings

2026-09-15. Static examination only; no USB calls, mux writes, vendor-code execution, or firmware changes in this lane. The confirmed bottom-purple state was untouched.

## Result

No atomic raw mux-plus-side-LED USB transaction was recovered. The long `031b` I2C bridge performs one addressed operation on the base bus; it does not use the firmware's mux-aware device wrapper. Short `031b` events `0867`/`0868` do not reach a pause/resume handler in either the concrete system-task switch or its base switch. They therefore are **not established as a way to stop competing I2C activity**.

`CONTROLR` is a real diagnostic controller-message injector, but its allowed targets are system/call/user-interface/button controllers, with no LED-controller target. Its final word is injected as a controller input/value, not called as a function pointer. No supported value that directly sets side brightness or disables background mux activity was proved. Do not treat an arbitrary value or packed RGB word as an LED setter.

## Provenance and address convention

Official P21 firmware `1.1165.71.2094` came from [Poly's public firmware archive](https://swupdate.lens.poly.com/431a/1.1165.71.2094/0/StudioP21_PID431A_V1.1165.71.2094_DFU_PACKAGE.zip). `dfu_image.bin` SHA-256 is `bd3e11161f0440d20dba19a8f01cd5a0b58357ea822c494c5f588adeaf1c52e5`. Disassembly artifacts are `/tmp/p21-main-thumb.elf` and `/tmp/p21-main-thumb.asm`, with APP_MAIN loaded at `0x50000`. Firmware VM address minus `0x4ff80` is the byte offset in the original `dfu_image.bin`.

## Long `031b` I2C cannot bundle two addresses

The label dispatcher at `649b4` passes the I2C body to `63778`, after matching ASCII `I2C` at `64a3e`. Parser `63778..63930` decodes one BE32 operation (`3` read, `4` write), one target address, one register, register-address-length nibble, byte count, and optional timing value. It permits counts `1..49`.

At `637f8..63804`, the parser loads bus global `200021c4`. It constructs a temporary `CI2cDevice` object with vtable `b0fcc`, stores that base-bus object at temporary-object `+20`, and stores the single target address at `+14`. The read call uses vtable slot `18` (`630d0`); the write call uses slot `1c` (`63050`). These methods delegate to base-bus slots `20` and `24` respectively (`630e6..630f8`, `63066..63078`) and wait on the temporary object's completion semaphore. The temporary object is destroyed before the diagnostic request finishes.

The register-length byte's upper nibble becomes one boolean passed to the base operation. The examined code does not turn it into a mux channel or another address. Even if this boolean changes the electrical transfer behavior, there is no second address field or second transfer body to use for a mux-plus-LED sequence.

The firmware's mux-aware wrapper (`CI2CMuxDevice`, RTTI `b3a1c`) and mux selector/cache code are separate. The bridge does not invoke that wrapper or update cached channel global `20003a26`. A host request selecting physical mux `76`, followed by a request to a side chip, has an intervening scheduling window and is not made atomic by the bridge's completion semaphore. This is a structural limitation of the decoded request, not a hardware test result.

## Short `031b`: exact events, no pause established

`64b78..64ba0` handles command-plus-data length three (two command bytes plus one payload byte). A zero byte selects event `0867`; any nonzero byte selects `0868`. It calls `84ff8` with sender task `31`, recipient task `6`, and that event. `84ff8` constructs and posts a regular message; it does not transform the event into an I2C operation.

Task 6's concrete `CSystemTask` message dispatcher is `62450..62d60`. Unknown events go through `62d2a..62d5c` to base dispatcher `533f0`. Neither `0867` nor `0868` has an explicit concrete branch. In the base dispatcher, both values compare below `086a` and above `0866`, fail the explicit `0869` comparison, and reach default `5539e` (`5358c..535a6`). There is no pause/resume operation on this path.

Default `5539e` can look up the message sender and invoke its task callback if that sender appears in the task's correspondent list (`847dc` scans the list). Otherwise it logs the unprocessed-message diagnostic. Thus this lane does **not** assert that the events are universally discarded: it rules out the proposed direct system-task I2C pause handler. A sender-callback side effect would require further proof before using short `031b` as a workaround.

## `CONTROLR`: exact framing and targets

The long-label match at `649e8` uses all eight ASCII bytes `CONTROLR` (string `b1260`) and calls `64734` with the body beginning at command-buffer `+12`, equivalent to payload `+10`. Body fields are three big-endian uint32 words:

| Payload offset | Bytes | Meaning established by parser |
| --- | --- | --- |
| `0..1` | `00 00` | diagnostic prefix |
| `2..9` | `43 4f 4e 54 52 4f 4c 52` | ASCII `CONTROLR` |
| `10..13` | `00 00 00 00` | required zero word; nonzero rejected |
| `14..17` | BE32 | allowed controller ID below |
| `18..21` | BE32 | injected controller input/value |

Transport template (static recipe, **not live validated in this lane**):

```text
de 01 01 10 1c 00 00 00 05 03 1b
00 00 43 4f 4e 54 52 4f 4c 52
00 00 00 00 <controller-id BE32> <value BE32>
<zero padding to 62 bytes>
```

The parser permits exactly `1..5`, `800d`, `800e`, `800f`, `8010`. It loads a four-byte controller-message namespace unit from flash, rather than loading a controller-object pointer:

| Input ID | Namespace unit | Established instantiated target | Construction evidence |
| --- | --- | --- | --- |
| `1` | `00010003` at `bb5dc` | SystemController / `CCordedSystemController` | `6e000..6e006` calls `8cd54`; failure assertion `b5640` names SystemController |
| `2` | `00020004` at `bb5e0` | UserInterfaceController | `6e02e..6e034` calls `8ddc8`; assertion `b5660` |
| `3` | `00030001` at `bb5c4` | UsbCallController | `6dfbe..6dfc4` calls `8db14`; assertion `b5620` |
| `4` | `00040001` at `bb5f8` | unresolved; no corresponding construction recovered | generic core-name routing `58776..587fe` has no name-4 mapping |
| `5` | `00050002` at `bb5f0` | CallArbitrationController | `6df90..6df96` calls `8c400`; assertion `b55f8` |
| `800d` | `800d0005` at `b531c` | UsbButtonController | `6e154..6e15a`, assertion `b5688` |
| `800e` | `800e0005` at `b5320` | MuteButtonController | `6e262..6e268`, assertion `b56fc` |
| `800f` | `800f0005` at `b5318` | VolumeUpButtonController | `6e194..6e19a`, assertion `b56ac` |
| `8010` | `80100005` at `b530c` | VolumeDownButtonController | `6e1fa..6e200`, assertion `b56d4` |

`64710` builds a controller message whose sender unit is `80028000` (flash `bb5e4`, mapped to task 31 by `586ec`), target unit is the selected table word, target unit is also copied into the message data, and the final BE32 input is copied as a data word (`64714..64720`). It calls common posting function `5884c` with dispatch mode `2`; the message is copied and posted through `851fc` and `84fc0`. There is no direct call to an LED vtable here.

The concrete side-light owner is the existing LED controller reached through the indicator/task route documented in `side-lights-firmware.md`. `CONTROLR` offers ordinary higher-level controller inputs that may indirectly change indicators; this lane did not establish a supported input enum leading to the requested side control. It therefore supplies no safe concrete side-setting packet through this route.

## Feasible next step / stop point

Prioritize proving and repairing the existing `0317`/indicator route or the normal `0e34` side-brightness path, because those target the firmware's side-light actor and its mux-aware drivers. If that remains inaccessible, further static work must establish either (a) a controller input enum that reaches that actor, or (b) a host command creating a mux-aware operation. Do not infer either capability from the raw I2C bridge or from short `031b` acknowledgement alone.

## Follow-up: third side-chip address is `68`

The parent subsequently confirmed physical side illumination through native `0317`, but raw verification failed for presumed address `68` (register 0, count 15) on right-side mux mask `02`; `69` and `6a` read successfully. The firmware address evidence does **not** support changing the third address to `67`:

| Side | Third wrapper construction | Address computation | Wrapper global | LED object / chip ID |
| --- | --- | --- | --- | --- |
| Left, selector `13`, mux mask `01` | `6e838` calls `6a528` | `6e814` sets `r3=0`; `6e832` adds `68`, so incoming address is `68` | `2000216c` (`6ebd8`, stored at `6e83e`) | `2000214c`, chip ID 2 (`6eabc..6eaca`) |
| Right, selector `14`, mux mask `02` | `6e8e0` calls `6a528` | `6e8c6` sets `r3=1`; `6e8da` adds `67`, so incoming address is **`68`**, not `67` | `20002160` (`6ebe4`, stored at `6e8e6`) | `200021d0`, chip ID 5 (`6eb04..6eb12`) |

Constructor `6a528` preserves the incoming address register `r3` in `r7` at `6a536`, stores its low byte unchanged at wrapper `+15` (`6a562`), and, when constructing the shared base `CI2cDevice`, stores `r7` in that device's address field `+14` (`6a5b2`). There is no shift or address arithmetic in those stores. Each corresponding `CLedsKtd2061` constructor receives the wrapper as `r1`, chip ID 2 or 5 as `r2`, and output count 12 as `r3`.

This proves the compiled configuration and the side-object mapping. It does not prove that a third physical chip responds on this unit or explain the failed raw read. That failure must remain a live transport/population observation; changing `68` to `67` based on the immediate in `6e8da` would misread the preceding `r3=1` instruction.
