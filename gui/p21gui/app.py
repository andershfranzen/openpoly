"""Poly Studio P21 control panel."""
import sys
from concurrent.futures import ThreadPoolExecutor

from PySide6.QtCore import Qt, QTimer, Signal, Slot
from PySide6.QtGui import QColor, QFontDatabase, QIcon, QKeySequence, QPixmap, QShortcut
from PySide6.QtWidgets import (
    QApplication, QButtonGroup, QCheckBox, QColorDialog, QComboBox, QFormLayout, QGridLayout, QGroupBox,
    QHBoxLayout, QLabel, QLayout, QMainWindow, QPushButton, QRadioButton, QScrollArea, QSizePolicy, QSlider, QSpinBox,
    QTabWidget, QVBoxLayout, QWidget,
)

from . import vendor
from .audio import open_audio
from .camera import open_camera
from .screen import open_screen
from .vendor import P21Error


# --- small widgets --------------------------------------------------------------
class ColorButton(QPushButton):
    picked = Signal(QColor)

    def __init__(self, color="#ffffff"):
        super().__init__()
        self.setFixedSize(56, 26)
        self.set(QColor(color))
        self.clicked.connect(self._pick)

    def set(self, color):
        self.color = color
        self.setStyleSheet(f"background:{color.name()}; border:1px solid palette(mid); border-radius:4px;")
        self.setAccessibleName(f"Colour {color.name()}")

    def _pick(self):
        c = QColorDialog.getColor(self.color, self, "Choose colour")
        if c.isValid():
            self.set(c)
            self.picked.emit(c)


class ValueSlider(QWidget):
    """Slider with a readout; emits `committed` on release or after keyboard changes settle."""
    committed = Signal(int)

    def __init__(self, lo, hi, step=1, suffix="", spin=False):
        super().__init__()
        self.lo, self.step = lo, max(step, 1)
        self.slider = QSlider(Qt.Horizontal)
        self.slider.setRange(lo, hi)
        self.slider.setSingleStep(self.step)
        self.slider.setPageStep(self.step * max(1, (hi - lo) // self.step // 10))
        row = QHBoxLayout(self)
        row.setContentsMargins(0, 0, 0, 0)
        row.addWidget(self.slider, 1)
        self._timer = QTimer(self, singleShot=True, interval=300, timeout=self._commit)
        if spin:
            self.readout = QSpinBox()
            self.readout.setRange(lo, hi)
            self.readout.setSingleStep(self.step)
            self.readout.setSuffix(suffix)
            self.readout.setMinimumWidth(96)
            self.readout.setKeyboardTracking(False)
            self.readout.valueChanged.connect(self._from_spin)
        else:
            self.readout = QLabel()
            self.readout.setMinimumWidth(48)
            self.readout.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
            self.suffix = suffix
        row.addWidget(self.readout)
        self.slider.valueChanged.connect(self._moved)
        self.slider.sliderReleased.connect(self._commit)
        self.set(lo)

    def value(self):
        return self.slider.value()

    def set(self, value):
        for w in (self.slider, self.readout):
            w.blockSignals(True)
        self.slider.setValue(value)
        self._show(value)
        for w in (self.slider, self.readout):
            w.blockSignals(False)

    def _show(self, value):
        if isinstance(self.readout, QSpinBox):
            self.readout.setValue(value)
        else:
            self.readout.setText(f"{value}{self.suffix}")

    def _moved(self, value):
        self.readout.blockSignals(True)  # a spin box would otherwise commit every drag step
        self._show(value)
        self.readout.blockSignals(False)
        if not self.slider.isSliderDown():
            self._timer.start()

    def _from_spin(self, value):
        self.slider.blockSignals(True)
        self.slider.setValue(value)
        self.slider.blockSignals(False)
        self._commit()

    def _commit(self):
        self._timer.stop()
        snapped = self.lo + round((self.slider.value() - self.lo) / self.step) * self.step
        self.set(snapped)
        self.committed.emit(snapped)


def form_layout():
    form = QFormLayout()
    form.setFieldGrowthPolicy(QFormLayout.AllNonFixedFieldsGrow)
    form.setFormAlignment(Qt.AlignLeft | Qt.AlignTop)
    return form


def hint(text):
    label = QLabel(text)
    label.setWordWrap(True)
    label.setStyleSheet("color: palette(placeholder-text);")
    return label


def group(title, *children):
    box = QGroupBox(title)
    layout = QVBoxLayout(box)
    for child in children:
        (layout.addLayout if isinstance(child, QLayout) else layout.addWidget)(child)
    return box


def scrolling(*children):
    inner = QWidget()
    layout = QVBoxLayout(inner)
    for child in children:
        layout.addWidget(child)
    layout.addStretch(1)
    area = QScrollArea()
    area.setWidgetResizable(True)
    area.setFrameShape(QScrollArea.NoFrame)
    area.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
    area.setWidget(inner)
    return area


def read_bar(session):
    """Bar registers, or a message when the LED bus is on a side channel (the rest of the tab still loads)."""
    try:
        return session.bar_state()
    except vendor.BusBusy as e:
        return str(e)


def reg_to_rgb(values):
    return QColor(*(min(255, round(v * 255 / 192)) for v in values))


def selector_label(v):
    """0 is off, 8 palette A, 15 palette B; 9..14 take the named components from B, the rest from A."""
    if v in (0, 8, 15):
        return {0: "Off", 8: "A", 15: "B"}[v]
    return "B " + "".join(c for bit, c in ((4, "R"), (2, "G"), (1, "B")) if v & bit) + ", A rest"


# --- tabs ---------------------------------------------------------------------------
class LightsTab(QWidget):
    def __init__(self, win):
        super().__init__()
        self.win = win

        # Live side lights
        self.left, self.right = ValueSlider(0, 100, 10, "%"), ValueSlider(0, 100, 10, "%")
        for s in (self.left, self.right):
            s.committed.connect(self._apply_sides)
        sides_form = form_layout()
        sides_form.addRow("Left", self.left)
        sides_form.addRow("Right", self.right)
        sides = group("Side lights", sides_form,
                      hint("As you face the screen. Applies immediately in 10% steps. Starts from the stored "
                           "brightness; firmware events can override it later."))

        # Bottom bar
        self.bar_color = ColorButton()
        self.bar_color.picked.connect(self._apply_color)
        off = QPushButton("Off")
        off.clicked.connect(lambda: self._apply_color(QColor(0, 0, 0)))
        self.fade = QComboBox()
        self.fade.addItems([f"{ms} ms" if ms < 1000 else f"{ms // 1000} s" for ms in vendor.FADE_MS])
        self.fade.activated.connect(lambda i: self.win.run("vendor", lambda s: s.bar_fade(i), self.refresh_bar, "Fade time set",
                                                           failed=self.refresh_bar))
        # ponytail: disabled until the firmware-native (0317) cycle is verified; per-frame I2C writes stall USB.
        self.cycle = QPushButton("Cycle spectrum")
        self.cycle.setEnabled(False)
        self.cycle.setToolTip("Temporarily unavailable: per-frame I2C colour writes stalled the P21's USB "
                              "(evidence/lighting-robustness-2026-09-15.txt).")
        color_row = QHBoxLayout()
        for w in (self.bar_color, off):
            color_row.addWidget(w)
        color_row.addStretch(1)
        bar_form = form_layout()
        bar_form.addRow("Colour", color_row)
        bar_form.addRow("Fade time", self.fade)
        self.cycle.setSizePolicy(QSizePolicy.Fixed, QSizePolicy.Fixed)
        bar_form.addRow("", self.cycle)
        bar = group("Bottom bar", bar_form,
                    hint("Colours stay until changed or overridden by firmware status events."))

        # Palette editor
        self.chip = QComboBox()
        self.chip.addItems([f"Chip {i + 1} (0x{a:02x})" for i, a in enumerate(vendor.CHIPS)])
        self.chip.currentIndexChanged.connect(lambda _: self._show_palette())
        self.pal_a, self.pal_b = ColorButton(), ColorButton()
        self.pal_a.picked.connect(lambda _: self._refresh_selector_icons())
        self.pal_b.picked.connect(lambda _: self._refresh_selector_icons())
        pal_row = QHBoxLayout()
        for text, w in (("A", self.pal_a), ("B", self.pal_b)):
            pal_row.addWidget(QLabel(text))
            pal_row.addWidget(w)
        pal_row.addStretch(1)
        grid = QGridLayout()
        self.selectors = []
        for i in range(12):
            combo = QComboBox()
            for v in (0, *range(8, 16)):
                combo.addItem(selector_label(v), v)
            combo.setAccessibleName(f"Module {i + 1}")
            combo.setToolTip("Which palette colour this module shows")
            self.selectors.append(combo)
            grid.addWidget(QLabel(str(i + 1)), (i // 4) * 2, i % 4, Qt.AlignHCenter)
            grid.addWidget(combo, (i // 4) * 2 + 1, i % 4)
        apply_palette = QPushButton("Apply palette")
        apply_palette.clicked.connect(self._apply_palette)
        apply_palette.setSizePolicy(QSizePolicy.Fixed, QSizePolicy.Fixed)
        self.registers = QLabel("—")
        self.registers.setFont(QFontDatabase.systemFont(QFontDatabase.FixedFont))
        self.registers.setTextInteractionFlags(Qt.TextSelectableByMouse)
        chip_form = form_layout()
        chip_form.addRow("Chip", self.chip)
        chip_form.addRow("Palettes", pal_row)
        palette = group("Bottom bar modules", chip_form, grid, apply_palette,
                        hint("Each chip drives 12 modules from two RGB palettes. Physical left-to-right order "
                             "is not mapped yet."),
                        QLabel("Registers 00–0e"), self.registers)

        # Stored firmware settings
        self.stored = {}
        stored_form = form_layout()
        for name, label in (("status", "Status light"), ("left", "Left (firmware label)"), ("right", "Right (firmware label)")):
            spin = QSpinBox()
            spin.setRange(0, 100)
            spin.setSuffix("%")
            spin.setKeyboardTracking(False)
            spin.valueChanged.connect(lambda v, n=name: self._store(n, v))
            stored_form.addRow(label, spin)
            self.stored[name] = spin
        toggles = QGridLayout()
        for i, (name, label) in enumerate((("manual", "Manual mode"), ("sensor", "Ambient sensor"), ("idle", "Idle"),
                                           ("incoming", "Incoming call"), ("active", "Active call"),
                                           ("held", "Call on hold"), ("charging", "Charging"))):
            box = QCheckBox(label)
            box.toggled.connect(lambda on, n=name: self._store(n, int(on)))
            toggles.addWidget(box, i // 2, i % 2)
            self.stored[name] = box
        stored = group("Stored settings", stored_form, toggles,
                       hint("Saved in the P21. Stored left/right brightness applies after cycling the rear touch pad."))

        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(scrolling(sides, bar, palette, stored))
        self.states = None

    # device → widgets
    def refresh(self):
        self.win.run("vendor", lambda s: ({n: s.setting(n) for n in vendor.SETTINGS}, read_bar(s)), self._show)

    def refresh_bar(self, _=None):
        self.win.run("vendor", read_bar, self._show_bar)

    def _show(self, result):
        settings, states = result
        for name, widget in self.stored.items():
            widget.blockSignals(True)
            (widget.setValue if isinstance(widget, QSpinBox) else widget.setChecked)(settings[name])
            widget.blockSignals(False)
        self.left.set(settings["right"])  # firmware labels face outward
        self.right.set(settings["left"])
        self._show_bar(states)

    def _show_bar(self, states):
        if isinstance(states, str):
            self.states = None
            self.registers.setText(f"{states}\nSetting a colour switches the bus back to the bottom bar.")
            return
        self.states = states
        self.bar_color.set(reg_to_rgb(states[0][3:6]))
        self.fade.setCurrentIndex(states[0][2] & 7)
        self.registers.setText("\n".join(f"chip{i + 1}  " + s.hex(" ") for i, s in enumerate(states)))
        self._show_palette()

    def _show_palette(self):
        if not self.states:
            return
        s = self.states[self.chip.currentIndex()]
        self.pal_a.set(reg_to_rgb(s[3:6]))
        self.pal_b.set(reg_to_rgb(s[6:9]))
        nibbles = [n for b in s[9:15] for n in (b >> 4, b & 15)]
        for combo, v in zip(self.selectors, nibbles):
            combo.setCurrentIndex(max(0, combo.findData(v)))
        self._refresh_selector_icons()

    def _refresh_selector_icons(self):
        a, b = self.pal_a.color, self.pal_b.color
        for combo in self.selectors:
            for i in range(combo.count()):
                v = combo.itemData(i)
                pix = QPixmap(12, 12)
                if v == 0:
                    pix.fill(Qt.transparent)
                else:
                    pix.fill(QColor(*((b if v & bit else a).getRgb()[k] for k, bit in ((0, 4), (1, 2), (2, 1)))))
                combo.setItemIcon(i, QIcon(pix))

    # widgets → device
    def _apply_sides(self, _):
        left, right = self.left.value(), self.right.value()
        self.win.run("vendor", lambda s: s.sides(left, right), None, f"Side lights set to {left}% / {right}%",
                     failed=self.refresh)

    def _apply_color(self, color):
        r, g, b = color.red(), color.green(), color.blue()
        self.win.run("vendor", lambda s: s.bar_rgb(r, g, b), self.refresh_bar, "Bottom bar colour set", failed=self.refresh_bar)

    def _apply_palette(self):
        chip = self.chip.currentIndex()
        a, b = self.pal_a.color.getRgb()[:3], self.pal_b.color.getRgb()[:3]
        selectors = [c.currentData() for c in self.selectors]
        self.win.run("vendor", lambda s: s.bar_palette(chip, a, b, selectors), self.refresh_bar, f"Chip {chip + 1} palette applied",
                     failed=self.refresh_bar)

    def _store(self, name, value):
        self.win.run("vendor", lambda s: s.set_setting(name, value), None, f"Stored {name} = {value}", failed=self.refresh)


class IndicatorsTab(QWidget):
    def __init__(self, win):
        super().__init__()
        self.win = win
        self.boxes = {}
        labels = {"mute": "Mute", "call": "Off-hook (in call)", "ring": "Ringing", "hold": "On hold"}
        indicator_layout = QVBoxLayout()
        for name, label in labels.items():
            box = QCheckBox(label)
            box.toggled.connect(lambda on, n=name: self.win.run("vendor", lambda s: s.set_indicator(n, on), None,
                                                                 f"{labels[n]} indicator {'on' if on else 'off'}",
                                                                 failed=self.refresh))
            indicator_layout.addWidget(box)
            self.boxes[name] = box
        indicators = group("Status indicators", indicator_layout,
                           hint("Lights the indicator only. To mute the microphone, use the Audio tab."))

        self.icons = QButtonGroup(self)
        icon_layout = QVBoxLayout()
        for name, label in (("zoom", "Zoom"), ("teams", "Microsoft Teams")):
            radio = QRadioButton(label)
            radio.setProperty("softphone", name)
            self.icons.addButton(radio)
            icon_layout.addWidget(radio)
        self.icons.buttonClicked.connect(self._set_icon)
        icon = group("Softphone logo", icon_layout, hint("Shown on the mini-display."))

        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(scrolling(indicators, icon))

    def refresh(self):
        self.win.run("vendor", lambda s: (s.indicators(), s.softphone()[0]), self._show)

    def _show(self, result):
        states, icon = result
        for name, box in self.boxes.items():
            box.blockSignals(True)
            box.setChecked(states[name])
            box.blockSignals(False)
        self.icons.setExclusive(False)  # so an unknown icon can show no selection
        for radio in self.icons.buttons():
            radio.setChecked(radio.property("softphone") == icon)
        self.icons.setExclusive(True)

    def _set_icon(self, radio):
        name = radio.property("softphone")
        self.win.run("vendor", lambda s: s.set_softphone(name), None, f"Softphone logo set to {radio.text()}", failed=self.refresh)


CAMERA_GROUPS = (
    ("Exposure", ("auto-exposure", "exposure-priority", "exposure", "gain", "backlight")),
    ("Framing", ("zoom", "pan", "tilt")),
    ("Image", ("brightness", "contrast", "saturation", "sharpness", "gamma", "hue")),
    ("White balance", ("auto-white-balance", "white-balance")),
    ("Other", ("power-line", "privacy")),
)


class CameraTab(QWidget):
    def __init__(self, win):
        super().__init__()
        self.win = win
        self.rows = {}
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        self.area = scrolling(hint("Loading camera controls…"))
        layout.addWidget(self.area)

    def refresh(self):
        self.win.run("system", self.win.using(open_camera, lambda c: c.controls()), self._show)

    def _show(self, controls):
        by_name = {c.name: c for c in controls}
        if set(by_name) != set(self.rows):
            self._build(by_name)
        for c in controls:
            widget = self.rows[c.name]
            widget.setEnabled(c.enabled)
            widget.blockSignals(True)
            if c.kind == "bool":
                widget.setChecked(bool(c.value))
            elif c.kind == "menu":
                widget.setCurrentIndex(max(0, widget.findData(c.value)))
            else:
                widget.set(c.value)
            widget.blockSignals(False)

    def _build(self, by_name):
        self.rows = {}
        boxes = []
        for title, names in CAMERA_GROUPS:
            form = form_layout()
            for name in names:
                c = by_name.get(name)
                if not c:
                    continue
                if c.kind == "bool":
                    w = QCheckBox(c.label)
                    w.toggled.connect(lambda on, n=name: self._set(n, int(on)))
                    form.addRow("", w)
                elif c.kind == "menu":
                    w = QComboBox()
                    for value, text in c.options.items():
                        w.addItem(text, value)
                    w.activated.connect(lambda i, n=name, w=w: self._set(n, w.itemData(i)))
                    form.addRow(c.label, w)
                else:
                    w = ValueSlider(c.min, c.max, c.step, f" {c.unit}" if c.unit else "", spin=True)
                    w.committed.connect(lambda v, n=name: self._set(n, v))
                    form.addRow(c.label, w)
                self.rows[name] = w
            if form.rowCount():
                extra = [hint("Zoom 10 is 1×, 40 is 4×. Pan and tilt only move when zoomed in past 1×.")] if title == "Framing" else []
                boxes.append(group(title, form, *extra))
        if not boxes:
            boxes = [hint("The camera reported no controls.")]
        boxes.append(hint("Privacy is a software control, not the physical shutter. Automatic modes disable their "
                          "manual controls."))
        self.layout().replaceWidget(self.area, new := scrolling(*boxes))
        self.area.deleteLater()
        self.area = new

    def _set(self, name, value):
        def job(camera):
            actual = camera.set(name, value)
            return actual, camera.controls()

        def done(result):
            actual, controls = result
            self._show(controls)
            if actual != value:
                self.win.notify(f"The camera adjusted {name} to {actual}")
        self.win.run("system", self.win.using(open_camera, job), done, f"Camera {name} set", failed=self.refresh)


class AudioTab(QWidget):
    def __init__(self, win):
        super().__init__()
        self.win = win
        self.widgets = {}
        boxes = []
        for kind, title in (("input", "Microphone"), ("output", "Speakers")):
            volume = ValueSlider(0, 100, 1, "%")
            volume.committed.connect(lambda v, k=kind, t=title: self._run(k, lambda a: a.set_volume(k, v), f"{t} volume set"))
            mute = QCheckBox("Mute")
            mute.toggled.connect(lambda on, k=kind, t=title: self._run(k, lambda a: a.set_mute(k, on), f"{t} {'muted' if on else 'unmuted'}"))
            default = QPushButton("Use as system default")
            default.clicked.connect(lambda _, k=kind, t=title: self._run(k, lambda a: a.make_default(k), f"P21 {t.lower()} is now the default"))
            form = form_layout()
            form.addRow("Volume", volume)
            form.addRow("", mute)
            form.addRow("", default)
            boxes.append(group(title, form))
            self.widgets[kind] = (volume, mute)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(scrolling(*boxes, hint("Hardware may round volume; the slider shows what the device reports.")))

    def _run(self, kind, action, message):
        self.win.run("system", self.win.using(open_audio, lambda a: (action(a), a.get("input"), a.get("output"))),
                     lambda r: self._show(r[1:]), message, failed=self.refresh)

    def refresh(self):
        self.win.run("system", self.win.using(open_audio, lambda a: (a.get("input"), a.get("output"))), self._show)

    def _show(self, result):
        for kind, (vol, muted) in zip(("input", "output"), result):
            volume, mute = self.widgets[kind]
            volume.set(round(vol))
            mute.blockSignals(True)
            mute.setChecked(muted)
            mute.blockSignals(False)


class DisplayTab(QWidget):
    def __init__(self, win):
        super().__init__()
        self.win = win
        self.modes = QComboBox()
        self.modes.setMinimumContentsLength(24)
        apply = QPushButton("Apply")
        apply.clicked.connect(self._apply)
        row = QHBoxLayout()
        row.addWidget(self.modes, 1)
        row.addWidget(apply)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(scrolling(group("Resolution", row, hint(
            "The P21 screen runs over DisplayLink, so its driver must be installed (DisplayLink Manager on macOS, "
            "evdi on Linux). Changes last until you log out; Linux requires an X11 session."))))

    def refresh(self):
        self.win.run("system", self.win.using(open_screen, lambda s: s.modes()), self._show)

    def _show(self, result):
        modes, current = result
        self.modes.clear()
        for mode_id, text in modes:
            self.modes.addItem(text + ("  (current)" if mode_id == current else ""), mode_id)
        self.modes.setCurrentIndex(max(0, self.modes.findData(current)))

    def _apply(self):
        mode_id = self.modes.currentData()
        if mode_id is None:
            return
        self.win.run("system", self.win.using(open_screen, lambda s: (s.apply(mode_id), s.modes())[1]), self._show,
                     "Display mode changed", failed=self.refresh)


# --- window -------------------------------------------------------------------------
class Window(QMainWindow):
    _finished = Signal(object, object, object, object, object)

    def __init__(self):
        super().__init__()
        self.setWindowTitle("Poly Studio P21")
        self.resize(640, 760)
        init = None
        if sys.platform == "win32":
            import comtypes
            init = comtypes.CoInitialize
        # One queue per device path: vendor HID traffic must never interleave.
        self.pools = {"vendor": ThreadPoolExecutor(1, initializer=init), "system": ThreadPoolExecutor(1, initializer=init)}
        self.pending = 0
        self._finished.connect(self._deliver)

        self.tabs = QTabWidget()
        self.pages = [LightsTab(self), IndicatorsTab(self), CameraTab(self), AudioTab(self), DisplayTab(self)]
        for page, title in zip(self.pages, ("Lights", "Indicators", "Camera", "Audio", "Display")):
            self.tabs.addTab(page, title)
        refresh = QPushButton("Refresh")
        shortcut = QShortcut(QKeySequence.Refresh, self, self.retry)
        refresh.setToolTip(f"Read the current values from the P21 ({shortcut.key().toString(QKeySequence.NativeText)})")
        refresh.clicked.connect(self.retry)
        self.statusBar().addPermanentWidget(refresh)
        self.tabs.currentChanged.connect(lambda _: self.refresh())
        self.setCentralWidget(self.tabs)

        self.message = QLabel()
        self.message.setTextInteractionFlags(Qt.TextSelectableByMouse)
        self.statusBar().addWidget(self.message, 1)
        QTimer.singleShot(0, self.refresh)

    def refresh(self):
        self.tabs.currentWidget().refresh()

    def retry(self):
        vendor.Session.fault = None  # an explicit Refresh is the user's go-ahead after reconnecting
        self.message.setProperty("error", False)
        self.refresh()

    def using(self, opener, action):
        def job():
            backend = opener()
            try:
                return action(backend)
            finally:
                backend.close()
        return job

    def run(self, pool, fn, done=None, message=None, busy="Talking to the P21…", failed=None):
        """Run fn off the UI thread. Vendor jobs receive an open vendor.Session."""
        self.pending += 1
        if not self.message.property("error"):  # an error stays visible until an action succeeds
            self.notify(busy)

        def job():
            if pool != "vendor":
                return fn()
            with vendor.Session() as session:
                return fn(session)

        def finished(future):
            error = future.exception()
            self._finished.emit(done, None if error else future.result(), error, message, failed)

        self.pools[pool].submit(job).add_done_callback(finished)

    @Slot(object, object, object, object, object)
    def _deliver(self, done, result, error, message, failed):
        self.pending -= 1
        if error:
            text = str(error) if isinstance(error, P21Error) else f"{type(error).__name__}: {error}"
            self.notify(text, error=True)
            if failed and not vendor.Session.fault:  # never touch a stalled device again automatically
                failed()
            return
        if done:
            done(result)
        if self.message.property("error") and not message:
            return
        self.notify(message or ("Ready" if not self.pending else "Talking to the P21…"))

    def notify(self, text, error=False):
        self.message.setProperty("error", error)
        self.message.setStyleSheet("color: #d93025;" if error else "")
        self.message.setText(text)

    def closeEvent(self, event):
        for pool in self.pools.values():
            pool.shutdown(wait=True, cancel_futures=True)
        super().closeEvent(event)


def main():
    app = QApplication(sys.argv)
    app.setApplicationName("Poly Studio P21")
    window = Window()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
