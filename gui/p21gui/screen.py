"""P21 display mode selection. The video path is DisplayLink on every OS.

macOS: CoreGraphics (port of src/screen.c). Linux: xrandr (X11 only; needs the evdi
DisplayLink driver). Windows: Win32 display settings. The P21 is found by its EDID
identity: manufacturer PLY (0x4199), product 1.
Changes last for the session; the OS restores its saved mode on the next login/reboot.
"""
import ctypes
import re
import subprocess
import sys

from .vendor import P21Error


def open_screen():
    if sys.platform == "darwin":
        return Quartz()
    if sys.platform.startswith("linux"):
        return Xrandr()
    if sys.platform == "win32":
        return Win32Display()
    raise P21Error(f"Unsupported platform {sys.platform}")


# --- macOS ------------------------------------------------------------------------
class Quartz:
    def __init__(self):
        c = ctypes
        cg = self.cg = c.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        cf = self.cf = c.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        for fn, res, args in [
            ("CGGetOnlineDisplayList", c.c_int32, [c.c_uint32, c.POINTER(c.c_uint32), c.POINTER(c.c_uint32)]),
            ("CGDisplayVendorNumber", c.c_uint32, [c.c_uint32]), ("CGDisplayModelNumber", c.c_uint32, [c.c_uint32]),
            ("CGDisplayCopyDisplayMode", c.c_void_p, [c.c_uint32]),
            ("CGDisplayCopyAllDisplayModes", c.c_void_p, [c.c_uint32, c.c_void_p]),
            ("CGDisplayModeGetWidth", c.c_size_t, [c.c_void_p]), ("CGDisplayModeGetHeight", c.c_size_t, [c.c_void_p]),
            ("CGDisplayModeGetPixelWidth", c.c_size_t, [c.c_void_p]), ("CGDisplayModeGetPixelHeight", c.c_size_t, [c.c_void_p]),
            ("CGDisplayModeGetRefreshRate", c.c_double, [c.c_void_p]), ("CGDisplayModeGetIODisplayModeID", c.c_int32, [c.c_void_p]),
            ("CGDisplayModeRelease", None, [c.c_void_p]),
            ("CGBeginDisplayConfiguration", c.c_int32, [c.POINTER(c.c_void_p)]),
            ("CGConfigureDisplayWithDisplayMode", c.c_int32, [c.c_void_p, c.c_uint32, c.c_void_p, c.c_void_p]),
            ("CGCompleteDisplayConfiguration", c.c_int32, [c.c_void_p, c.c_uint32]),
            ("CGCancelDisplayConfiguration", c.c_int32, [c.c_void_p]),
        ]:
            getattr(cg, fn).restype, getattr(cg, fn).argtypes = res, args
        cf.CFArrayGetCount.restype, cf.CFArrayGetCount.argtypes = c.c_long, [c.c_void_p]
        cf.CFArrayGetValueAtIndex.restype, cf.CFArrayGetValueAtIndex.argtypes = c.c_void_p, [c.c_void_p, c.c_long]
        cf.CFRelease.argtypes = [c.c_void_p]

    def close(self):
        pass

    def _display(self):
        ids, count = (ctypes.c_uint32 * 32)(), ctypes.c_uint32()
        if self.cg.CGGetOnlineDisplayList(32, ids, ctypes.byref(count)):
            raise P21Error("Display enumeration failed")
        found = [d for d in ids[:count.value] if self.cg.CGDisplayVendorNumber(d) == 0x4199 and self.cg.CGDisplayModelNumber(d) == 1]
        if len(found) != 1:
            raise P21Error(f"Expected one P21 display; found {len(found)}. Is DisplayLink Manager running?")
        return found[0]

    def _describe(self, m):
        g = self.cg
        w, h = g.CGDisplayModeGetWidth(m), g.CGDisplayModeGetHeight(m)
        pw, ph = g.CGDisplayModeGetPixelWidth(m), g.CGDisplayModeGetPixelHeight(m)
        text = f"{w}×{h}" + (f" (HiDPI {pw}×{ph})" if (pw, ph) != (w, h) else "")
        rate = g.CGDisplayModeGetRefreshRate(m)
        return g.CGDisplayModeGetIODisplayModeID(m), text + (f" @ {rate:.0f} Hz" if rate else "")

    def _current(self, display):
        m = self.cg.CGDisplayCopyDisplayMode(display)
        if not m:
            raise P21Error("Cannot read current display mode")
        return m

    def modes(self):
        """([(id, description)], current id)"""
        display = self._display()
        m = self._current(display)
        current = self._describe(m)[0]
        self.cg.CGDisplayModeRelease(m)
        array = self.cg.CGDisplayCopyAllDisplayModes(display, None)
        if not array:
            raise P21Error("No display modes available")
        modes = [self._describe(self.cf.CFArrayGetValueAtIndex(array, i)) for i in range(self.cf.CFArrayGetCount(array))]
        self.cf.CFRelease(array)
        return modes, current

    def _apply(self, display, mode):
        config = ctypes.c_void_p()
        error = self.cg.CGBeginDisplayConfiguration(ctypes.byref(config))
        if not error:
            error = self.cg.CGConfigureDisplayWithDisplayMode(config, display, mode, None)
            if error:
                self.cg.CGCancelDisplayConfiguration(config)
            else:
                error = self.cg.CGCompleteDisplayConfiguration(config, 1)  # kCGConfigureForSession
        return error

    def apply(self, mode_id):
        display = self._display()
        array = self.cg.CGDisplayCopyAllDisplayModes(display, None)
        if not array:
            raise P21Error("No display modes available")
        before = self._current(display)
        try:
            found = [self.cf.CFArrayGetValueAtIndex(array, i) for i in range(self.cf.CFArrayGetCount(array))]
            found = [m for m in found if self.cg.CGDisplayModeGetIODisplayModeID(m) == mode_id]
            if not found:
                raise P21Error("Mode is no longer available")
            error = self._apply(display, found[0])
            actual = self._current(display)
            ok = not error and self.cg.CGDisplayModeGetIODisplayModeID(actual) == mode_id
            self.cg.CGDisplayModeRelease(actual)
            if not ok:
                restored = not self._apply(display, before)
                raise P21Error(f"Display mode change failed ({error}); " + ("restored" if restored else "RESTORE FAILED"))
        finally:
            self.cg.CGDisplayModeRelease(before)
            self.cf.CFRelease(array)


# --- Linux ----------------------------------------------------------------------
class Xrandr:
    def close(self):
        pass

    def _xrandr(self, *args):
        try:
            r = subprocess.run(["xrandr", *args], capture_output=True, text=True, timeout=15)
        except FileNotFoundError:
            raise P21Error("xrandr not found (install x11-xserver-utils)") from None
        if r.returncode:
            raise P21Error(f"xrandr: {r.stderr.strip() or 'failed'} (Wayland sessions are not supported)")
        return r.stdout

    def _output(self):
        """(output name, [(mode id, description)], current mode id) for the output whose EDID is the P21's."""
        found = []
        for block in re.split(r"\n(?=\S)", self._xrandr("--verbose")):
            head = re.match(r"(\S+) connected", block)
            edid = re.search(r"EDID:\s*\n((?:\s+[0-9a-f]{32}\n?)+)", block)
            if not head or not edid:
                continue
            raw = bytes.fromhex("".join(edid.group(1).split()))
            if raw[8:10] != b"\x41\x99" or raw[10:12] != b"\x01\x00":
                continue
            modes, current = [], None
            for line in block.splitlines():
                if m := re.match(r"\s+(\d+x\d+\S*) \((0x[0-9a-f]+)\)", line):
                    modes.append([int(m.group(2), 16), m.group(1).replace("x", "×")])
                    if "*current" in line:
                        current = modes[-1][0]
                elif (m := re.match(r"\s+v:.*clock\s+([\d.]+)Hz", line)) and modes:
                    modes[-1][1] += f" @ {float(m.group(1)):.0f} Hz"
            modes = [tuple(m) for m in modes]
            found.append((head.group(1), modes, current))
        if len(found) != 1:
            raise P21Error(f"Expected one P21 output in xrandr; found {len(found)}. Is the DisplayLink (evdi) driver installed?")
        return found[0]

    def modes(self):
        return self._output()[1:]

    def apply(self, mode_id):
        name, _, before = self._output()
        self._xrandr("--output", name, "--mode", hex(mode_id))
        if self._output()[2] != mode_id:
            if before is not None:
                self._xrandr("--output", name, "--mode", hex(before))
            raise P21Error("Display mode readback mismatch; restored")


# --- Windows --------------------------------------------------------------------
class _DisplayDevice(ctypes.Structure):
    _fields_ = [("cb", ctypes.c_uint32), ("DeviceName", ctypes.c_wchar * 32), ("DeviceString", ctypes.c_wchar * 128),
                ("StateFlags", ctypes.c_uint32), ("DeviceID", ctypes.c_wchar * 128), ("DeviceKey", ctypes.c_wchar * 128)]


class _DevMode(ctypes.Structure):
    _fields_ = [("dmDeviceName", ctypes.c_wchar * 32), ("dmSpecVersion", ctypes.c_uint16), ("dmDriverVersion", ctypes.c_uint16),
                ("dmSize", ctypes.c_uint16), ("dmDriverExtra", ctypes.c_uint16), ("dmFields", ctypes.c_uint32),
                ("dmPosition", ctypes.c_byte * 16), ("dmColor", ctypes.c_short), ("dmDuplex", ctypes.c_short),
                ("dmYResolution", ctypes.c_short), ("dmTTOption", ctypes.c_short), ("dmCollate", ctypes.c_short),
                ("dmFormName", ctypes.c_wchar * 32), ("dmLogPixels", ctypes.c_uint16), ("dmBitsPerPel", ctypes.c_uint32),
                ("dmPelsWidth", ctypes.c_uint32), ("dmPelsHeight", ctypes.c_uint32), ("dmDisplayFlags", ctypes.c_uint32),
                ("dmDisplayFrequency", ctypes.c_uint32), ("dmICMMethod", ctypes.c_uint32), ("dmICMIntent", ctypes.c_uint32),
                ("dmMediaType", ctypes.c_uint32), ("dmDitherType", ctypes.c_uint32), ("dmReserved1", ctypes.c_uint32),
                ("dmReserved2", ctypes.c_uint32), ("dmPanningWidth", ctypes.c_uint32), ("dmPanningHeight", ctypes.c_uint32)]


ENUM_CURRENT_SETTINGS = 0xFFFFFFFF
DM_BITSPERPEL, DM_PELSWIDTH, DM_PELSHEIGHT, DM_DISPLAYFREQUENCY = 0x40000, 0x80000, 0x100000, 0x400000


class Win32Display:
    def __init__(self):
        self.user32 = ctypes.WinDLL("user32")

    def close(self):
        pass

    def _adapter(self):
        found, i = [], 0
        while True:
            adapter = _DisplayDevice(cb=ctypes.sizeof(_DisplayDevice))
            if not self.user32.EnumDisplayDevicesW(None, i, ctypes.byref(adapter), 0):
                break
            monitor = _DisplayDevice(cb=ctypes.sizeof(_DisplayDevice))
            j = 0
            while self.user32.EnumDisplayDevicesW(adapter.DeviceName, j, ctypes.byref(monitor), 0):
                if "PLY0001" in monitor.DeviceID.upper():  # MONITOR\PLY0001\{...}
                    found.append(adapter.DeviceName)
                j += 1
            i += 1
        if len(found) != 1:
            raise P21Error(f"Expected one P21 display; found {len(found)}. Is the DisplayLink driver installed?")
        return found[0]

    def _mode(self, name, index):
        dm = _DevMode(dmSize=ctypes.sizeof(_DevMode))
        if not self.user32.EnumDisplaySettingsW(name, ctypes.c_uint32(index), ctypes.byref(dm)):
            return None
        return dm

    @staticmethod
    def _key(dm):
        return dm.dmPelsWidth, dm.dmPelsHeight, dm.dmDisplayFrequency, dm.dmBitsPerPel

    def _all(self, name):
        modes, i = {}, 0
        while (dm := self._mode(name, i)) is not None:
            modes.setdefault(self._key(dm), dm)
            i += 1
        return list(modes.items())

    def modes(self):
        name = self._adapter()
        modes = self._all(name)
        current = self._key(self._mode(name, ENUM_CURRENT_SETTINGS))
        described = [(i, f"{w}×{h} @ {hz} Hz, {bpp}-bit") for i, ((w, h, hz, bpp), _) in enumerate(modes)]
        return described, next((i for i, (k, _) in enumerate(modes) if k == current), None)

    def _set(self, name, dm):
        dm.dmFields = DM_BITSPERPEL | DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY
        return self.user32.ChangeDisplaySettingsExW(name, ctypes.byref(dm), None, 0, None)  # dynamic, not saved

    def apply(self, mode_id):
        name = self._adapter()
        before = self._mode(name, ENUM_CURRENT_SETTINGS)
        key, dm = self._all(name)[mode_id]
        status = self._set(name, dm)
        if status or self._key(self._mode(name, ENUM_CURRENT_SETTINGS)) != key:
            restored = not self._set(name, before)
            raise P21Error(f"Display mode change failed ({status}); " + ("restored" if restored else "RESTORE FAILED"))
