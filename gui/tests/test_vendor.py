"""Offline checks of the vendor HID protocol against a simulated P21. No hardware needed.

Run: uv run python -m unittest discover tests
"""
import tempfile
import unittest
from unittest import mock

from p21gui import vendor

BAR = bytes.fromhex("a43082131313000000888888888888")


class FakeP21:
    """Enough of firmware 2094's BR channel, I2C bridge and HID reports to exercise the port."""

    def __init__(self):
        self.stored = {0x426: 0, 0x427: 0, 0x12: 100, 0x13: 50, 0x14: 50, 0xE33: 0x2F}
        self.gate, self.mux = 0, 4
        self.chips = {(ch, a): bytearray(BAR) for ch in (1, 2, 4) for a in vendor.CHIPS}
        self.feat5, self.icon = bytearray([5, 2, 0x1E]), 22
        self.reply, self.side_commands, self.negotiated = bytes(62), [], True

    # hid.device API
    def open_path(self, path):
        pass

    def close(self):
        pass

    def write(self, data):
        rid = data[0]
        if rid == 0xDE:
            self._br(data)
        elif rid in (0x09, 0x17, 0x18, 0x20):
            bit = {0x09: 2, 0x17: 3, 0x18: 4, 0x20: 5}[rid]
            self.feat5[1] = (self.feat5[1] & ~(1 << bit)) | (data[1] << bit)
        elif rid == 0x0D:
            self.icon = data[2] | data[3] << 8
        return len(data)

    def get_feature_report(self, rid, size):
        return list(self.feat5) if rid == 5 else [6, 0, 2, 0, 0, 0, 0x5D, 9, 0x98, 0x92, self.icon & 255, self.icon >> 8]

    def get_input_report(self, rid, size):
        return list(self.reply)

    def _answer(self, kind, sid, payload=b""):
        self.reply = bytes([0xDE, 1, 1, 0x10, 6 + len(payload), 0, 0, 0, kind, sid >> 8, sid & 255, *payload]).ljust(62, b"\0")

    def _br(self, d):
        kind, sid, payload = d[8], d[9] << 8 | d[10], bytes(d[11:5 + d[4]])
        if kind == 1:
            self.negotiated = True
            self.reply = bytes.fromhex("de0303042604270429").ljust(62, b"\0")  # multi-chunk metadata reply
        elif not self.negotiated:
            pass  # freshly powered firmware ignores BR requests
        elif kind == 2 and sid in (0x426, 0x427):
            self._answer(3, sid, bytes([self.stored[sid]]))
        elif kind == 2 and sid == 0xE34:
            led = payload[0]
            self._answer(3, sid, bytes([0x12 if led == 0x14 else led, 0xFF, self.stored[led]]))  # firmware echo quirk
        elif kind == 2 and sid == 0xE33:
            self._answer(3, sid, bytes([0, 0, 0, self.stored[0xE33]]))
        elif kind == 2 and sid == 0x300:
            self._answer(3, sid, b"\x01") if self.gate else self._answer(4, sid, b"\x00\x12")
        elif kind == 5 and sid in (0x426, 0x427):
            self.stored[sid] = payload[0]
            self._answer(6, sid)
        elif kind == 5 and sid == 0xE34:
            self.stored[payload[0]] = payload[2]
            self._answer(6, sid)
        elif kind == 5 and sid == 0xE33:
            mask = payload[7]
            self.stored[0xE33] = (self.stored[0xE33] & ~mask) | payload[3]
            self._answer(6, sid)
        elif kind == 5 and sid == 0x300:
            self.gate = payload[0]
            self._answer(6, sid)
        elif kind == 5 and sid == 0x317 and self.gate and payload[0] == 0x12:
            self.mux = 4  # native bottom LED command selects the bottom channel
            self._answer(6, sid)
        elif kind == 5 and sid == 0x317 and self.gate:
            self.side_commands.append(payload)
            side, level = payload[0] - 0x13, payload[2]
            for a in vendor.CHIPS:
                chip = self.chips[(1 << side, a)]
                chip[2], chip[3:9] = 0x82, bytes([192 * level // 100]) * 6
                chip[9:15] = (b"\x88" if level else b"\x00") * 6
            self.mux = 1 << side  # firmware leaves the mux on the side channel
            self._answer(6, sid)
        elif kind == 5 and sid == 0x31B:
            write, address, reg, n = payload[13] == 4, payload[14], payload[15], payload[17]
            if address == vendor.MUX:
                self._answer(10, sid, b"\0\1I2" + bytes([self.mux]))
            elif write:
                self.chips[(self.mux, address)][reg:reg + n] = payload[20:20 + n]
                self._answer(6, sid, b"\0\1I2\1")
            else:
                self._answer(10, sid, b"\0\1I2" + bytes(self.chips[(self.mux, address)][reg:reg + n]))
        else:
            self._answer(7, sid, b"\x00\x01")


class VendorProtocol(unittest.TestCase):
    def setUp(self):
        self.p21 = FakeP21()
        fake_hid = mock.Mock()
        fake_hid.enumerate.return_value = [{"path": b"p21", "usage_page": vendor.VENDOR_PAGE}]
        fake_hid.device.return_value = self.p21
        lock = tempfile.NamedTemporaryFile()
        self.addCleanup(lock.close)
        self.addCleanup(setattr, vendor.Session, "fault", None)
        for patch in (mock.patch.object(vendor, "hid", fake_hid), mock.patch.object(vendor.time, "sleep"),
                      mock.patch.object(vendor, "LOCK_PATH", lock.name), mock.patch.object(vendor.sys, "platform", "darwin")):
            patch.start()
            self.addCleanup(patch.stop)

    def test_br_parse(self):
        self.p21._answer(3, 0x426, b"\x01")
        packet = self.p21.reply
        self.assertEqual(vendor.br_parse(packet, 3, 0x426), b"\x01")
        self.assertIs(vendor.br_parse(packet, 3, 0x427), vendor.UNRELATED)
        self.assertIs(vendor.br_parse(packet, 6, 0x426), vendor.UNRELATED)
        self.assertIs(vendor.br_parse(packet[:61], 3, 0x426), vendor.MALFORMED)
        self.p21._answer(4, 0x426, b"\x00\x12")
        self.assertIs(vendor.br_parse(self.p21.reply, 3, 0x426), vendor.REJECTED)

    def test_colour_maths_matches_c(self):
        self.assertEqual([vendor.component(v) for v in (0, 64, 128, 255)], [0, 48, 96, 192])

    def test_settings_roundtrip(self):
        with vendor.Session() as s:
            self.assertEqual({n: s.setting(n) for n in vendor.SETTINGS},
                             {"manual": 0, "sensor": 0, "left": 50, "right": 50, "status": 100,
                              "idle": 1, "incoming": 1, "active": 1, "held": 1, "charging": 1})
            s.set_setting("right", 70)
            s.set_setting("held", 0)
            self.assertEqual((s.setting("right"), s.setting("held"), s.setting("idle")), (70, 0, 1))

    def test_rgb_and_palette_registers(self):
        with vendor.Session() as s:
            s.bar_rgb(64, 0, 64)
            self.assertEqual(self.p21.chips[(4, 0x69)].hex(), "a43082300030000000888888888888")
            self.assertEqual(self.p21.chips[(4, 0x6A)], self.p21.chips[(4, 0x69)])
            s.bar_palette(1, (255, 0, 0), (0, 0, 255), [8] * 6 + [15] * 6)
            self.assertEqual(self.p21.chips[(4, 0x6A)].hex(), "a43082c000000000c0888888ffffff")
            s.bar_fade(5)
            self.assertEqual(self.p21.chips[(4, 0x69)][2], 0x85)

    def test_negotiates_when_firmware_is_silent(self):
        self.p21.negotiated = False
        with vendor.Session() as s:
            self.assertEqual(s.setting("status"), 100)
            s.set_setting("status", 90)
        self.assertEqual(self.p21.stored[0x12], 90)

    def test_usb_failure_stops_all_transfers(self):
        with vendor.Session() as s:
            s.bar_state()
            calls = []

            def stalled(data):
                calls.append(data)
                raise OSError("timeout")
            self.p21.write = stalled
            with self.assertRaisesRegex(vendor.P21Error, "Stopped talking"):
                s.bar_rgb(255, 0, 0)
            with self.assertRaisesRegex(vendor.P21Error, "Stopped talking"):
                s.indicators()  # no restore or later request reaches the device
        with vendor.Session() as s, self.assertRaisesRegex(vendor.P21Error, "Stopped talking"):
            s.indicators()  # the latch survives into the next session
        self.assertEqual(len(calls), 1)

    def test_busy_mux_refuses_bar_writes(self):
        self.p21.mux = 1
        with vendor.Session() as s, self.assertRaises(vendor.BusBusy):
            s.bar_fade(7)  # only a colour change may switch the bus back
        self.assertEqual(self.p21.chips[(1, 0x69)], bytearray(BAR))

    def test_colour_after_sides_reactivates_bottom_bus(self):
        with vendor.Session() as s:
            s.sides(30, 30)
            with self.assertRaises(vendor.BusBusy):
                s.bar_state()
            s.bar_rgb(64, 0, 64)
            self.assertEqual(s.bar_state()[0][3:6], bytes([48, 0, 48]))
        self.assertEqual(self.p21.gate, 0)

    def test_sides_face_the_screen_and_restore_gate(self):
        with vendor.Session() as s:
            self.assertEqual(s.sides(25, 0), (30, 0))
        self.assertEqual(self.p21.side_commands, [bytes([0x14, 8, 30]), bytes([0x13, 8, 0])])
        self.assertEqual(self.p21.gate, 0)

    def test_indicators_and_softphone(self):
        with vendor.Session() as s:
            s.set_indicator("call", True)
            self.assertEqual(s.indicators(), {"mute": False, "call": True, "ring": False, "hold": False})
            s.set_softphone("teams")
            self.assertEqual(s.softphone(), ("teams", 23))


if __name__ == "__main__":
    unittest.main()
