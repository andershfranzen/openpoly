"""P21 microphone and speaker volume, mute and default-device selection.

macOS: CoreAudio (port of src/audio.c). Linux: pactl (PulseAudio or PipeWire).
Windows: WASAPI through pycaw. kind is "input" (microphone) or "output" (speakers).
Volumes are percentages; hardware may round them, so setters return the readback.
"""
import ctypes
import json
import subprocess
import sys

from .vendor import P21Error

NAME = "Poly Studio P21"
VID, PID = 0x047F, 0x431A


def open_audio():
    if sys.platform == "darwin":
        return CoreAudio()
    if sys.platform.startswith("linux"):
        return Pulse()
    if sys.platform == "win32":
        return Wasapi()
    raise P21Error(f"Unsupported platform {sys.platform}")


# --- macOS ------------------------------------------------------------------------
def _fourcc(s):
    return int.from_bytes(s.encode(), "big")


class _Address(ctypes.Structure):
    _fields_ = [("selector", ctypes.c_uint32), ("scope", ctypes.c_uint32), ("element", ctypes.c_uint32)]


SYSTEM = 1
GLOBAL, INPUT, OUTPUT = _fourcc("glob"), _fourcc("inpt"), _fourcc("outp")
DEVICES, OBJECT_NAME, STREAMS = _fourcc("dev#"), _fourcc("lnam"), _fourcc("slay")
VOLUME, MUTE = _fourcc("volm"), _fourcc("mute")
DEFAULT_DEVICE = {"input": _fourcc("dIn "), "output": _fourcc("dOut")}


class CoreAudio:
    def __init__(self):
        c = ctypes
        ca = self.ca = c.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
        cf = self.cf = c.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        addr = c.POINTER(_Address)
        ca.AudioObjectGetPropertyDataSize.argtypes = [c.c_uint32, addr, c.c_uint32, c.c_void_p, c.POINTER(c.c_uint32)]
        ca.AudioObjectGetPropertyData.argtypes = [c.c_uint32, addr, c.c_uint32, c.c_void_p, c.POINTER(c.c_uint32), c.c_void_p]
        ca.AudioObjectSetPropertyData.argtypes = [c.c_uint32, addr, c.c_uint32, c.c_void_p, c.c_uint32, c.c_void_p]
        ca.AudioObjectHasProperty.argtypes = [c.c_uint32, addr]
        ca.AudioObjectHasProperty.restype = c.c_bool
        ca.AudioObjectIsPropertySettable.argtypes = [c.c_uint32, addr, c.POINTER(c.c_bool)]
        cf.CFStringGetCString.argtypes = [c.c_void_p, c.c_char_p, c.c_long, c.c_uint32]
        cf.CFStringGetCString.restype = c.c_bool
        cf.CFRelease.argtypes = [c.c_void_p]

    def close(self):
        pass

    def _size(self, obj, a):
        size = ctypes.c_uint32()
        if self.ca.AudioObjectGetPropertyDataSize(obj, a, 0, None, ctypes.byref(size)):
            raise P21Error("CoreAudio size query failed")
        return size.value

    def _read(self, obj, a, value):
        size = ctypes.c_uint32(ctypes.sizeof(value))
        status = self.ca.AudioObjectGetPropertyData(obj, a, 0, None, ctypes.byref(size), ctypes.byref(value))
        if status or size.value != ctypes.sizeof(value):
            raise P21Error(f"CoreAudio read failed: {status}")
        return value

    def _write(self, obj, a, value):
        settable = ctypes.c_bool()
        if self.ca.AudioObjectIsPropertySettable(obj, a, ctypes.byref(settable)) or not settable:
            raise P21Error("CoreAudio property is read-only")
        status = self.ca.AudioObjectSetPropertyData(obj, a, 0, None, ctypes.sizeof(value), ctypes.byref(value))
        if status:
            raise P21Error(f"CoreAudio write failed: {status}")

    def _device(self, kind):
        scope = INPUT if kind == "input" else OUTPUT
        a = _Address(DEVICES, GLOBAL, 0)
        ids = (ctypes.c_uint32 * (self._size(SYSTEM, a) // 4))()
        self._read(SYSTEM, a, ids)
        matches = []
        for dev in ids:
            ref = self._read(dev, _Address(OBJECT_NAME, GLOBAL, 0), ctypes.c_void_p())
            name = ctypes.create_string_buffer(256)
            ok = ref.value and self.cf.CFStringGetCString(ref, name, 256, 0x08000100)  # UTF-8
            if ref.value:
                self.cf.CFRelease(ref)
            s = _Address(STREAMS, scope, 0)
            if not ok or name.value.decode() != NAME or not self.ca.AudioObjectHasProperty(dev, s):
                continue
            raw = (ctypes.c_uint8 * self._size(dev, s))()
            self._read(dev, s, raw)
            buffers = int.from_bytes(bytes(raw[0:4]), "little")  # AudioBufferList: 16-byte AudioBuffers at offset 8
            channels = sum(int.from_bytes(bytes(raw[8 + 16 * i:12 + 16 * i]), "little") for i in range(buffers))
            if channels:
                matches.append((dev, scope, channels))
        if len(matches) != 1:
            raise P21Error(f"Expected one P21 {kind} device; found {len(matches)}")
        return matches[0]

    def _elements(self, kind, selector):
        """Main element if present, else every channel (the P21 speakers expose channels 1 and 2)."""
        dev, scope, channels = self._device(kind)
        if self.ca.AudioObjectHasProperty(dev, _Address(selector, scope, 0)):
            return dev, [_Address(selector, scope, 0)]
        elements = [_Address(selector, scope, ch) for ch in range(1, channels + 1)]
        if not all(self.ca.AudioObjectHasProperty(dev, e) for e in elements):
            raise P21Error(f"P21 {kind} has no {'mute' if selector == MUTE else 'volume'} control")
        return dev, elements

    def _values(self, kind, selector):
        dev, elements = self._elements(kind, selector)
        ctype = ctypes.c_float if selector == VOLUME else ctypes.c_uint32
        return dev, elements, [self._read(dev, e, ctype()).value for e in elements]

    def get(self, kind):
        volumes = self._values(kind, VOLUME)[2]
        mutes = self._values(kind, MUTE)[2]
        return sum(volumes) / len(volumes) * 100, all(mutes)

    def _set(self, kind, selector, wanted):
        dev, elements, before = self._values(kind, selector)
        ctype = ctypes.c_float if selector == VOLUME else ctypes.c_uint32
        written = []
        try:
            for e in elements:  # preflight every channel so a partial change cannot happen silently
                settable = ctypes.c_bool()
                if self.ca.AudioObjectIsPropertySettable(dev, e, ctypes.byref(settable)) or not settable:
                    raise P21Error("CoreAudio property is read-only")
            for e in elements:
                written.append(e)
                self._write(dev, e, ctype(wanted))
                actual = self._read(dev, e, ctype()).value
                if abs(actual - wanted) > (0.0051 if selector == VOLUME else 0):
                    raise P21Error(f"readback mismatch (requested {wanted}, actual {actual:.3f})")
        except P21Error as e:
            for element, value in zip(written, before):
                try:
                    self._write(dev, element, ctype(value))
                except P21Error:
                    raise P21Error(f"{e}; RESTORE FAILED") from None
            raise P21Error(f"{e}; previous value restored") from None

    def set_volume(self, kind, percent):
        self._set(kind, VOLUME, percent / 100)
        return self.get(kind)[0]

    def set_mute(self, kind, on):
        self._set(kind, MUTE, int(on))
        return self.get(kind)[1]

    def make_default(self, kind):
        dev = self._device(kind)[0]
        a = _Address(DEFAULT_DEVICE[kind], GLOBAL, 0)
        before = self._read(SYSTEM, a, ctypes.c_uint32()).value
        self._write(SYSTEM, a, ctypes.c_uint32(dev))
        if self._read(SYSTEM, a, ctypes.c_uint32()).value != dev:
            self._write(SYSTEM, a, ctypes.c_uint32(before))
            raise P21Error("Default device did not change; restored")


# --- Linux ----------------------------------------------------------------------
class Pulse:
    def close(self):
        pass

    def _pactl(self, *args):
        try:
            r = subprocess.run(["pactl", *args], capture_output=True, text=True, timeout=10)
        except FileNotFoundError:
            raise P21Error("pactl not found; install pulseaudio-utils (works with PipeWire too)") from None
        if r.returncode:
            raise P21Error(f"pactl {args[0]}: {r.stderr.strip()}")
        return r.stdout

    def _device(self, kind):
        noun = "sources" if kind == "input" else "sinks"
        matches = []
        for d in json.loads(self._pactl("-f", "json", "list", noun)):
            props = d.get("properties", {})
            try:
                ours = int(props.get("device.vendor.id", ""), 16) == VID and int(props.get("device.product.id", ""), 16) == PID
            except ValueError:
                continue
            if ours and props.get("device.class") != "monitor":
                matches.append(d)
        if len(matches) != 1:
            raise P21Error(f"Expected one P21 {kind} in PulseAudio/PipeWire; found {len(matches)}")
        return noun[:-1], matches[0]

    def get(self, kind):
        _, d = self._device(kind)
        volumes = [int(ch["value_percent"].rstrip("%")) for ch in d["volume"].values()]
        return sum(volumes) / len(volumes), bool(d["mute"])

    def set_volume(self, kind, percent):
        noun, d = self._device(kind)
        self._pactl(f"set-{noun}-volume", d["name"], f"{int(percent)}%")
        return self.get(kind)[0]

    def set_mute(self, kind, on):
        noun, d = self._device(kind)
        self._pactl(f"set-{noun}-mute", d["name"], "1" if on else "0")
        return self.get(kind)[1]

    def make_default(self, kind):
        noun, d = self._device(kind)
        self._pactl(f"set-default-{noun}", d["name"])


# --- Windows --------------------------------------------------------------------
class Wasapi:
    def __init__(self):
        from pycaw.constants import DEVICE_STATE, EDataFlow, ERole
        from pycaw.utils import AudioUtilities
        self.utils, self.states, self.flows, self.roles = AudioUtilities, DEVICE_STATE, EDataFlow, ERole

    def close(self):
        pass

    def _device(self, kind):
        flow = (self.flows.eCapture if kind == "input" else self.flows.eRender).value
        matches = [d for d in self.utils.GetAllDevices(flow, self.states.ACTIVE.value) if NAME in (d.FriendlyName or "")]
        if len(matches) != 1:
            raise P21Error(f"Expected one active P21 {kind} endpoint; found {len(matches)}")
        return matches[0]

    def get(self, kind):
        v = self._device(kind).EndpointVolume
        return v.GetMasterVolumeLevelScalar() * 100, bool(v.GetMute())

    def set_volume(self, kind, percent):
        self._device(kind).EndpointVolume.SetMasterVolumeLevelScalar(percent / 100, None)
        return self.get(kind)[0]

    def set_mute(self, kind, on):
        self._device(kind).EndpointVolume.SetMute(int(on), None)
        return self.get(kind)[1]

    def make_default(self, kind):
        r = self.roles
        self.utils.SetDefaultDevice(self._device(kind).id, roles=[r.eConsole, r.eMultimedia, r.eCommunications])
