#!/usr/bin/env python3
# Offline builder for the P21 icon-LCD host-push patch.
# Never touches USB/HID, never flashes, never runs vendor code. It assembles the
# injected Thumb (via clang), splices it + a 4-byte hook into a copy of APP_MAIN,
# fixes both container CRC32s, re-parses to verify, and writes a fresh
# dfu_image.bin. It refuses any input but the documented official image and never
# overwrites an existing output.
import argparse, hashlib, os, struct, subprocess, sys, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ASM = os.path.join(HERE, "icon_patch.s")

INPUT_SHA256 = "bd3e11161f0440d20dba19a8f01cd5a0b58357ea822c494c5f588adeaf1c52e5"
LOAD_BASE = 0x50000
SEC_FILE_OFF = 0x80                 # APP_MAIN bytes start here in the container
def vm_to_file(vm): return vm - LOAD_BASE + SEC_FILE_OFF

INJECT_VM = 0xBF000                 # inside the 47,744 B zero pad (0xbef7f..0xcaa80)
PAD_END_VM = 0xCAA80
HOOK_VM = 0xB0E90                   # 0x031b label jump-table slot idx 13 ('P')
HOOK_ORIG = 0x00064B0E             # stock: default-reply tail
SEC_CRC_OFF = 0x3C                  # APP_MAIN section CRC32 (little-endian)
HDR_CRC_OFF = 0x1C                  # header CRC32 over bytes[0x20:end]


def assemble_blob():
    """clang-assemble icon_patch.s and return its .text bytes (stdlib ELF parse)."""
    obj = os.path.join(HERE, "icon_patch.o")
    subprocess.run(["clang", "--target=thumbv6m-none-eabi", "-mcpu=cortex-m0",
                    "-c", ASM, "-o", obj], check=True)
    try:
        e = open(obj, "rb").read()
    finally:
        os.remove(obj)
    assert e[:4] == b"\x7fELF" and e[4] == 1 and e[5] == 1, "expected little-endian ELF32"
    e_shoff, = struct.unpack_from("<I", e, 0x20)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", e, 0x2E)
    def sh(i): return struct.unpack_from("<IIIIIIIIII", e, e_shoff + i * e_shentsize)
    stroff = sh(e_shstrndx)[4]
    blob = None
    for i in range(e_shnum):
        name_i, _typ, _fl, _ad, off, size, *_ = sh(i)
        name = e[stroff + name_i: e.index(b"\0", stroff + name_i)].decode()
        if name == ".text":
            blob = e[off:off + size]
    assert blob is not None, ".text section not found"
    return blob


def expect(cond, msg):
    if not cond:
        sys.exit("build_patch: " + msg)


def main():
    ap = argparse.ArgumentParser(description="Build the P21 icon-LCD push patch (offline).")
    ap.add_argument("input", help="official dfu_image.bin")
    ap.add_argument("--output-dir", required=True, help="fresh dir for dfu_image.bin (must not exist)")
    args = ap.parse_args()

    img = bytearray(open(args.input, "rb").read())
    got = hashlib.sha256(img).hexdigest()
    expect(got == INPUT_SHA256, f"input SHA-256 mismatch: {got}")
    expect(img[:8] == b"FIRMWARE" and img[0x20:0x28] == b"APP_MAIN", "not a FIRMWARE/APP_MAIN container")

    sec_off, sec_len = struct.unpack_from("<II", img, 0x34)
    expect(sec_off == SEC_FILE_OFF, f"unexpected APP_MAIN offset {sec_off:#x}")
    expect(struct.unpack_from("<I", img, SEC_CRC_OFF)[0] == zlib.crc32(img[sec_off:sec_off + sec_len]) & 0xffffffff,
           "stored section CRC does not match input (unexpected image)")
    expect(struct.unpack_from("<I", img, HDR_CRC_OFF)[0] == zlib.crc32(img[0x20:]) & 0xffffffff,
           "stored header CRC does not match input (unexpected image)")

    blob = assemble_blob()
    expect(INJECT_VM + len(blob) <= PAD_END_VM, "injected code overruns the zero pad")

    # --- assert every byte we overwrite has its expected original content ---
    inj_fo = vm_to_file(INJECT_VM)
    expect(all(b == 0 for b in img[inj_fo:inj_fo + len(blob)]),
           "injection region is not the expected zero padding")
    hook_fo = vm_to_file(HOOK_VM)
    expect(struct.unpack_from("<I", img, hook_fo)[0] == HOOK_ORIG,
           f"hook word is not the expected stock value {HOOK_ORIG:#x}")

    # --- apply: inject code, repoint the one jump-table word ---
    img[inj_fo:inj_fo + len(blob)] = blob
    struct.pack_into("<I", img, hook_fo, INJECT_VM)

    # --- fix section CRC first, then the header CRC that covers it ---
    struct.pack_into("<I", img, SEC_CRC_OFF, zlib.crc32(img[sec_off:sec_off + sec_len]) & 0xffffffff)
    struct.pack_into("<I", img, HDR_CRC_OFF, zlib.crc32(img[0x20:]) & 0xffffffff)

    # --- re-parse the finished bytes and re-verify both CRCs ---
    expect(struct.unpack_from("<I", img, SEC_CRC_OFF)[0] == zlib.crc32(img[sec_off:sec_off + sec_len]) & 0xffffffff,
           "section CRC re-verify failed")
    expect(struct.unpack_from("<I", img, HDR_CRC_OFF)[0] == zlib.crc32(img[0x20:]) & 0xffffffff,
           "header CRC re-verify failed")
    expect(len(img) == os.path.getsize(args.input), "output length changed")

    try:
        os.makedirs(args.output_dir)  # never overwrite an existing output
    except FileExistsError:
        sys.exit(f"build_patch: output dir already exists: {args.output_dir}")
    out = os.path.join(args.output_dir, "dfu_image.bin")
    with open(out, "xb") as f:
        f.write(img)

    print(f"injected {len(blob)} B at {INJECT_VM:#x} (file {inj_fo:#x})")
    print(f"hook @ {HOOK_VM:#x} (file {hook_fo:#x}): {HOOK_ORIG:#x} -> {INJECT_VM:#x}")
    print(f"section CRC32 @0x3c -> {struct.unpack_from('<I', img, SEC_CRC_OFF)[0]:#010x}")
    print(f"header  CRC32 @0x1c -> {struct.unpack_from('<I', img, HDR_CRC_OFF)[0]:#010x}")
    print(f"output SHA-256: {hashlib.sha256(img).hexdigest()}")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
