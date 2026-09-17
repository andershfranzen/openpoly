"""P21 webcam image controls with one native backend per OS.

macOS: UVC requests over libusb (port of src/camera.c; no interface claim).
Linux: V4L2 controls (uvcvideo keeps the device). Windows: DirectShow.
Each backend reports controls in its own native units.
"""
import ctypes
import sys
from dataclasses import dataclass, field

from .vendor import P21Error

VID, PID = 0x095D, 0x9298


@dataclass
class Control:
    name: str
    label: str
    kind: str  # "range" | "bool" | "menu"
    value: int
    min: int = 0
    max: int = 1
    step: int = 1
    default: int | None = None
    options: dict = field(default_factory=dict)  # menu: value -> label
    enabled: bool = True  # writable and not overridden by an automatic mode
    unit: str = ""


LABELS = {
    "auto-exposure": "Auto exposure", "exposure-priority": "Exposure priority (may lower frame rate)",
    "exposure": "Exposure", "zoom": "Zoom", "pan": "Pan", "tilt": "Tilt", "privacy": "Privacy (software)",
    "backlight": "Backlight compensation", "brightness": "Brightness", "contrast": "Contrast", "gain": "Gain",
    "power-line": "Power-line frequency", "hue": "Hue", "saturation": "Saturation", "sharpness": "Sharpness",
    "gamma": "Gamma", "auto-white-balance": "Auto white balance", "white-balance": "White balance",
}
POWER_LINE = {0: "Disabled", 1: "50 Hz", 2: "60 Hz"}


def open_camera():
    if sys.platform == "darwin":
        return UvcCamera()
    if sys.platform.startswith("linux"):
        return V4l2Camera()
    if sys.platform == "win32":
        return DirectShowCamera()
    raise P21Error(f"Unsupported platform {sys.platform}")


# --- macOS: UVC over libusb ---------------------------------------------------
# name: (unit, selector, byte width, signed); pan/tilt share selector 13 (two int32).
UVC = {
    "auto-exposure": (1, 2, 1, 0), "exposure-priority": (1, 3, 1, 0), "exposure": (1, 4, 4, 0),
    "zoom": (1, 11, 2, 0), "pan": (1, 13, 4, 1), "tilt": (1, 13, 4, 1), "privacy": (1, 17, 1, 0),
    "backlight": (3, 1, 2, 0), "brightness": (3, 2, 2, 1), "contrast": (3, 3, 2, 0), "gain": (3, 4, 2, 0),
    "power-line": (3, 5, 1, 0), "hue": (3, 6, 2, 1), "saturation": (3, 7, 2, 0), "sharpness": (3, 8, 2, 0),
    "gamma": (3, 9, 2, 0), "auto-white-balance": (3, 11, 1, 0), "white-balance": (3, 10, 2, 0),
}
UVC_UNITS = {"exposure": "×100 µs", "pan": "arcsec", "tilt": "arcsec", "white-balance": "K"}
MANUAL, APERTURE_PRIORITY = 1, 8  # UVC auto-exposure mode bits
GET_CUR, GET_MIN, GET_MAX, GET_RES, GET_INFO, GET_DEF = 0x81, 0x82, 0x83, 0x84, 0x86, 0x87


class UvcCamera:
    def __init__(self):
        import libusb_package
        lib = self.lib = ctypes.CDLL(libusb_package.get_library_path())
        lib.libusb_control_transfer.argtypes = [ctypes.c_void_p, ctypes.c_uint8, ctypes.c_uint8, ctypes.c_uint16,
                                                ctypes.c_uint16, ctypes.c_char_p, ctypes.c_uint16, ctypes.c_uint]
        lib.libusb_open_device_with_vid_pid.restype = ctypes.c_void_p
        lib.libusb_open_device_with_vid_pid.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_uint16]
        lib.libusb_close.argtypes = [ctypes.c_void_p]
        lib.libusb_exit.argtypes = [ctypes.c_void_p]
        self.ctx = ctypes.c_void_p()
        if lib.libusb_init(ctypes.byref(self.ctx)):
            raise P21Error("USB initialisation failed")
        self.h = lib.libusb_open_device_with_vid_pid(self.ctx, VID, PID)
        if not self.h:
            lib.libusb_exit(self.ctx)
            raise P21Error("Poly Studio P21 webcam not found")
        if not self._layout_ok():
            self.close()
            raise P21Error("Unexpected P21 UVC layout; refusing camera controls")

    def close(self):
        self.lib.libusb_close(self.h)
        self.lib.libusb_exit(self.ctx)

    def _xfer(self, request_type, request, value, index, size, data=None):
        buf = ctypes.create_string_buffer(bytes(data) if data else b"", size)
        r = self.lib.libusb_control_transfer(self.h, request_type, request, value, index, buf, size, 1000)
        if r != size:
            raise P21Error(f"USB control transfer failed ({r})")
        return buf.raw[:size]

    def _layout_ok(self):
        # Camera terminal 1 and processing unit 3 on VideoControl interface 0, as the firmware declares.
        head = self._xfer(0x80, 6, 0x0200, 0, 9)
        config = self._xfer(0x80, 6, 0x0200, 0, head[2] | head[3] << 8)
        ct = pu = False
        in_vc = False
        i = 0
        while i + 2 <= len(config) and config[i] >= 2:
            d = config[i:i + config[i]]
            if d[1] == 4 and len(d) >= 7:
                in_vc = d[2] == 0 and d[5] == 14 and d[6] == 1
            elif in_vc and d[1] == 0x24 and len(d) >= 8:
                ct |= d[2] == 2 and d[3] == 1 and d[4] == 1 and d[5] == 2
                pu |= d[2] == 5 and d[3] == 3
            i += config[i]
        return ct and pu

    def _get(self, name, request):
        unit, selector, width, signed = UVC[name]
        size = width * (2 if selector == 13 and unit == 1 else 1)
        b = self._xfer(0xA1, request, selector << 8, unit << 8, 1 if request == GET_INFO else size)
        if request == GET_INFO:
            return b[0]
        offset = width if name == "tilt" else 0
        return int.from_bytes(b[offset:offset + width], "little", signed=bool(signed))

    def controls(self):
        out = []
        for name in UVC:
            try:
                info = self._get(name, GET_INFO)
                cur = self._get(name, GET_CUR)
            except P21Error:
                continue
            enabled = bool(info & 2) and not info & 4
            c = Control(name, LABELS[name], "range", cur, enabled=enabled, unit=UVC_UNITS.get(name, ""))
            if name == "auto-exposure":
                c.kind, c.value = "bool", int(cur == APERTURE_PRIORITY)
            elif name in ("exposure-priority", "privacy", "auto-white-balance"):
                c.kind = "bool"
            elif name == "power-line":
                lo, hi = self._get(name, GET_MIN), self._get(name, GET_MAX)
                c.kind, c.options = "menu", {k: v for k, v in POWER_LINE.items() if lo <= k <= hi}
            else:
                c.min, c.max, c.step = (self._get(name, r) for r in (GET_MIN, GET_MAX, GET_RES))
                try:
                    c.default = self._get(name, GET_DEF)
                except P21Error:
                    pass
            out.append(c)
        return out

    def set(self, name, value):
        """Write, then return the device's readback (the firmware rounds e.g. zoom)."""
        unit, selector, width, signed = UVC[name]
        info = self._get(name, GET_INFO)
        if not info & 2 or info & 4:
            raise P21Error(f"{LABELS[name]} is read-only or overridden by an automatic mode")
        if name == "auto-exposure":
            modes = self._get(name, GET_RES)  # a bitmask of supported modes
            value = APERTURE_PRIORITY if value else MANUAL
            if not modes & value:
                raise P21Error("Exposure mode not supported")
        if selector == 13 and unit == 1:
            size = width * 2
            both = self._xfer(0xA1, GET_CUR, selector << 8, unit << 8, size)
            fields = [both[:width], both[width:]]
            fields[name == "tilt"] = value.to_bytes(width, "little", signed=True)
            data = b"".join(fields)
        else:
            size = width
            data = value.to_bytes(width, "little", signed=bool(signed))
        self._xfer(0x21, 1, selector << 8, unit << 8, size, data)
        actual = self._get(name, GET_CUR)
        return int(actual == APERTURE_PRIORITY) if name == "auto-exposure" else actual


# --- Linux: V4L2 ----------------------------------------------------------------
CID_BASE, CID_CAMERA = 0x00980900, 0x009A0900
V4L2 = {
    "auto-exposure": CID_CAMERA + 1, "exposure-priority": CID_CAMERA + 3, "exposure": CID_CAMERA + 2,
    "zoom": CID_CAMERA + 13, "pan": CID_CAMERA + 8, "tilt": CID_CAMERA + 9, "privacy": CID_CAMERA + 16,
    "backlight": CID_BASE + 28, "brightness": CID_BASE + 0, "contrast": CID_BASE + 1, "gain": CID_BASE + 19,
    "power-line": CID_BASE + 24, "hue": CID_BASE + 3, "saturation": CID_BASE + 2, "sharpness": CID_BASE + 27,
    "gamma": CID_BASE + 16, "auto-white-balance": CID_BASE + 12, "white-balance": CID_BASE + 26,
}
VIDIOC_QUERYCAP, VIDIOC_QUERYCTRL, VIDIOC_G_CTRL, VIDIOC_S_CTRL = 0x80685600, 0xC0445624, 0xC008561B, 0xC008561C
V4L2_EXPOSURE_MANUAL, V4L2_EXPOSURE_APERTURE_PRIORITY = 1, 3


class V4l2Camera:
    def __init__(self):
        import fcntl
        import glob
        import os
        import struct
        self.fcntl, self.struct = fcntl, struct
        for node in sorted(glob.glob("/sys/class/video4linux/video*")):
            usb = os.path.realpath(os.path.join(node, "device", ".."))
            try:
                ids = [open(os.path.join(usb, f)).read().strip() for f in ("idVendor", "idProduct")]
            except OSError:
                continue
            if ids != [f"{VID:04x}", f"{PID:04x}"]:
                continue
            path = "/dev/" + os.path.basename(node)
            try:
                fd = os.open(path, os.O_RDWR)
            except OSError as e:
                raise P21Error(f"Cannot open {path}: {e} (add your user to the 'video' group)") from None
            cap = bytearray(104)
            fcntl.ioctl(fd, VIDIOC_QUERYCAP, cap)
            caps, device_caps = struct.unpack_from("<II", cap, 84)
            if (device_caps if caps & 0x80000000 else caps) & 1:  # V4L2_CAP_VIDEO_CAPTURE
                self.fd = fd
                return
            os.close(fd)  # metadata node
        raise P21Error("Poly Studio P21 webcam not found")

    def close(self):
        import os
        os.close(self.fd)

    def _ioctl(self, request, buf):
        try:
            self.fcntl.ioctl(self.fd, request, buf)
        except OSError as e:
            raise P21Error(str(e)) from None

    def controls(self):
        out = []
        for name, cid in V4L2.items():
            q = bytearray(self.struct.pack("<I64x", cid))
            try:
                self._ioctl(VIDIOC_QUERYCTRL, q)
            except P21Error:
                continue
            _, _, lo, hi, step, default, flags = self.struct.unpack_from("<II32xiiiiI", q)
            if flags & 1:  # DISABLED
                continue
            c = Control(name, LABELS[name], "range", self._get(cid), lo, hi, step, default,
                        enabled=not flags & (4 | 0x10), unit=UVC_UNITS.get(name, ""))  # READ_ONLY | INACTIVE
            if name == "auto-exposure":
                c.kind, c.value = "bool", int(c.value == V4L2_EXPOSURE_APERTURE_PRIORITY)
            elif name in ("exposure-priority", "privacy", "auto-white-balance"):
                c.kind = "bool"
            elif name == "power-line":
                c.kind, c.options = "menu", {k: v for k, v in POWER_LINE.items() if lo <= k <= hi}
            out.append(c)
        return out

    def _get(self, cid):
        b = bytearray(self.struct.pack("<Ii", cid, 0))
        self._ioctl(VIDIOC_G_CTRL, b)
        return self.struct.unpack("<Ii", b)[1]

    def set(self, name, value):
        if name == "auto-exposure":
            value = V4L2_EXPOSURE_APERTURE_PRIORITY if value else V4L2_EXPOSURE_MANUAL
        self._ioctl(VIDIOC_S_CTRL, bytearray(self.struct.pack("<Ii", V4L2[name], value)))
        actual = self._get(V4L2[name])
        return int(actual == V4L2_EXPOSURE_APERTURE_PRIORITY) if name == "auto-exposure" else actual


# --- Windows: DirectShow ----------------------------------------------------------
# name: (interface, property id, auto-flag control). KS ids beyond the classic enums
# (privacy 8, exposure priority 19, power line 13) pass straight through ksproxy.
DSHOW = {
    "auto-exposure": ("cam", 4, True), "exposure-priority": ("cam", 19, False), "exposure": ("cam", 4, False),
    "zoom": ("cam", 3, False), "pan": ("cam", 0, False), "tilt": ("cam", 1, False), "privacy": ("cam", 8, False),
    "backlight": ("amp", 8, False), "brightness": ("amp", 0, False), "contrast": ("amp", 1, False),
    "gain": ("amp", 9, False), "power-line": ("amp", 13, False), "hue": ("amp", 2, False),
    "saturation": ("amp", 3, False), "sharpness": ("amp", 4, False), "gamma": ("amp", 5, False),
    "auto-white-balance": ("amp", 7, True), "white-balance": ("amp", 7, False),
}
DSHOW_UNITS = {"exposure": "log₂ s", "pan": "°", "tilt": "°", "white-balance": "K"}
FLAG_AUTO, FLAG_MANUAL = 1, 2


class DirectShowCamera:
    def __init__(self):
        import comtypes
        from comtypes import COMMETHOD, GUID, HRESULT, IUnknown
        from comtypes.automation import VARIANT
        from comtypes.persist import IPropertyBag
        from ctypes import POINTER, byref, c_long, c_ulong, c_void_p
        from ctypes.wintypes import DWORD

        range_args = [(["in"], c_long, "Property"), (["out"], POINTER(c_long), "pMin"), (["out"], POINTER(c_long), "pMax"),
                      (["out"], POINTER(c_long), "pSteppingDelta"), (["out"], POINTER(c_long), "pDefault"),
                      (["out"], POINTER(c_long), "pCapsFlags")]

        def control_interface(iid):
            class I(IUnknown):
                _iid_ = GUID(iid)
                _methods_ = [
                    COMMETHOD([], HRESULT, "GetRange", *range_args),
                    COMMETHOD([], HRESULT, "Set", (["in"], c_long, "Property"), (["in"], c_long, "lValue"), (["in"], c_long, "Flags")),
                    COMMETHOD([], HRESULT, "Get", (["in"], c_long, "Property"), (["out"], POINTER(c_long), "lValue"), (["out"], POINTER(c_long), "Flags")),
                ]
            return I

        IAMVideoProcAmp = control_interface("{C6E13360-30AC-11D0-A18C-00A0C9118956}")
        IAMCameraControl = control_interface("{C6E13370-30AC-11D0-A18C-00A0C9118956}")

        class IMoniker(IUnknown):  # only the vtable slots up to BindToStorage matter
            _iid_ = GUID("{0000000F-0000-0000-C000-000000000046}")
            _methods_ = [COMMETHOD([], HRESULT, n) for n in ("GetClassID", "IsDirty", "Load", "Save", "GetSizeMax")] + [
                COMMETHOD([], HRESULT, "BindToObject", (["in"], c_void_p, "pbc"), (["in"], c_void_p, "pmkToLeft"),
                          (["in"], POINTER(GUID), "riid"), (["out"], POINTER(POINTER(IUnknown)), "ppv")),
                COMMETHOD([], HRESULT, "BindToStorage", (["in"], c_void_p, "pbc"), (["in"], c_void_p, "pmkToLeft"),
                          (["in"], POINTER(GUID), "riid"), (["out"], POINTER(POINTER(IUnknown)), "ppv")),
            ]

        class IEnumMoniker(IUnknown):
            _iid_ = GUID("{00000102-0000-0000-C000-000000000046}")
            _methods_ = [COMMETHOD([], HRESULT, "Next", (["in"], c_ulong, "celt"), (["out"], POINTER(POINTER(IMoniker)), "rgelt"),
                                   (["out"], POINTER(c_ulong), "pceltFetched"))]

        class ICreateDevEnum(IUnknown):
            _iid_ = GUID("{29840822-5B84-11D0-BD3B-00A0C911CE86}")
            _methods_ = [COMMETHOD([], HRESULT, "CreateClassEnumerator", (["in"], POINTER(GUID), "clsidDeviceClass"),
                                   (["out"], POINTER(POINTER(IEnumMoniker)), "ppEnumMoniker"), (["in"], DWORD, "dwFlags"))]

        dev_enum = comtypes.CoCreateInstance(GUID("{62BE5D10-60EB-11D0-BD3B-00A0C911CE86}"), ICreateDevEnum)
        monikers = dev_enum.CreateClassEnumerator(byref(GUID("{860BB310-5D01-11D0-BD3B-00A0C911CE86}")), 0)
        if not monikers:  # S_FALSE: no video devices at all
            raise P21Error("Poly Studio P21 webcam not found")
        while True:
            moniker, fetched = monikers.Next(1)
            if not fetched:
                raise P21Error("Poly Studio P21 webcam not found")
            bag = moniker.BindToStorage(None, None, byref(IPropertyBag._iid_)).QueryInterface(IPropertyBag)
            try:
                path = bag.Read("DevicePath", VARIANT(), None)  # \\?\usb#vid_095d&pid_9298&mi_00#...
            except comtypes.COMError:
                continue
            if f"vid_{VID:04x}&pid_{PID:04x}" in str(path).lower():
                filt = moniker.BindToObject(None, None, byref(IUnknown._iid_))
                self.ifaces = {"cam": filt.QueryInterface(IAMCameraControl), "amp": filt.QueryInterface(IAMVideoProcAmp)}
                self.COMError = comtypes.COMError
                return

    def close(self):
        self.ifaces = None

    def controls(self):
        out = []
        for name, (iface, prop, auto) in DSHOW.items():
            try:
                lo, hi, step, default, caps = self.ifaces[iface].GetRange(prop)
                value, flags = self.ifaces[iface].Get(prop)
            except self.COMError:
                continue
            c = Control(name, LABELS[name], "range", value, lo, hi, step, default, unit=DSHOW_UNITS.get(name, ""))
            if auto:
                if not caps & FLAG_AUTO:
                    continue
                c.kind, c.value = "bool", int(bool(flags & FLAG_AUTO))
            elif name in ("exposure-priority", "privacy"):
                c.kind = "bool"
            elif name == "power-line":
                c.kind, c.options = "menu", {k: v for k, v in POWER_LINE.items() if lo <= k <= hi}
            else:
                c.enabled = not flags & FLAG_AUTO
            out.append(c)
        return out

    def set(self, name, value):
        iface, prop, auto = DSHOW[name]
        current, flags = self.ifaces[iface].Get(prop)
        try:
            if auto:
                self.ifaces[iface].Set(prop, current, FLAG_AUTO if value else FLAG_MANUAL)
            else:
                if flags & FLAG_AUTO and name in ("exposure", "white-balance"):
                    raise P21Error(f"{LABELS[name]} is overridden by an automatic mode")
                self.ifaces[iface].Set(prop, value, FLAG_MANUAL)
            actual, flags = self.ifaces[iface].Get(prop)
        except self.COMError as e:
            raise P21Error(f"{LABELS[name]}: {e}") from None
        return int(bool(flags & FLAG_AUTO)) if auto else actual
