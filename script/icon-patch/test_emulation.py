#!/usr/bin/env python3
# Offline unicorn emulation of the patched 0x031b path. Runs the *real* firmware
# label dispatcher (from 0x649b4) so routing, my_dispatch, and my_handler all
# execute against the actual patched bytes; firmware callees (malloc/memcpy/draw)
# and the stock I2C handler are hooked and recorded. No device, no vendor code run
# on hardware. Usage: python3 test_emulation.py [official dfu_image.bin]
import os, struct, subprocess, sys, tempfile, zlib
from unicorn import *
from unicorn.arm_const import *

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_IMG = "/tmp/p21-official-firmware-static/dfu_image.bin"

# firmware addresses
ENTRY, STOP = 0x649B4, 0x64B0E          # 0x031b label dispatch entry / reply tail
MALLOC, MEMCPY, DRAW, I2C = 0x84C40, 0xA8520, 0x69684, 0x63778
STATE, DISPPTR = 0x20001200, 0x20002170
MAGIC = 0x42313250

# emulation scratch (all inside the 64 KB RAM map)
SP0, PAY, TASK, DISP, HEAP0 = 0x2000F000, 0x2000A000, 0x20002500, 0x20002400, 0x20008000
FLASH_BASE = 0x50000


def load_app_main(img_path):
    subprocess.run([sys.executable, os.path.join(HERE, "build_patch.py"), img_path,
                    "--output-dir", load_app_main.tmp], check=True,
                   stdout=subprocess.DEVNULL)
    c = open(os.path.join(load_app_main.tmp, "dfu_image.bin"), "rb").read()
    off, length = struct.unpack_from("<II", c, 0x34)
    return c[off:off + length]


class Emu:
    def __init__(self, code):
        self.uc = uc = Uc(UC_ARCH_ARM, UC_MODE_THUMB)
        fsz = (len(code) + 0xFFF) & ~0xFFF
        uc.mem_map(FLASH_BASE, fsz)
        uc.mem_write(FLASH_BASE, code)
        uc.mem_map(0x20000000, 0x10000)
        uc.hook_add(UC_HOOK_CODE, self._hook)
        self.reset()

    def reset(self):
        uc = self.uc
        uc.mem_write(0x20000000, b"\0" * 0x10000)
        uc.mem_write(DISPPTR, struct.pack("<I", DISP))   # non-null display object
        self.heap = HEAP0
        self.calls = {"malloc": [], "memcpy": [], "draw": [], "i2c": []}

    def _ret(self):
        # Return to caller. Keep the Thumb (T) bit set explicitly — redirecting PC
        # from inside a code hook otherwise lets unicorn drop back to ARM state.
        self.uc.reg_write(UC_ARM_REG_PC, self.uc.reg_read(UC_ARM_REG_LR) & ~1)
        self.uc.reg_write(UC_ARM_REG_CPSR, self.uc.reg_read(UC_ARM_REG_CPSR) | 0x20)

    def _u32(self, a):
        return struct.unpack("<I", self.uc.mem_read(a, 4))[0]

    def _hook(self, uc, address, size, user):
        if address == STOP:
            uc.emu_stop(); return
        if address == MALLOC:
            n = uc.reg_read(UC_ARM_REG_R0)
            p = self.heap; self.heap = (self.heap + n + 7) & ~7
            uc.mem_write(p, b"\0" * n); uc.reg_write(UC_ARM_REG_R0, p)
            self.calls["malloc"].append((n, p)); self._ret(); return
        if address == MEMCPY:
            d, s, n = (uc.reg_read(r) for r in (UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2))
            uc.mem_write(d, bytes(uc.mem_read(s, n)))
            self.calls["memcpy"].append((d, s, n)); self._ret(); return
        if address == DRAW:
            this, x, y, w = (uc.reg_read(r) for r in (UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3))
            sp = uc.reg_read(UC_ARM_REG_SP)
            h, pix = self._u32(sp), self._u32(sp + 4)
            self.calls["draw"].append(dict(this=this, x=x, y=y, w=w, h=h, pix=pix,
                                           data=bytes(uc.mem_read(pix, w * h * 2))))
            uc.reg_write(UC_ARM_REG_R0, 0); self._ret(); return
        if address == I2C:
            self.calls["i2c"].append(uc.reg_read(UC_ARM_REG_R1))
            uc.reg_write(UC_ARM_REG_R0, 0); self._ret(); return

    def dispatch(self, label, body):
        """Run one BR 0x031b message through the real dispatcher. Returns result dict."""
        uc = self.uc
        payload = b"\x03\x1b\x00\x00" + label.encode().ljust(8, b"\0") + bytes(body)
        uc.mem_write(PAY, payload.ljust(0x40, b"\0"))
        uc.mem_write(SP0 - 0x40, b"\0" * 0x80)          # clear the dispatcher frame
        uc.reg_write(UC_ARM_REG_SP, SP0)
        uc.reg_write(UC_ARM_REG_R9, PAY)
        uc.reg_write(UC_ARM_REG_R5, len(payload))       # payload length (!=3 -> label path)
        uc.reg_write(UC_ARM_REG_R7, TASK)
        self.calls = {"malloc": [], "memcpy": [], "draw": [], "i2c": []}
        uc.emu_start(ENTRY | 1, STOP, count=20000)   # odd address selects Thumb
        return {
            "status": struct.unpack("<H", uc.mem_read(SP0 + 0x34, 2))[0],
            "datap": self._u32(SP0 + 0x1C),
            "count": struct.unpack("<H", uc.mem_read(SP0 + 0x2E, 2))[0],
            "calls": {k: list(v) for k, v in self.calls.items()},
        }

    # state accessors
    def st_magic(self): return self._u32(STATE)
    def st_buf(self): return self._u32(STATE + 4)
    def st_geo(self):
        w, h = struct.unpack("<HH", self.uc.mem_read(STATE + 8, 4))
        x, y = self.uc.mem_read(STATE + 0xC, 2)
        return x, y, w, h


PASS = FAIL = 0
def check(cond, msg):
    global PASS, FAIL
    if cond: PASS += 1
    else: FAIL += 1; print("  FAIL:", msg)


def main():
    img = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_IMG
    with tempfile.TemporaryDirectory() as td:
        load_app_main.tmp = os.path.join(td, "o")
        code = load_app_main(img)
    e = Emu(code)

    # ---------- happy path: Begin -> Data -> Data -> Show -> Query ----------
    print("[scenario] begin/data/show/query")
    r = e.dispatch("PLCD", b"B" + bytes([54, 9, 60, 60]))      # x,y,w,h
    check(r["status"] == 0, "Begin status 0")
    check(e.st_magic() == MAGIC, "Begin sets magic")
    check(e.st_geo() == (54, 9, 60, 60), f"Begin geometry {e.st_geo()}")
    check(e.st_buf() != 0, "Begin allocated framebuffer")
    check(len(r["calls"]["malloc"]) == 1 and r["calls"]["malloc"][0][0] == 7200, "Begin malloc(7200)")
    check(not r["calls"]["draw"], "Begin does not draw")
    buf = e.st_buf()

    pat0 = bytes(range(0, 32))                                  # 16 px at offset 0
    r = e.dispatch("PLCD", b"D" + struct.pack("<H", 0) + bytes([len(pat0)]) + pat0)
    check(r["status"] == 0, "Data#1 status 0")
    check(bytes(e.uc.mem_read(buf, 32)) == pat0, "Data#1 landed at offset 0")

    pat1 = bytes([0xAA, 0x55]) * 10                             # 20 bytes at offset 100
    r = e.dispatch("PLCD", b"D" + struct.pack("<H", 100) + bytes([len(pat1)]) + pat1)
    check(r["status"] == 0, "Data#2 status 0")
    check(bytes(e.uc.mem_read(buf + 100, 20)) == pat1, "Data#2 landed at offset 100")
    check(e.st_buf() == buf, "framebuffer pointer stable across Data")

    r = e.dispatch("PLCD", b"S")
    check(r["status"] == 0, "Show status 0")
    check(len(r["calls"]["draw"]) == 1, "Show draws once")
    d = r["calls"]["draw"][0] if r["calls"]["draw"] else {}
    check(d.get("this") == DISP, "draw this = *0x20002170")
    check((d.get("x"), d.get("y"), d.get("w"), d.get("h")) == (54, 9, 60, 60), "draw rect")
    check(d.get("pix") == buf, "draw pix = framebuffer")
    check(d.get("data", b"")[:32] == pat0, "draw streamed our pixels")

    r2 = e.dispatch("PLCD", b"S")                               # repeated Show redraws
    check(r2["status"] == 0 and len(r2["calls"]["draw"]) == 1, "repeated Show redraws unconditionally")

    r = e.dispatch("PLCD", b"Q")
    check(r["status"] == 0, "Query status 0")
    check(r["count"] == 8 and r["datap"] != 0, "Query returns 8-byte data reply")
    check(bytes(e.uc.mem_read(r["datap"], 8)) == b"P21LCDv1", "Query magic = P21LCDv1")

    # ---------- bounds / malformed rejections (fresh state each) ----------
    print("[scenario] rejections")
    e.reset()
    r = e.dispatch("PLCD", b"B" + bytes([0, 0, 100, 100]))     # 100*100*2 = 20000 > 7200
    check(r["status"] == 1 and e.st_magic() != MAGIC and not r["calls"]["malloc"], "reject Begin too large")

    e.reset()
    r = e.dispatch("PLCD", b"B" + bytes([120, 0, 60, 60]))     # x+w = 180 > 160
    check(r["status"] == 1 and e.st_magic() != MAGIC, "reject Begin rect off-panel (x)")
    r = e.dispatch("PLCD", b"B" + bytes([0, 40, 60, 60]))      # y+h = 100 > 82
    check(r["status"] == 1, "reject Begin rect off-panel (y)")
    r = e.dispatch("PLCD", b"B" + bytes([0, 0, 0, 60]))        # w = 0
    check(r["status"] == 1, "reject Begin w=0")

    e.reset()                                                  # Data/Show before Begin
    r = e.dispatch("PLCD", b"D" + struct.pack("<H", 0) + b"\x04" + b"\1\2\3\4")
    check(r["status"] == 1 and not r["calls"]["memcpy"], "reject Data before Begin")
    r = e.dispatch("PLCD", b"S")
    check(r["status"] == 1 and not r["calls"]["draw"], "reject Show before Begin")

    e.reset()                                                  # valid Begin, then bad Data
    e.dispatch("PLCD", b"B" + bytes([0, 0, 60, 60]))           # buffer = 7200
    buf = e.st_buf(); before = bytes(e.uc.mem_read(buf, 7200))
    r = e.dispatch("PLCD", b"D" + struct.pack("<H", 7190) + b"\x20" + b"\xFF" * 0x20)  # 7190+32 > 7200
    check(r["status"] == 1 and not r["calls"]["memcpy"], "reject Data offset+len past buffer")
    r = e.dispatch("PLCD", b"D" + struct.pack("<H", 0) + b"\x26" + b"\x11" * 0x26)     # len 38 > 37
    check(r["status"] == 1 and not r["calls"]["memcpy"], "reject Data len>37")
    check(bytes(e.uc.mem_read(buf, 7200)) == before, "framebuffer untouched by rejected Data")

    r = e.dispatch("PLCD", b"Z")                               # unknown op
    check(r["status"] == 1, "reject unknown op")

    r = e.dispatch("PLCX", b"B" + bytes([0, 0, 8, 8]))         # wrong label -> stock default reply
    check(r["status"] == 0 and not r["calls"]["draw"] and e.st_magic() == MAGIC,
          "non-PLCD 'P' label falls through to default reply (no handler run)")
    # (status 0 here is the pre-existing default-reply behaviour; our handler never ran:
    #  magic is unchanged from the earlier valid Begin, no malloc/draw happened.)
    check(not r["calls"]["malloc"], "wrong label runs no handler")

    # ---------- stock 0x031b I2C still routes identically ----------
    print("[scenario] stock I2C routing intact")
    e.reset()
    r = e.dispatch("I2C", b"\0\0\0\3\x69\x03\x01\x03\0\0")     # an I2C-shaped body
    check(len(r["calls"]["i2c"]) == 1, "I2C label routes to stock handler 0x63778")
    check(not r["calls"]["draw"] and not r["calls"]["malloc"], "I2C path does not touch our code")

    print(f"\n{PASS} passed, {FAIL} failed")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
