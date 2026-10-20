#!/usr/bin/env python3
"""The Linux shell for the touch frame: panels/frame/FRAME-API.md, natively.

One process, run by cage (a one-window Wayland kiosk): a full-screen WebKitGTK
view of the page, plus the native half of the contract -- the screen policy
loop, the backlight, the touch-wakes-a-dark-screen rule, the sensor report.

Why WebKitGTK and not cog/WPE as the README first planned: Alpine packages no
cog and no wpewebkit at all. WebKitGTK is the same engine, packaged, with the
same script-message bridge; what it costs (GTK4 on a GLES2-only GPU, memory) is
what milestone 4 measures.

The bridge differs from Android's in one way. `@JavascriptInterface` calls are
synchronous; WebKit's script messages aren't. The four methods that return
nothing are fire-and-forget anyway; `info()` returns a JS-side copy of the
readings that this process refreshes every second (debug-only per the
contract, so a second's staleness is fine).

Config comes from the environment (/etc/conf.d/frame-shell, which reads the
card's FRAMEBOOT/frame-shell.conf -- the URL and token never live in git):
  FRAME_URL      https://<panels host>          (required)
  FRAME_TOKEN    PANEL_TOKEN, appended as ?k=   (optional)
  FRAME_PIR      1 to read the PIR on PG12; this unit has none fitted (README)
  FRAME_LRADC_CH 0 or 1, which LRADC channel carries the light sensor
  FRAME_CALIBRATE 1 loads calibrate.html instead of the page: orientation
                 marks and touch points, logged to the shell's log
  FRAME_DEBUG_TOUCH 1 logs every touch/pointer/click the page gets (touchdebug.js)
  FRAME_AUTOFLIP 0 to keep the page as start.sh rotates it, whichever way up
                 the frame is (default 1: the accelerometer decides)
"""
import glob
import json
import mmap
import os
import threading
import time
import urllib.parse
import urllib.request

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("WebKit", "6.0")
from gi.repository import GLib, Gtk, WebKit  # noqa: E402

SHELL = "linux/0.2.0"
HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.environ.get("FRAME_URL", "").rstrip("/")
TOKEN = os.environ.get("FRAME_TOKEN", "")
PIR = os.environ.get("FRAME_PIR") == "1"
LRADC_CH = int(os.environ.get("FRAME_LRADC_CH", "0"))
CALIBRATE = os.environ.get("FRAME_CALIBRATE") == "1"
AUTOFLIP = os.environ.get("FRAME_AUTOFLIP", "1") == "1"
DEBUG_TOUCH = os.environ.get("FRAME_DEBUG_TOUCH") == "1"

BACKLIGHT = "/sys/class/backlight/backlight"
THERMAL = "/sys/class/thermal/thermal_zone0/temp"
PIR_GPIO = 204  # PG12, as the vendor's bl_h18l232b.ko numbered it

# Defaults until panels answers (FRAME-API §4)
DEFAULT_POLICY = {"awake_s": 300, "night": False, "force": None, "force_s": 0,
                  "brightness": None, "report_s": 60}


def url(path):
    return BASE + path + ("?k=" + urllib.parse.quote(TOKEN) if TOKEN else "")


def read_text(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def write_text(path, value):
    try:
        with open(path, "w") as f:
            f.write(str(value))
    except OSError as e:
        print(f"frame-shell: {path}: {e}", flush=True)


class Lradc:
    """The "pt3r850" light sensor: a phototransistor on the SoC's LRADC.

    Mainline only has lradc-keys (disabled in our DT, it would turn light into
    volume presses), so the registers are read through /dev/mem. 6-bit reading,
    0..63, uncalibrated -- trends, not lux, as the contract says.

    Registers are touched only as whole aligned 32-bit words, through a
    memoryview cast to "I". The first version used struct.pack_into, whose
    4-byte copy came out as byte + odd-address halfword + byte; device memory
    faults on the unaligned halfword ("Alignment trap: not handling instruction
    f8a03001"), the SIGBUS killed python, cage exited with its only client, and
    supervise-daemon restarted it every ~10 s -- the glass flashed between the
    page and the console.
    """
    BASE = 0x01C22800
    CTRL, DATA0, DATA1 = 0x00, 0x0C, 0x10

    def __init__(self):
        self.regs = None
        try:
            fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
            page = self.BASE & ~(mmap.PAGESIZE - 1)
            self.mem = mmap.mmap(fd, mmap.PAGESIZE, offset=page)
            os.close(fd)
            self.regs = memoryview(self.mem).cast("I")
            self.word = (self.BASE - page) // 4
            # continuous mode, both channels, enabled (bit names from sun4i-lradc-keys.c)
            self.regs[self.word + self.CTRL // 4] = (2 << 24) | (3 << 22) | (2 << 12) | 1
        except OSError as e:
            print(f"frame-shell: no LRADC ({e}); lux won't be reported", flush=True)

    def read(self):
        if self.regs is None:
            return None
        reg = self.DATA1 if LRADC_CH else self.DATA0
        return self.regs[self.word + reg // 4] & 0x3F


class Accel:
    """Which way up the frame hangs, from the DA280 accelerometer (IIO).

    Only 0 vs 180 degrees matters: the page is a fixed 1280x800 landscape, so a
    frame hung the other way up wants the same page upside down. Measured on the
    glass, in the frame's default horizontal position (where start.sh's rotation
    is right): gravity reads about +9.2 m/s^2 on Y. Upside down is negative.
    (The first version had this backwards -- the frame had been turned midway
    through the calibration, so the reading was taken for the wrong position.)
    """
    FLIP_AT = 5.0  # m/s^2; between -5 and +5 (lying flat, mid-turn) keep the last

    def __init__(self):
        self.y = self.scale = None
        try:
            for name in glob.glob("/sys/bus/iio/devices/iio:device*/name"):
                if read_text(name) == "da280":
                    d = os.path.dirname(name)
                    self.y = os.path.join(d, "in_accel_y_raw")
                    self.scale = float(read_text(os.path.join(d, "in_accel_scale")))
        except (TypeError, ValueError):
            self.y = None
        if self.y is None:
            print("frame-shell: no accelerometer; the page stays as start.sh rotates it", flush=True)

    def upside_down(self, was):
        if self.y is None:
            return was
        raw = read_text(self.y)
        if raw is None:
            return was
        g = int(raw) * self.scale
        if g < -self.FLIP_AT:
            return True
        if g > self.FLIP_AT:
            return False
        return was


def read_pir():
    if not PIR:
        return None
    v = read_text(f"/sys/class/gpio/gpio{PIR_GPIO}/value")
    return None if v is None else v == "1"


class Touch:
    """Reads the Silead touchscreen beside libinput, and takes it away from
    libinput (EVIOCGRAB) while the screen is dark, so the touch that wakes the
    screen never reaches the page (FRAME-API §4.2)."""

    def __init__(self, on_touch):
        self.on_touch = on_touch
        self.dev = None
        self.grabbed = False
        self.want_grab = False
        self.finger_down = False
        try:
            import evdev
            for path in evdev.list_devices():
                d = evdev.InputDevice(path)
                if "silead" in d.name.lower() or "gsl" in d.name.lower():
                    self.dev = d
                    break
        except Exception as e:  # no py3-evdev, no device: degrade, don't die
            print(f"frame-shell: no touch device ({e})", flush=True)
        if self.dev:
            threading.Thread(target=self._loop, daemon=True).start()

    def set_grab(self, grab):
        if not self.dev:
            return
        self.want_grab = grab
        if grab and not self.grabbed:
            self._grab(True)
        # woken by something other than a touch (an HA hold, the PIR): let go
        # now, or the next touch would be swallowed as a "wake" touch
        elif not grab and self.grabbed and not self.finger_down:
            self._grab(False)

    def _grab(self, grab):
        try:
            self.dev.grab() if grab else self.dev.ungrab()
            self.grabbed = grab
        except OSError:
            pass

    def _loop(self):
        from evdev import ecodes
        for ev in self.dev.read_loop():
            if ev.type == ecodes.EV_KEY and ev.code == ecodes.BTN_TOUCH:
                self.finger_down = ev.value == 1
                if ev.value == 1:
                    GLib.idle_add(self.on_touch)
                # release the grab only once the waking finger is up, so the
                # page never sees half a gesture
                elif ev.value == 0 and self.grabbed and not self.want_grab:
                    self._grab(False)


class Shell:
    def __init__(self, app):
        self.app = app
        self.policy = dict(DEFAULT_POLICY)
        self.policy_at = time.monotonic()
        self.last_activity = time.monotonic()
        self.page_brightness = -1.0
        self.screen = None
        self.brightness = None
        self.motion = None
        self.last_report = 0.0
        self.page_loaded = False
        self.lradc = Lradc()
        self.accel = Accel() if AUTOFLIP else None
        self.flipped = False
        self.touch = Touch(self.on_touch)
        self.max_bl = int(read_text(BACKLIGHT + "/max_brightness") or 10)
        if PIR and not os.path.exists(f"/sys/class/gpio/gpio{PIR_GPIO}"):
            write_text("/sys/class/gpio/export", PIR_GPIO)

    # --- the page --------------------------------------------------------

    def build(self):
        # The Silead reports a resting finger drifting 10-25 px over a 100-200 ms
        # tap (the vendor's closed filter library smoothed it on Android). With
        # GTK's 8 px default a tap became a drag and the button never got its
        # click (FRAME_DEBUG_TOUCH logs: clicks only when moved <= 8 px). The page
        # is fixed-size with nothing to scroll, so a generous threshold costs
        # nothing.
        Gtk.Settings.get_default().set_property(
            "gtk-dnd-drag-threshold", int(os.environ.get("FRAME_TAP_SLOP", "40")))
        win = Gtk.ApplicationWindow(application=self.app)
        ucm = WebKit.UserContentManager()
        ucm.register_script_message_handler("cortex", None)
        ucm.connect("script-message-received::cortex", self.on_message)
        with open(os.path.join(HERE, "bridge.js")) as f:
            ucm.add_script(WebKit.UserScript.new(
                f.read(), WebKit.UserContentInjectedFrames.TOP_FRAME,
                WebKit.UserScriptInjectionTime.START, None, None))
        if DEBUG_TOUCH:
            with open(os.path.join(HERE, "touchdebug.js")) as f:
                ucm.add_script(WebKit.UserScript.new(
                    f.read(), WebKit.UserContentInjectedFrames.TOP_FRAME,
                    WebKit.UserScriptInjectionTime.START, None, None))
        self.ucm = ucm
        self.view = WebKit.WebView(user_content_manager=ucm)
        s = self.view.get_settings()
        s.set_enable_developer_extras(False)
        s.set_enable_back_forward_navigation_gestures(False)
        self.view.connect("context-menu", lambda *a: True)
        self.view.connect("load-failed", self.on_load_failed)
        self.view.connect("load-changed", self.on_load_changed)
        self.view.connect("web-process-terminated", self.on_web_process_terminated)
        win.set_child(self.view)
        win.fullscreen()
        win.present()
        self.load_page()
        GLib.timeout_add_seconds(1, self.tick)

    def load_page(self):
        self.page_loaded = False
        if CALIBRATE:
            self.view.load_uri("file://" + os.path.join(HERE, "calibrate.html"))
        else:
            self.view.load_uri(url("/frame"))
        return False

    def on_load_changed(self, view, event):
        if event == WebKit.LoadEvent.FINISHED and view.get_uri().startswith(BASE):
            self.page_loaded = True

    def on_load_failed(self, view, event, uri, error):
        # FRAME-API §1: our own "can't reach panels" screen, retry every ~10 s
        if uri.startswith(BASE):
            print(f"frame-shell: page failed: {error.message}", flush=True)
            view.load_uri("file://" + os.path.join(HERE, "offline.html"))
            GLib.timeout_add_seconds(10, self.load_page)
            return True
        return False

    def on_web_process_terminated(self, view, reason):
        # The page's process died (first seen: a JavaScriptCore JIT assertion on
        # armv7, start.sh). Without this the last frame stays on the glass and
        # looks like a freeze; reload it -- the flip and the bridge are user
        # scripts/styles, so they come back with the load.
        print(f"frame-shell: web process terminated ({reason.value_nick}), reloading", flush=True)
        GLib.timeout_add_seconds(2, self.load_page)

    def on_message(self, ucm, value):
        try:
            msg = json.loads(value.to_string())
        except ValueError:
            return
        m, a = msg.get("m"), msg.get("a")
        if m == "policy":
            self.apply_policy(a)
        elif m == "screenOff":
            # dark now; motion or a touch wakes it as usual
            self.last_activity = -1e9
            self.policy["force"] = None
        elif m == "setBrightness":
            self.page_brightness = float(a)
        elif m == "reload":
            self.view.reload()
        elif m == "log":  # calibrate.html, touchdebug.js
            print(f"frame-shell: page: {a}", flush=True)

    # --- policy (FRAME-API §4) ---------------------------------------------

    def apply_policy(self, p):
        if isinstance(p, str):
            try:
                p = json.loads(p)
            except ValueError:
                return
        if isinstance(p, dict):
            self.policy = {**DEFAULT_POLICY, **p}
            self.policy_at = time.monotonic()

    # The flip is done in the page, not the compositor: wlroots maps the
    # touchscreen straight onto the output box, so turning the output 180
    # degrees would leave touch where it was; WebKit's hit testing follows a
    # CSS transform, so the touches turn with the picture.
    FLIP_CSS = ("html { transform: rotate(180deg); transform-origin: 50% 50%;"
                " width: 100vw; height: 100vh; overflow: hidden; }")

    def set_flip(self, flipped):
        if flipped == self.flipped:
            return
        self.flipped = flipped
        self.ucm.remove_all_style_sheets()
        if flipped:
            self.ucm.add_style_sheet(WebKit.UserStyleSheet.new(
                self.FLIP_CSS, WebKit.UserContentInjectedFrames.TOP_FRAME,
                WebKit.UserStyleLevel.USER, None, None))
        # the user stylesheet covers the next load; the page already showing
        # gets the same rule now (user stylesheets don't reach it live)
        js = ("(function(){var s=document.getElementById('cortex-flip');"
              "if(!s){s=document.createElement('style');s.id='cortex-flip';"
              "(document.head||document.documentElement).appendChild(s);}"
              "s.textContent=%s;})();" % json.dumps(self.FLIP_CSS if flipped else ""))
        self.view.evaluate_javascript(js, -1, None, None, None, None, None)
        print(f"frame-shell: {'upside down, page flipped' if flipped else 'upright'}", flush=True)

    def on_touch(self):
        self.last_activity = time.monotonic()
        return False

    def want_screen(self, now):
        if CALIBRATE:  # someone is at the glass, touching crosshairs
            return True
        p = self.policy
        if p.get("force") in ("on", "off") and now - self.policy_at < (p.get("force_s") or 0):
            return p["force"] == "on"
        return now - self.last_activity < p.get("awake_s", 300)

    def want_brightness(self):
        if self.page_brightness >= 0:
            return min(self.page_brightness, 1.0)
        b = self.policy.get("brightness")
        return 1.0 if b is None else float(b)

    def set_backlight(self, on, level):
        if on:
            write_text(BACKLIGHT + "/brightness", max(1, round(level * self.max_bl)))
            write_text(BACKLIGHT + "/bl_power", 0)
        else:
            write_text(BACKLIGHT + "/bl_power", 4)

    # --- the 1 s loop ------------------------------------------------------

    def tick(self):
        now = time.monotonic()
        if self.accel:
            self.set_flip(self.accel.upside_down(self.flipped))
        motion = read_pir()
        edge = motion is not None and motion != self.motion
        self.motion = motion
        if motion:
            self.last_activity = now

        on, level = self.want_screen(now), self.want_brightness()
        changed = on != self.screen
        if changed or (on and level != self.brightness):
            self.set_backlight(on, level)
        self.touch.set_grab(not on)
        self.screen, self.brightness = on, level

        readings = self.readings()
        self.view.evaluate_javascript(
            "window.__cortexInfo = %s;" % json.dumps(json.dumps(readings)),
            -1, None, None, None, None, None)

        if edge or changed or now - self.last_report >= self.policy.get("report_s", 60):
            self.last_report = now
            threading.Thread(target=self.report, args=(readings,), daemon=True).start()
        return True

    def readings(self):
        t = read_text(THERMAL)
        r = {"shell": SHELL, "screen": self.screen, "brightness": self.brightness,
             "lux": self.lradc.read(),
             "soc_temp": None if t is None else round(int(t) / 1000, 1),
             "uptime": int(time.monotonic())}
        r = {k: v for k, v in r.items() if v is not None}
        # FRAME-API §3 (v3.25.3): no PIR is an explicit null -- HA shows the
        # motion sensor as unavailable, never as a permanent "nobody here"
        r["motion"] = self.motion
        return r

    def report(self, readings):
        # fire and forget; a failed report is retried at the next one (§3)
        req = urllib.request.Request(
            url("/frame/api/report"), data=json.dumps(readings).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                policy = json.loads(r.read() or b"{}")
            GLib.idle_add(self.apply_policy, policy)
        except Exception as e:
            print(f"frame-shell: report failed: {e}", flush=True)


def main():
    app = Gtk.Application(application_id="mx.cortex.frame")
    app.connect("activate", lambda a: Shell(a).build())
    app.run(None)


if __name__ == "__main__":
    main()
