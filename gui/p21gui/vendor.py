"""P21 vendor HID controls: lights, status indicators and the softphone icon.

Port of src/lights.c and src/hid.c from raw libusb control transfers to hidapi,
so the OS HID driver stays attached on every platform. Every report used here is
declared in the device's HID descriptor (evidence/hid-descriptors.json).
"""
import os
import sys
import time

if sys.platform.startswith("linux"):
    import hidraw as hid  # the wheel's `hid` module is libusb-based and would detach usbhid
else:
    import hid

VID, PID = 0x047F, 0x431A
VENDOR_PAGE, TELEPHONY_PAGE = 0xFFA2, 0x0B  # BR/05/06/0d live in ffa2; LED outputs in 0b

SETTINGS = {  # name: (setting id, LED selector, mask)
    "manual": (0x426, 0, 0), "sensor": (0x427, 0, 0),
    "left": (0xE34, 0x13, 0), "right": (0xE34, 0x14, 0), "status": (0xE34, 0x12, 0),
    "idle": (0xE33, 0, 1), "incoming": (0xE33, 0, 2), "active": (0xE33, 0, 4),
    "held": (0xE33, 0, 8), "charging": (0xE33, 0, 32),
}
INDICATORS = {"mute": (0x09, 2), "call": (0x17, 3), "ring": (0x18, 4), "hold": (0x20, 5)}
SOFTPHONES = {"zoom": 22, "teams": 23}
FADE_MS = (31, 63, 125, 250, 500, 1000, 2000, 4000)
CHIPS = (0x69, 0x6A)
MUX = 0x76
LOCK_PATH = f"/tmp/p21ctl-br-{os.getuid()}.lock" if os.name == "posix" else None  # shared with p21ctl

MALFORMED, UNRELATED, REJECTED = "malformed", "unrelated", "rejected"
STOP = object()  # poll() check result: give up early


class P21Error(Exception):
    pass


class BusBusy(P21Error):
    """The shared LED mux is on another channel; nothing was written."""


def br_parse(b, kind, sid):
    """Payload bytes of a BR reply, or MALFORMED/UNRELATED/REJECTED."""
    if len(b) != 62 or b[:4] != b"\xde\x01\x01\x10" or not 6 <= b[4] <= 57 or any(b[5:8]):
        return MALFORMED
    if b[9] != sid >> 8 or b[10] != sid & 255:
        return UNRELATED
    if b[8] in (4, 7):
        return REJECTED
    if b[8] != kind:
        return UNRELATED
    return bytes(b[11:5 + b[4]])


def component(value):
    """RGB 0..255 to the KTD2061's 0..192 current steps."""
    return (value * 192 + 127) // 255


class Session:
    """One exclusive conversation with the vendor HID interface.

    Holds p21ctl's flock so the GUI and CLI never interleave BR requests.
    Poly software must still not issue simultaneous vendor commands.
    """

    def __init__(self):
        self._handles, self._lock = {}, None
        self._last, self._negotiated = None, False

    def __enter__(self):
        if LOCK_PATH:
            import fcntl
            self._lock = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            try:
                fcntl.flock(self._lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                os.close(self._lock)
                raise P21Error("Another p21ctl process is using the P21 vendor controls") from None
        return self

    def __exit__(self, *exc):
        for dev in self._handles.values():
            dev.close()
        if self._lock is not None:
            os.close(self._lock)

    def _dev(self, page):
        # Windows exposes each top-level collection as its own device; elsewhere one handle serves all.
        key = page if sys.platform == "win32" else None
        if key not in self._handles:
            paths = {d["path"] for d in hid.enumerate(VID, PID) if key is None or d["usage_page"] == page}
            if len(paths) != 1:
                raise P21Error(f"Expected one Poly Studio P21 HID interface; found {len(paths)}. Is it connected?")
            dev = hid.device()
            try:
                dev.open_path(paths.pop())
            except OSError as e:
                hint = " (Linux: install the udev rule from gui/linux)" if sys.platform.startswith("linux") else ""
                raise P21Error(f"Cannot open P21 HID interface: {e}{hint}") from None
            self._handles[key] = dev
        return self._handles[key]

    # --- transport -------------------------------------------------------
    fault = None  # shared by all sessions until the user explicitly retries

    def _io(self, what, call):
        """A USB-level failure latches: after a stall, more transfers (even restores) make it worse."""
        if Session.fault:
            raise P21Error(Session.fault)
        try:
            return call()
        except OSError as e:
            Session.fault = (f"{what} failed ({e}). Stopped talking to the P21; any restore is unverified. "
                           "Reconnect or power-cycle the P21 before retrying.")
            raise P21Error(Session.fault) from None

    def _write(self, page, data):
        def write():
            n = self._dev(page).write(bytes(data))
            if n < len(data):  # Windows reports the padded collection length
                raise OSError(n)
        self._io(f"HID output report {data[0]:02x}", write)

    def feature(self, report, size):
        b = bytes(self._io(f"HID feature {report:02x}", lambda: self._dev(VENDOR_PAGE).get_feature_report(report, 63)))
        if len(b) < size or b[0] != report:
            raise P21Error(f"HID feature {report:02x}: invalid response ({len(b)} bytes)")
        return b[:size]

    def br_send(self, kind, sid, data=b""):
        if len(data) > 51:
            raise ValueError("BR payload too long")
        packet = bytes([0xDE, 1, 1, 0x10, 6 + len(data), 0, 0, 0, kind, sid >> 8, sid & 255]) + bytes(data)
        self._last = packet.ljust(62, b"\0")
        self._write(VENDOR_PAGE, self._last)

    def _negotiate(self):
        # BRHostVersionNegotiation (docs/vendor-analysis.md). After power-up or reconnect the firmware
        # ignores BR requests until a host sends it; Poly's background service normally does.
        self._negotiated = True
        self._write(VENDOR_PAGE, bytes([0xDE, 1, 1, 0x10, 7, 0, 0, 0, 1, 1, 2, 0]).ljust(62, b"\0"))
        time.sleep(0.1)

    def poll(self, check, failure, attempts=40):
        """GET_REPORT retains the last reply; poll it until check() returns non-None.

        check(packet) may return STOP to abort early.
        """
        for retry in (False, True):
            for _ in range(attempts):
                time.sleep(0.025)
                b = bytes(self._io("BR read", lambda: self._dev(VENDOR_PAGE).get_input_report(0xDE, 62)))
                result = check(b)
                if result is STOP:
                    raise P21Error(failure)
                if result is not None:
                    return result
            if retry or self._negotiated:
                break
            # Silence usually means no host has negotiated since power-up. Every request here is an
            # absolute GET/SET, so repeating it after negotiating is safe.
            self._negotiate()
            self._write(VENDOR_PAGE, self._last)
        raise P21Error(f"{failure}: the P21 is not answering vendor requests. If p21ctl fails too, power-cycle the P21.")

    # --- stored settings (BR GET/SET) -----------------------------------
    def _raw_get(self, name):
        sid, led, mask = SETTINGS[name]
        self.br_send(2, sid, bytes([led]) if led else b"")

        def check(b):
            p = br_parse(b, 3, sid)
            if p is REJECTED:
                raise P21Error(f"BR setting {sid:04x} rejected, error bytes {b[11]:02x} {b[12]:02x}")
            return None if isinstance(p, str) else p

        p = self.poll(check, f"No matching BR response for {sid:04x}")
        if mask and len(p) == 4:
            return int(bool(p[3] & mask))
        if not led and not mask and len(p) == 1 and p[0] <= 1:
            return p[0]
        # P21 1.1165.71.2094 echoes selector 12 for right-light GETs (requested 14).
        if led and len(p) == 3 and (p[0] == led or (led == 0x14 and p[0] == 0x12)) and p[1] == 0xFF and p[2] <= 100:
            return p[2]
        raise P21Error(f"Invalid {name} response")

    def setting(self, name):
        # A different setting's reply fences stale reads of the retained report.
        self._raw_get("sensor" if name == "manual" else "manual")
        return self._raw_get(name)

    def _setting_write(self, name, value):
        sid, led, mask = SETTINGS[name]
        data = bytes([0, 0, 0, mask if value else 0, 0, 0, 0, mask]) if mask else bytes([led, 0xFF, value]) if led else bytes([value])
        self.br_send(5, sid, data)

        def check(b):
            p = br_parse(b, 6, sid)
            if p is REJECTED:
                raise P21Error(f"BR setting {sid:04x} rejected, error bytes {b[11]:02x} {b[12]:02x}")
            if isinstance(p, str):
                return None
            if p:
                raise P21Error(f"Unexpected {name} acknowledgement")
            return True

        self.poll(check, f"No matching BR response for {sid:04x}")

    def set_setting(self, name, value):
        """Write a stored setting with readback; restores the previous value on mismatch."""
        before = self.setting(name)
        try:
            self._setting_write(name, value)
            actual = self.setting(name)
        except P21Error:
            actual = None
        if actual != value:
            try:
                self._setting_write(name, before)
                restored = self.setting(name) == before
            except P21Error:
                restored = False
            raise P21Error(f"{name} write/readback failed; " + ("previous value restored" if restored else "RESTORATION FAILED, inspect device"))
        return actual

    # --- diagnostic I2C bridge (bottom bar and side chips) ---------------
    def _i2c(self, write, address, reg, data=None, n=0):
        n = len(data) if write else n
        if not 1 <= n <= 15 or address not in (*CHIPS, MUX) or (address == MUX and (write or reg or n != 1)) \
                or reg < 0 or reg + n > 15 or (write and reg < 2):
            raise ValueError("I2C access outside the LED chips")
        p = bytes([0, 0, *b"I2C", 0, 0, 0, 0, 0, 0, 0, 0, 4 if write else 3, address, reg, 0 if address == MUX else 1, n, 0, 0])
        if write:
            p += bytes(data)
        if address == MUX or (not write and n == 1):
            # A different reply fences the retained report; otherwise a stale 1-byte mux reply
            # would pass as a 1-byte chip read.
            self._raw_get("manual")
        self.br_send(5, 0x31B, p)

        def check(b):
            reply = br_parse(b, 6 if write else 10, 0x31B)
            if reply is REJECTED:
                return STOP
            if write and reply == b"\0\1I2\1":
                return True
            if not write and isinstance(reply, bytes) and len(reply) == n + 4 and reply[:4] == b"\0\1I2":
                return reply[4:]
            # A successful write also emits its payload; it may replace the ACK.
            if write and br_parse(b, 10, 0x31B) == p:
                return True
            return None

        return self.poll(check, f"LED bridge failed ({'write' if write else 'read'} {address:02x}:{reg:02x})")

    def _channel(self, expected):
        channel = self._i2c(False, MUX, 0, n=1)[0]
        # Never change the mux behind the firmware's cached channel selection.
        if channel != expected:
            raise BusBusy(f"LED bus is busy (mux={channel:02x}, expected={expected:02x}); retry when idle")

    def _chip_read(self, chip, channel):
        self._channel(channel)
        state = self._i2c(False, CHIPS[chip], 0, n=15)
        self._channel(channel)
        if state[0] != 0xA4:
            raise P21Error("Unexpected LED chip ID")
        return state

    def bar_state(self):
        return [self._chip_read(c, 4) for c in (0, 1)]

    def _bar_write(self, chip, reg, values):
        self._channel(4)
        self._i2c(True, CHIPS[chip], reg, values)
        self._channel(4)
        if self._i2c(False, CHIPS[chip], reg, n=len(values)) != bytes(values):
            raise P21Error(f"Bottom chip{chip + 1} readback mismatch")
        self._channel(4)

    def _bar_apply(self, states, chips=(0, 1), registers=13):
        for c in chips:
            self._bar_write(c, 2, states[c][2:2 + registers])

    def _bar_restore(self, before, chips, registers=13):
        try:
            self._bar_apply(before, chips, registers)
        except P21Error as e:
            raise P21Error(f"Bottom bar restoration FAILED: {e}") from None

    def _bar_activate(self):
        """Return the LED bus to the bottom bar with the firmware's own LED command (port of bar_activate).

        After side-light changes the firmware leaves the mux on a side channel. The native command
        switches it back; the restore baseline then becomes the firmware's dim white.
        """
        if self._i2c(False, MUX, 0, n=1)[0] == 4:
            return
        before = self._gate()
        try:
            if not before:
                self._side_send(0x300, b"\x01")
            if self._gate() != 1:
                raise P21Error("Side-control command gate did not open")
            self._side_send(0x317, bytes([0x12, 8, 10]))
        finally:
            if not before:
                self._side_send(0x300, bytes([before]))
                if self._gate() != before:
                    raise P21Error("Bottom activation command gate restoration FAILED")
        for _ in range(8):
            time.sleep(0.1)
            if self._i2c(False, MUX, 0, n=1)[0] == 4:
                return
        raise P21Error("Bottom channel activation did not apply")

    def bar_rgb(self, r, g, b):
        """Solid colour across both chips; stays until changed or overridden by firmware."""
        self._bar_activate()
        before = self.bar_state()
        after = [bytearray(s) for s in before]
        for s in after:
            s[3:6] = bytes(component(v) for v in (r, g, b))
            s[9:15] = b"\x88" * 6
            s[2] = (s[2] & 0x3F) | 0x80
        self._guarded(before, lambda: self._bar_apply(after))

    def bar_fade(self, index):
        before = self.bar_state()
        after = [bytearray(s) for s in before]
        for s in after:
            s[2] = (s[2] & 0xF8) | index
        self._guarded(before, lambda: self._bar_apply(after, registers=1), registers=1)

    def bar_palette(self, chip, rgb0, rgb1, selectors):
        """chip 0/1; selectors: 12 values from 0 or 8..15 (bit0 blue, bit1 green, bit2 red from palette 1)."""
        if len(selectors) != 12 or any(v not in (0, *range(8, 16)) for v in selectors):
            raise ValueError("selectors must be 12 values from 0, 8..15")
        before = self.bar_state()
        after = [bytearray(s) for s in before]
        s = after[chip]
        s[3:9] = bytes(component(v) for v in (*rgb0, *rgb1))
        s[9:15] = bytes((selectors[i * 2] << 4) | selectors[i * 2 + 1] for i in range(6))
        s[2] = (s[2] & 0x3F) | 0x80
        self._guarded(before, lambda: self._bar_apply(after, (chip,)), (chip,))

    def _guarded(self, before, action, chips=(0, 1), registers=13):
        try:
            action()
        except P21Error as e:
            self._bar_restore(before, chips, registers)
            raise P21Error(f"{e}; previous colours restored") from None

    # --- live side lights -------------------------------------------------
    def _gate(self):
        self._raw_get("manual")
        self.br_send(2, 0x300)

        def check(b):
            p = br_parse(b, 3, 0x300)
            if isinstance(p, bytes) and len(p) == 1 and p[0] <= 1:
                return p[0]
            # Firmware 2094 denies GET0300 with 0012 while its command gate is off.
            if p is REJECTED and b[8] == 4 and b[4] >= 8 and b[11] == 0 and b[12] == 0x12:
                return 0
            return None

        return self.poll(check, "Cannot determine side-control command gate")

    def _side_send(self, sid, data):
        self._raw_get("manual")
        self.br_send(5, sid, data)

        def check(b):
            p = br_parse(b, 6, sid)
            if p == b"":
                return True
            if p is REJECTED:
                return STOP
            if sid == 0x300 and br_parse(b, 10, sid) == bytes(data):
                return True
            return None

        self.poll(check, f"Side command {sid:04x} failed")

    def _side_verify(self, side, percent):
        level = 192 * percent // 100
        # ACK means queued. Verify the two responding chips; firmware also configures
        # address 68, which rejects reads on this unit and is not verified here.
        for _ in range(10):
            time.sleep(0.05)
            ok = True
            for chip in (0, 1):
                s = self._chip_read(chip, 1 << side)
                if percent and any(v != level for v in s[3:9]):
                    ok = False
                if any((v & 0x88) != (0x88 if percent else 0) for v in s[9:15]):
                    ok = False
                if percent and (s[2] & 0xC0) != 0x80:
                    ok = False
            if ok:
                return
        raise P21Error(f"Side light did not reach {percent}%")

    def sides(self, left, right):
        """Live side-light brightness, as you face the screen. Rounds up to 10% steps."""
        if not (0 <= left <= 100 and 0 <= right <= 100):
            raise ValueError("brightness must be 0..100")
        before = self._gate()
        levels = ((left + 9) // 10 * 10, (right + 9) // 10 * 10)
        try:
            self._side_send(0x300, b"\x01")
            if self._gate() != 1:
                raise P21Error("Side-control command gate did not open")
            for side, level in enumerate(levels):
                device_side = 1 - side  # firmware labels face outward
                self._side_send(0x317, bytes([0x13 + device_side, 8, level]))
                self._side_verify(device_side, level)
        finally:
            self._side_send(0x300, bytes([before]))
            if self._gate() != before:
                raise P21Error("Side-control command gate restoration FAILED")
        return levels

    # --- status indicators and softphone icon ----------------------------
    def indicators(self):
        b = self.feature(5, 3)
        return {name: bool(b[1] >> bit & 1) for name, (_, bit) in INDICATORS.items()}

    def set_indicator(self, name, on):
        report, bit = INDICATORS[name]
        previous = self.feature(5, 3)[1] >> bit & 1
        try:
            self._write(TELEPHONY_PAGE, bytes([report, int(on)]))
            ok = (self.feature(5, 3)[1] >> bit & 1) == int(on)
        except P21Error:
            ok = False
        if not ok:
            self._write(TELEPHONY_PAGE, bytes([report, previous]))
            if (self.feature(5, 3)[1] >> bit & 1) != previous:
                raise P21Error(f"RESTORE FAILED: {name} indicator")
            raise P21Error(f"{name} indicator write or readback failed; restored")

    def softphone(self):
        b = self.feature(6, 12)
        value = b[10] | b[11] << 8
        return next((n for n, v in SOFTPHONES.items() if v == value), None), value

    def _icon_write(self, value):
        # Output 0x0d: usage f0 occupies bits 8..23, little endian.
        self._write(VENDOR_PAGE, bytes([0x0D, 0, value & 255, value >> 8]))
        for _ in range(40):  # firmware applies it asynchronously (~25 ms)
            if self.softphone()[1] == value:
                return True
            time.sleep(0.025)
        return False

    def set_softphone(self, name):
        before = self.softphone()[1]
        try:
            ok = self._icon_write(SOFTPHONES[name])
        except P21Error:
            if Session.fault:
                raise
            ok = False
        if not ok:
            if not self._icon_write(before):
                raise P21Error("RESTORE FAILED: softphone icon; inspect device")
            raise P21Error("Softphone icon write or readback failed; restored")

