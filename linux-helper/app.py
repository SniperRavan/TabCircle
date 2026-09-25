"""
TabCircle Linux Helper
Native companion for Chromium-based browsers providing MRU tab switching
and a floating visual thumbnail overlay on Linux (X11).
"""

import sys
import os
import json
import asyncio
import threading
import logging
from logging.handlers import RotatingFileHandler
import time
import base64
import atexit
import signal
import math
import tempfile
import subprocess
from urllib.parse import urlparse

from PyQt6.QtWidgets import (
    QApplication, QWidget, QLabel, QVBoxLayout, QHBoxLayout,
    QFrame, QGraphicsDropShadowEffect, QScrollArea
)
from PyQt6.QtCore import Qt, pyqtSignal, QObject, QRectF, QTimer, QPoint
from PyQt6.QtGui import (
    QPixmap, QImage, QPainter, QPainterPath, QColor, QFont, QPen, QIcon, QPalette, QCursor, QGuiApplication
)

import websockets
from Xlib import X, XK, display
import Xlib.error
from Xlib.ext import xtest, randr

_log_level = logging.DEBUG if "--debug" in sys.argv else logging.INFO
logging.basicConfig(
    level=_log_level,
    format="%(asctime)s.%(msecs)03d [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S"
)
logger = logging.getLogger("TabCircle")
logger.setLevel(_log_level)

# Ensure persistent daemon logs with log rotation (5MB x 3 backups = max 15MB)
try:
    _log_dir = os.path.expanduser("~/.cache/tabcircle")
    os.makedirs(_log_dir, exist_ok=True)
    _file_handler = RotatingFileHandler(
        os.path.join(_log_dir, "helper.log"),
        maxBytes=5 * 1024 * 1024,
        backupCount=3,
        encoding="utf-8"
    )
    _file_handler.setLevel(_log_level)
    _file_handler.setFormatter(logging.Formatter("%(asctime)s.%(msecs)03d [%(levelname)s] %(message)s", datefmt="%H:%M:%S"))
    logger.addHandler(_file_handler)
except Exception:
    pass

# --- Global State & Emergency Cleanup ---
_ungrab_display = None
_t_intercept = 0.0

def emergency_ungrab():
    """Guaranteed release of any active X11 keyboard grabs across Display instances."""
    global _ungrab_display
    try:
        if _ungrab_display is not None:
            _ungrab_display.allow_events(X.AsyncKeyboard, X.CurrentTime)
            _ungrab_display.ungrab_keyboard(X.CurrentTime)
            _ungrab_display.flush()
    except Exception:
        pass
    try:
        d = display.Display()
        d.allow_events(X.AsyncKeyboard, X.CurrentTime)
        d.ungrab_keyboard(X.CurrentTime)
        d.flush()
    except Exception:
        pass

atexit.register(emergency_ungrab)


def ensure_single_instance():
    """
    Ensures only a single instance of TabCircle helper runs at a time.
    Terminates any stale/zombie background instances holding port 41573 or X11 grabs.
    """
    pid_file = os.path.join(tempfile.gettempdir(), "tabcircle_helper.pid")
    my_pid = os.getpid()

    if os.path.exists(pid_file):
        try:
            with open(pid_file, "r") as f:
                old_pid = int(f.read().strip())
            if old_pid != my_pid and os.path.exists(f"/proc/{old_pid}"):
                cmdline_path = f"/proc/{old_pid}/cmdline"
                if os.path.exists(cmdline_path):
                    with open(cmdline_path, "rb") as f:
                        cmd = f.read().decode("utf-8", errors="ignore")
                    parts = [p for p in cmd.split("\x00") if p]
                    exe = os.path.basename(parts[0]).lower() if parts else ""
                    is_python = "python" in exe
                    is_helper_script = any(arg.endswith("linux-helper/app.py") or (arg.endswith("app.py") and "tabcircle" in arg.lower()) for arg in parts[1:])
                    is_not_compiler = not any(arg in ("py_compile", "-m") for arg in parts)
                    if is_python and is_helper_script and is_not_compiler:
                        logger.warning(f"Found existing TabCircle helper instance (PID {old_pid}). Terminating it to release port 41573 and X11 grabs...")
                        try:
                            os.kill(old_pid, signal.SIGTERM)
                            time.sleep(0.3)
                            if os.path.exists(f"/proc/{old_pid}"):
                                os.kill(old_pid, signal.SIGKILL)
                                time.sleep(0.2)
                        except OSError:
                            pass
        except Exception as e:
            logger.debug(f"PID check notice: {e}")

    try:
        with open(pid_file, "w") as f:
            f.write(str(my_pid))
    except Exception:
        pass

    def cleanup_pid():
        try:
            if os.path.exists(pid_file):
                with open(pid_file, "r") as f:
                    if f.read().strip() == str(my_pid):
                        os.remove(pid_file)
        except Exception:
            pass

    atexit.register(cleanup_pid)


# Path to icon relative to this file
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ICON_PATH = os.path.normpath(os.path.join(BASE_DIR, "..", "extension", "icons", "icon-128.png"))

# Supported browser window classes
BROWSER_CLASSES = ['chromium', 'chrome', 'brave', 'edge', 'vivaldi', 'opera', 'zen']

# --- Global State ---
ws_loop = None
ws_clients = set()
cached_tabs = []
cached_window_id = -1

# Thread-safe image separation: worker threads store QImage; GUI thread converts to QPixmap
tab_thumbnail_images = {}  # tab_id -> QImage (raw decoded image)
tab_scaled_pixmaps = {}    # tab_id -> QPixmap (GUI thread cache, 140x88 pre-scaled)
cached_favicon_images = {} # tab_id -> QImage (raw decoded favicon)
cached_favicons = {}       # tab_id -> QPixmap (GUI thread cache, size-scaled)
fetching_favicons = set()

# Dismissal synchronization between GUI clicks and Xlib key interceptor
_switcher_dismiss_event = threading.Event()
_live_dark = None
_offscreen_theme = None

# Persistent cache for sub-millisecond instant startup availability
CACHE_DIR = os.path.join(tempfile.gettempdir(), "tabcircle")
CACHE_FILE = os.path.join(CACHE_DIR, "tabs_cache.json")

def load_cached_tabs():
    global cached_tabs, cached_window_id
    if os.path.isfile(CACHE_FILE):
        try:
            with open(CACHE_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
            tabs = data.get("tabs", [])
            win_id = data.get("currentWindowId", -1)
            if tabs:
                cached_tabs = tabs
                cached_window_id = win_id
                logger.info(f"Loaded {len(cached_tabs)} cached tabs from previous session.")
        except Exception:
            pass

def save_cached_tabs(tabs, window_id):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(CACHE_FILE, "w", encoding="utf-8") as f:
            json.dump({"tabs": tabs, "currentWindowId": window_id}, f)
    except Exception:
        pass

load_cached_tabs()

# User configuration (~/.config/tabcircle/config.json)
CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "tabcircle")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")

def load_helper_config():
    """
    Loads user configuration from ~/.config/tabcircle/config.json.
    Supports low-resource mode via config or --low-resource CLI argument.
    """
    config = {
        "low_resource_mode": False
    }
    if os.path.isfile(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    if "low_resource_mode" in data:
                        config["low_resource_mode"] = bool(data["low_resource_mode"])
                    elif "lowResourceMode" in data:
                        config["low_resource_mode"] = bool(data["lowResourceMode"])
                    elif "capture_thumbnails" in data:
                        config["low_resource_mode"] = not bool(data["capture_thumbnails"])
                    elif "captureThumbnails" in data:
                        config["low_resource_mode"] = not bool(data["captureThumbnails"])
        except Exception as e:
            logger.warning(f"Could not read config file {CONFIG_FILE}: {e}")

    # Explicit precedence: CLI flags override configuration file
    if "--low-resource" in sys.argv:
        config["low_resource_mode"] = True
    elif "--no-low-resource" in sys.argv:
        config["low_resource_mode"] = False

    return config

helper_config = load_helper_config()
if helper_config.get("low_resource_mode", False):
    logger.info("Low-resource mode active: visual screenshots disabled (favicon-only mode).")

# --- UI Signals ---
class SwitcherSignals(QObject):
    update_mru = pyqtSignal(list, int)
    update_thumb = pyqtSignal(int)
    update_theme = pyqtSignal()
    show_overlay = pyqtSignal(list, int, object)
    hide_overlay = pyqtSignal()
    select_next = pyqtSignal()
    select_prev = pyqtSignal()
    commit_switch = pyqtSignal()

signals = SwitcherSignals()

# --- Squircle Geometry & Icon Helpers ---
def make_superellipse_squircle(rect: QRectF, r: float, n: float = 4.2) -> QPainterPath:
    """
    Constructs an authentic Apple-style continuous curvature squircle path using superellipse formula.
    - rect: QRectF geometry
    - r: corner radius in px
    - n: superellipse exponent (Apple continuous corner blending uses ~4.2)
    """
    path = QPainterPath()
    x, y, w, h = rect.x(), rect.y(), rect.width(), rect.height()
    r = min(r, w / 2, h / 2)
    steps = 16

    def f(u):
        cos_u = max(0.0, math.cos(u))
        sin_u = max(0.0, math.sin(u))
        fx = r * (cos_u ** (2.0 / n))
        fy = r * (sin_u ** (2.0 / n))
        return fx, fy

    # Start at top edge just after top-left corner
    path.moveTo(x + r, y)
    # Top straight edge
    path.lineTo(x + w - r, y)

    # 1. Top-right corner (u from pi/2 down to 0)
    cx, cy = x + w - r, y + r
    for i in range(1, steps + 1):
        u = (math.pi / 2.0) * (1.0 - i / steps)
        fx, fy = f(u)
        path.lineTo(cx + fx, cy - fy)

    # Right straight edge
    path.lineTo(x + w, y + h - r)

    # 2. Bottom-right corner (u from 0 to pi/2)
    cx, cy = x + w - r, y + h - r
    for i in range(1, steps + 1):
        u = (math.pi / 2.0) * (i / steps)
        fx, fy = f(u)
        path.lineTo(cx + fx, cy + fy)

    # Bottom straight edge
    path.lineTo(x + r, y + h)

    # 3. Bottom-left corner (u from pi/2 down to 0)
    cx, cy = x + r, y + h - r
    for i in range(1, steps + 1):
        u = (math.pi / 2.0) * (1.0 - i / steps)
        fx, fy = f(u)
        path.lineTo(cx - fx, cy + fy)

    # Left straight edge
    path.lineTo(x, y + r)

    # 4. Top-left corner (u from 0 to pi/2)
    cx, cy = x + r, y + r
    for i in range(1, steps + 1):
        u = (math.pi / 2.0) * (i / steps)
        fx, fy = f(u)
        path.lineTo(cx - fx, cy - fy)

    path.closeSubpath()
    return path


def draw_globe_icon(size=13, color=None):
    """Draws a crisp minimalist vector globe icon matching macOS SF Symbol globe."""
    pix = QPixmap(size, size)
    pix.fill(Qt.GlobalColor.transparent)
    p = QPainter(pix)
    p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
    if color is None:
        color = QColor(255, 255, 255, 120)
    pen = QPen(color, 1.0)
    p.setPen(pen)
    p.drawEllipse(1, 1, size - 2, size - 2)
    p.drawLine(1, size // 2, size - 2, size // 2)
    p.drawEllipse(size // 4, 1, size // 2, size - 2)
    p.end()
    return pix

def get_favicon_pixmap(tab_data, size=13, globe_color=None):
    """Returns cached favicon or fallback globe icon with strict SSRF and protocol validation. Converts to QPixmap on GUI thread."""
    tab_id = tab_data.get("id")
    if tab_id in cached_favicons:
        return cached_favicons[tab_id]

    if tab_id in cached_favicon_images:
        img = cached_favicon_images[tab_id]
        if not img.isNull():
            pix = QPixmap.fromImage(img).scaled(
                size, size,
                Qt.AspectRatioMode.KeepAspectRatio,
                Qt.TransformationMode.SmoothTransformation
            )
            cached_favicons[tab_id] = pix
            return pix

    raw_icon = tab_data.get("favIconUrl", "")
    if raw_icon and raw_icon.startswith("data:image"):
        try:
            b64 = raw_icon.split(",", 1)[1]
            img_bytes = base64.b64decode(b64)
            img = QImage.fromData(img_bytes)
            if not img.isNull():
                pix = QPixmap.fromImage(img).scaled(
                    size, size,
                    Qt.AspectRatioMode.KeepAspectRatio,
                    Qt.TransformationMode.SmoothTransformation
                )
                cached_favicons[tab_id] = pix
                return pix
        except Exception:
            pass
    elif raw_icon and tab_id not in fetching_favicons:
        parsed = urlparse(raw_icon)
        # Security: strictly allow only public http/https schemes, block file://, localhost, private RFC1918 IPs
        if parsed.scheme in ('http', 'https') and parsed.hostname:
            hostname = parsed.hostname.lower()
            if hostname not in ('localhost', '127.0.0.1', '::1', '0.0.0.0') and not hostname.startswith('192.168.') and not hostname.startswith('10.'):
                fetching_favicons.add(tab_id)
                def _fetch():
                    conn = None
                    try:
                        import http.client
                        port = parsed.port or (443 if parsed.scheme == 'https' else 80)
                        path = parsed.path or '/'
                        if parsed.query:
                            path += '?' + parsed.query
                        conn_cls = http.client.HTTPSConnection if parsed.scheme == 'https' else http.client.HTTPConnection
                        conn = conn_cls(hostname, port, timeout=1.5)
                        conn.request('GET', path, headers={'User-Agent': 'TabCircle/1.0'})
                        resp = conn.getresponse()
                        if resp.status == 200:
                            data = resp.read(1024 * 1024 + 1)
                            if len(data) <= 1024 * 1024:  # Max 1MB
                                img = QImage.fromData(data)
                                if not img.isNull():
                                    # Thread-safety: store QImage in worker thread; convert to QPixmap on GUI thread
                                    cached_favicon_images[tab_id] = img
                                    signals.update_thumb.emit(tab_id)
                    except Exception:
                        pass
                    finally:
                        if conn:
                            try:
                                conn.close()
                            except Exception:
                                pass
                        fetching_favicons.discard(tab_id)

                threading.Thread(target=_fetch, daemon=True).start()

    return draw_globe_icon(size, color=globe_color)


def get_tab_thumbnail_pixmap(tab_id: int) -> QPixmap:
    """Returns 140x88 pre-scaled QPixmap, instantiated and cached strictly on the GUI thread."""
    if tab_id in tab_scaled_pixmaps:
        return tab_scaled_pixmaps[tab_id]
    qimg = tab_thumbnail_images.get(tab_id)
    if qimg and not qimg.isNull():
        scaled = qimg.scaled(
            140, 88,
            Qt.AspectRatioMode.KeepAspectRatioByExpanding,
            Qt.TransformationMode.SmoothTransformation
        )
        x = max(0, (scaled.width() - 140) // 2)
        y = max(0, (scaled.height() - 88) // 2)
        cropped = scaled.copy(x, y, 140, 88)
        pix = QPixmap.fromImage(cropped)
        tab_scaled_pixmaps[tab_id] = pix
        return pix
    return None


def is_system_dark_mode() -> bool:
    """Detects if system is currently in Dark Mode (Cinnamon / GNOME / FreeDesktop / Qt)."""
    try:
        res = subprocess.run(
            ['gsettings', 'get', 'org.cinnamon.desktop.interface', 'color-scheme'],
            capture_output=True, text=True, timeout=0.4
        )
        val = res.stdout.strip().strip("'")
        if val == 'prefer-dark':
            return True
        if val == 'prefer-light':
            return False
        if val == 'default':
            res_theme = subprocess.run(
                ['gsettings', 'get', 'org.cinnamon.desktop.interface', 'gtk-theme'],
                capture_output=True, text=True, timeout=0.4
            )
            return 'dark' in res_theme.stdout.strip().lower()
    except Exception:
        pass

    try:
        res = subprocess.run(
            ['gsettings', 'get', 'org.gnome.desktop.interface', 'color-scheme'],
            capture_output=True, text=True, timeout=0.4
        )
        val = res.stdout.strip().strip("'")
        if val == 'prefer-dark':
            return True
        if val == 'prefer-light':
            return False
        if val == 'default':
            res_theme = subprocess.run(
                ['gsettings', 'get', 'org.gnome.desktop.interface', 'gtk-theme'],
                capture_output=True, text=True, timeout=0.4
            )
            return 'dark' in res_theme.stdout.strip().lower()
    except Exception:
        pass

    app = QApplication.instance()
    if app:
        return app.palette().color(QPalette.ColorRole.Window).lightness() < 128
    return True


class Theme:
    """Encapsulates design-token styling for dynamic Light and Dark modes."""
    def __init__(self, is_dark: bool):
        self.is_dark = is_dark
        if is_dark:
            # Dark glass background container
            self.container_bg = QColor(28, 28, 34, 242)
            self.container_border = QColor(255, 255, 255, 38)
            self.container_shadow = QColor(0, 0, 0, 180)

            # Tab Card
            self.pill_selected = QColor(255, 255, 255, 50)
            self.pill_hover = QColor(255, 255, 255, 18)
            self.title_selected_style = "color: #FFFFFF; font-size: 11px; font-weight: 600; background: transparent;"
            self.title_unselected_style = "color: rgba(255, 255, 255, 0.72); font-size: 11px; font-weight: 400; background: transparent;"

            # Thumbnail Widget
            self.thumb_border_selected = QColor("#2C6BED")
            self.thumb_border_unselected = QColor(255, 255, 255, 36)
            self.thumb_shadow_selected = QColor(44, 107, 237, 160)
            self.thumb_shadow_unselected = QColor(0, 0, 0, 140)
            self.thumb_fallback_bg = QColor(255, 255, 255, 24)
            self.globe_pen = QColor(255, 255, 255, 120)
        else:
            # Light frosted glass container matching Apple/Arc aesthetic
            self.container_bg = QColor(255, 255, 255, 246)
            self.container_border = QColor(0, 0, 0, 24)
            self.container_shadow = QColor(0, 0, 0, 52)

            # Tab Card
            self.pill_selected = QColor(0, 0, 0, 16)
            self.pill_hover = QColor(0, 0, 0, 8)
            self.title_selected_style = "color: #111827; font-size: 11px; font-weight: 600; background: transparent;"
            self.title_unselected_style = "color: #4B5563; font-size: 11px; font-weight: 400; background: transparent;"

            # Thumbnail Widget
            self.thumb_border_selected = QColor("#007AFF")
            self.thumb_border_unselected = QColor(0, 0, 0, 24)
            self.thumb_shadow_selected = QColor(0, 122, 255, 140)
            self.thumb_shadow_unselected = QColor(0, 0, 0, 38)
            self.thumb_fallback_bg = QColor(242, 243, 246)
            self.globe_pen = QColor(110, 115, 128)


def sample_browser_is_dark(d, root):
    """
    Directly samples the active browser window's tab-strip / header pixels in real time via X11.
    Provides instant 0-latency theme detection without waiting for Chromium's 10s batched disk flush.
    Returns True for Dark, False for Light, or None if sampling fails or returns all zeros (GPU window).
    """
    try:
        prop = root.get_full_property(d.intern_atom('_NET_ACTIVE_WINDOW'), X.AnyPropertyType)
        if not prop or not prop.value:
            return None
        win = d.create_resource_object('window', prop.value[0])
        geom = win.get_geometry()
        w = geom.width
        if w <= 0:
            return None
        lum = []
        for fx in (0.35, 0.5, 0.65, 0.8):
            px = win.get_image(int(w * fx), 3, 1, 1, X.ZPixmap, 0xffffffff).data
            lum.append(0.2126 * px[2] + 0.7152 * px[1] + 0.0722 * px[0])  # BGRx -> Rec.709 relative luminance
        if not any(lum):
            mid = win.get_image(w // 2, geom.height // 2, 1, 1, X.ZPixmap, 0xffffffff).data
            if not any(mid[:3]):
                logger.debug("Theme sample: all black (unreadable window)")
                return None
            lum = [0.0]  # black frame but readable window -> dark theme
        is_dark = sorted(lum)[len(lum) // 2] < 128
        logger.debug(f"Theme sample lum={[round(v) for v in lum]} -> is_dark={is_dark}")
        return is_dark
    except Exception as e:
        logger.debug(f"Theme sample failed: {e!r}")
        return None


_last_pref_mtime = 0
_cached_browser_theme = None
_cached_pref_path = None

def get_browser_theme_mode(force=False):
    """
    Directly inspects Chromium / Brave user preferences to determine if the browser
    is configured in Light mode (color_scheme2 == 1) or Dark mode (color_scheme2 == 2).
    Uses mtime caching to run in 0.01ms without repeatedly parsing 250KB JSON files.
    Resolves active profile dynamically from Local State.
    Returns False for Light, True for Dark, or None if system default / not specified.
    """
    global _last_pref_mtime, _cached_browser_theme, _cached_pref_path
    config_home = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
    candidates = []
    if _cached_pref_path and os.path.isfile(_cached_pref_path):
        candidates.append(_cached_pref_path)

    browser_roots = [
        # Brave Origin / Stable / Beta / Nightly
        os.path.join(config_home, "BraveSoftware", "Brave-Origin"),
        os.path.join(config_home, "BraveSoftware", "Brave-Browser"),
        os.path.join(config_home, "BraveSoftware", "Brave-Browser-Beta"),
        os.path.join(config_home, "BraveSoftware", "Brave-Browser-Nightly"),
        # Google Chrome / Chromium
        os.path.join(config_home, "google-chrome"),
        os.path.join(config_home, "google-chrome-beta"),
        os.path.join(config_home, "chromium"),
    ]

    for root_dir in browser_roots:
        if os.path.isdir(root_dir):
            active_profile = "Default"
            local_state = os.path.join(root_dir, "Local State")
            if os.path.isfile(local_state):
                try:
                    with open(local_state, "r", encoding="utf-8") as f:
                        ls_data = json.load(f)
                    active_profile = ls_data.get("profile", {}).get("last_used", "Default")
                except Exception:
                    pass
            pref_active = os.path.join(root_dir, active_profile, "Preferences")
            if pref_active not in candidates:
                candidates.append(pref_active)
            pref_default = os.path.join(root_dir, "Default", "Preferences")
            if pref_default not in candidates:
                candidates.append(pref_default)

    for pref_path in candidates:
        if os.path.isfile(pref_path):
            try:
                mtime = os.path.getmtime(pref_path)
                if not force and pref_path == _cached_pref_path and mtime == _last_pref_mtime:
                    return _cached_browser_theme

                with open(pref_path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                browser_section = data.get("browser", {})
                theme_info = browser_section.get("theme", {})
                cs = theme_info.get("color_scheme2")
                _cached_pref_path = pref_path
                _last_pref_mtime = mtime
                if cs == 1:
                    _cached_browser_theme = False  # Light mode
                    return False
                elif cs == 2:
                    _cached_browser_theme = True   # Dark mode
                    return True
                else:
                    _cached_browser_theme = None
                    return None
            except Exception:
                pass
    return None

_current_theme = None

def set_theme_mode(is_dark: bool):
    """Updates offscreen theme reporting from browser extension."""
    global _offscreen_theme, _current_theme
    if is_dark is None:
        return
    is_dark = bool(is_dark)
    _offscreen_theme = is_dark
    pref_dark = get_browser_theme_mode()
    # If no live sample and no explicit disk setting, apply offscreen reporting
    if _live_dark is None and pref_dark is None:
        if _current_theme is None or _current_theme.is_dark != is_dark:
            _current_theme = Theme(is_dark)
            logger.info(f"Theme mode updated from browser: {'Dark' if is_dark else 'Light'}")
            signals.update_theme.emit()

def get_current_theme() -> Theme:
    """Returns authoritative theme: live X11 pixel sample > disk preferences > extension > OS."""
    global _current_theme, _live_dark, _offscreen_theme
    target_dark = None
    if _live_dark is not None:
        target_dark = _live_dark
    else:
        pref_dark = get_browser_theme_mode()
        if pref_dark is not None:
            target_dark = pref_dark
        elif _offscreen_theme is not None:
            target_dark = _offscreen_theme
        else:
            target_dark = is_system_dark_mode()

    if _current_theme is None or _current_theme.is_dark != target_dark:
        _current_theme = Theme(target_dark)
        logger.info(f"Theme active: {'Dark' if target_dark else 'Light'} mode")
        signals.update_theme.emit()

    return _current_theme


# --- Thumbnail Widget (140x88) ---
class ThumbnailWidget(QWidget):
    """
    Renders 140x88 thumbnail with Apple continuous squircle corners.
    Box shadow:
      - Unselected tabs have a physical drop shadow (blur 10, offset 3, rgba(0,0,0,0.55))
      - Selected tabs have an energetic blue glowing halo shadow (blur 18, offset 3, rgba(44,107,237,0.65))
    Border:
      - Selected: 2px solid #2C6BED along squircle
      - Unselected: 1px solid rgba(255,255,255,0.14) along squircle
    Overlay:
      - Pinned gold star badge (★) top-left
      - Close button (✕) top-right on hover
    """
    close_clicked = pyqtSignal(int)
    clicked = pyqtSignal(int)

    def __init__(self, tab_data, is_selected=False, theme=None, parent=None):
        super().__init__(parent)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground, True)
        self.tab_data = tab_data
        self.tab_id = tab_data.get("id")
        self.is_selected = is_selected
        self.theme = theme or get_current_theme()
        self.hovering = False
        self.close_hovering = False

        self.setFixedSize(140, 88)
        self.setMouseTracking(True)
        self.shadow_effect = QGraphicsDropShadowEffect(self)
        self.setGraphicsEffect(self.shadow_effect)
        self.update_shadow()

    def update_data(self, tab_data, is_selected=False, theme=None):
        self.tab_data = tab_data
        self.tab_id = tab_data.get("id")
        self.is_selected = is_selected
        if theme:
            self.theme = theme
        self.hovering = False
        self.close_hovering = False
        self.update_shadow()
        self.update()

    def set_theme(self, theme: Theme):
        self.theme = theme
        self.update_shadow()
        self.update()

    def update_shadow(self):
        if self.is_selected:
            self.shadow_effect.setBlurRadius(18)
            self.shadow_effect.setColor(self.theme.thumb_shadow_selected)
            self.shadow_effect.setOffset(0, 3)
        else:
            self.shadow_effect.setBlurRadius(10)
            self.shadow_effect.setColor(self.theme.thumb_shadow_unselected)
            self.shadow_effect.setOffset(0, 3)

    def set_selected(self, selected: bool):
        if self.is_selected != selected:
            self.is_selected = selected
            self.update_shadow()
            self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, True)

        rect = QRectF(1.0, 1.0, 138.0, 86.0)
        path = make_superellipse_squircle(rect, 8.0, n=4.0)

        painter.save()
        painter.setClipPath(path)

        # 1. Base Fill & Thumbnail Content
        pixmap = get_tab_thumbnail_pixmap(self.tab_id)
        if pixmap and not pixmap.isNull():
            painter.drawPixmap(0, 0, pixmap)
        else:
            # Fallback neutral translucent background with centered favicon/globe
            painter.fillRect(0, 0, 140, 88, self.theme.thumb_fallback_bg)
            fav = get_favicon_pixmap(self.tab_data, size=28, globe_color=self.theme.globe_pen)
            painter.drawPixmap((140 - 28) // 2, (88 - 28) // 2, fav)

        painter.restore()

        # 2. Squircle Border
        if self.is_selected:
            pen = QPen(self.theme.thumb_border_selected, 2.0)
        else:
            pen = QPen(self.theme.thumb_border_unselected, 1.0)
        painter.strokePath(path, pen)

        # 3. Pinned Badge (★) on top-left
        if self.tab_data.get("pinned"):
            badge_x, badge_y, badge_s = 6, 6, 18
            painter.setPen(QPen(QColor(255, 255, 255, 70) if self.theme.is_dark else QColor(0, 0, 0, 30), 1.0))
            painter.setBrush(QColor(0, 0, 0, 150) if self.theme.is_dark else QColor(255, 255, 255, 200))
            painter.drawEllipse(badge_x, badge_y, badge_s, badge_s)

            painter.setPen(QColor("#FFC733") if self.theme.is_dark else QColor("#D97706"))
            font = QFont("sans-serif", 9, QFont.Weight.Bold)
            painter.setFont(font)
            painter.drawText(badge_x, badge_y, badge_s, badge_s, Qt.AlignmentFlag.AlignCenter, "★")

        # 4. Close Button (✕) on top-right when hovering
        if self.hovering:
            close_s = 18
            close_x = 140 - close_s - 6
            close_y = 6
            painter.setPen(QPen(QColor(255, 255, 255, 60) if self.theme.is_dark else QColor(0, 0, 0, 30), 1.0))
            if self.close_hovering:
                painter.setBrush(QColor("#EF4444"))
            else:
                painter.setBrush(QColor(0, 0, 0, 160) if self.theme.is_dark else QColor(255, 255, 255, 200))
            painter.drawEllipse(close_x, close_y, close_s, close_s)

            painter.setPen(QColor("#FFFFFF") if (self.theme.is_dark or self.close_hovering) else QColor("#000000"))
            font = QFont("sans-serif", 8, QFont.Weight.Bold)
            painter.setFont(font)
            painter.drawText(close_x, close_y, close_s, close_s, Qt.AlignmentFlag.AlignCenter, "✕")

        painter.end()

    def mouseMoveEvent(self, event):
        pos = event.position()
        in_close = (140 - 24 <= pos.x() <= 140 - 6 and 6 <= pos.y() <= 24)
        if in_close != self.close_hovering:
            self.close_hovering = in_close
            self.update()
        super().mouseMoveEvent(event)

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            pos = event.position()
            if 140 - 24 <= pos.x() <= 140 - 6 and 6 <= pos.y() <= 24 and self.hovering:
                self.close_clicked.emit(self.tab_id)
                event.accept()
                return
            self.clicked.emit(self.tab_id)
            event.accept()
            return
        super().mousePressEvent(event)


# --- Tab Card Widget (154x126) ---
class TabCard(QWidget):
    """
    Standard card metrics:
    - Width: 154 (140 thumb + 7*2 padding)
    - Height: 126 (88 thumb + 20 title + 7*2 padding + 4 spacing)
    - Selection pill: squircle continuous curvature with translucent white background
    """
    clicked = pyqtSignal(int)
    hovered = pyqtSignal(int)
    closed = pyqtSignal(int)

    def __init__(self, tab_data, is_selected=False, theme=None, parent=None):
        super().__init__(parent)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground, True)
        self.tab_data = tab_data
        self.tab_id = tab_data.get("id")
        self.is_selected = is_selected
        self.theme = theme or get_current_theme()
        self.is_hovered = False

        self.setFixedSize(154, 126)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setMouseTracking(True)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(7, 7, 7, 7)
        layout.setSpacing(4)

        # 1. Thumbnail Container (140 x 88) with individual box-shadow
        self.thumb_container = ThumbnailWidget(tab_data, is_selected=is_selected, theme=self.theme, parent=self)
        self.thumb_container.close_clicked.connect(self.closed.emit)
        self.thumb_container.clicked.connect(self.clicked.emit)
        layout.addWidget(self.thumb_container)

        # 2. Title Row (140 x 20): Favicon (13x13) + Title (11px)
        title_row = QWidget(self)
        title_row.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground, True)
        title_row.setFixedSize(140, 20)
        title_layout = QHBoxLayout(title_row)
        title_layout.setContentsMargins(0, 0, 0, 0)
        title_layout.setSpacing(5)

        self.fav_label = QLabel(title_row)
        self.fav_label.setFixedSize(13, 13)
        self.fav_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.update_favicon()
        title_layout.addWidget(self.fav_label)

        raw_title = tab_data.get("title") or tab_data.get("url") or "New Tab"
        self.title_label = QLabel(title_row)
        self.title_label.setFixedHeight(20)
        fm = self.title_label.fontMetrics()
        elided = fm.elidedText(raw_title, Qt.TextElideMode.ElideRight, 122)
        self.title_label.setText(elided)
        title_layout.addWidget(self.title_label)

        layout.addWidget(title_row)
        self.update_style()

    def update_data(self, tab_data, is_selected=False, theme=None):
        self.tab_data = tab_data
        self.tab_id = tab_data.get("id")
        self.is_selected = is_selected
        if theme:
            self.theme = theme
        self.is_hovered = False

        self.thumb_container.update_data(tab_data, is_selected=is_selected, theme=self.theme)

        raw_title = tab_data.get("title") or tab_data.get("url") or "New Tab"
        fm = self.title_label.fontMetrics()
        elided = fm.elidedText(raw_title, Qt.TextElideMode.ElideRight, 122)
        self.title_label.setText(elided)

        self.update_favicon()
        self.update_style()

    def set_theme(self, theme: Theme):
        self.theme = theme
        self.thumb_container.set_theme(theme)
        self.update_favicon()
        self.update_style()

    def update_favicon(self):
        pix = get_favicon_pixmap(self.tab_data, size=13, globe_color=self.theme.globe_pen)
        self.fav_label.setPixmap(pix)

    def update_thumbnail(self):
        self.thumb_container.update()
        self.update_favicon()

    def set_selected(self, selected: bool):
        if self.is_selected != selected:
            self.is_selected = selected
            self.update_style()

    def update_style(self):
        self.thumb_container.set_selected(self.is_selected)
        if self.is_selected:
            self.title_label.setFont(QFont("sans-serif", 10, QFont.Weight.DemiBold))
            self.title_label.setStyleSheet(self.theme.title_selected_style)
        else:
            self.title_label.setFont(QFont("sans-serif", 10, QFont.Weight.Normal))
            self.title_label.setStyleSheet(self.theme.title_unselected_style)
        self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        rect = QRectF(0.5, 0.5, 153.0, 125.0)
        if self.is_selected:
            # Arc / macOS style continuous squircle selection pill
            path = make_superellipse_squircle(rect, 10.0, n=4.2)
            painter.fillPath(path, self.theme.pill_selected)
        elif self.is_hovered:
            path = make_superellipse_squircle(rect, 10.0, n=4.2)
            painter.fillPath(path, self.theme.pill_hover)
        painter.end()
        super().paintEvent(event)

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self.clicked.emit(self.tab_id)
        super().mousePressEvent(event)

    def enterEvent(self, event):
        self.is_hovered = True
        self.hovered.emit(self.tab_id)
        self.thumb_container.hovering = True
        self.thumb_container.update()
        self.update()
        super().enterEvent(event)

    def leaveEvent(self, event):
        self.is_hovered = False
        self.thumb_container.hovering = False
        self.thumb_container.close_hovering = False
        self.thumb_container.update()
        self.update()
        super().leaveEvent(event)


# --- Squircle Container Frame ---
class SquircleContainer(QFrame):
    """Outer container with superellipse continuous squircle corners and hairline glass rim."""
    def __init__(self, theme=None, parent=None):
        super().__init__(parent)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.theme = theme or get_current_theme()

    def set_theme(self, theme: Theme):
        self.theme = theme
        self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        rect = QRectF(1.0, 1.0, self.width() - 2.0, self.height() - 2.0)
        path = make_superellipse_squircle(rect, 14.0, n=4.2)

        # Translucent glass fill
        painter.fillPath(path, self.theme.container_bg)

        # Subtle hairline glass rim
        pen = QPen(self.theme.container_border, 1.0)
        painter.strokePath(path, pen)
        painter.end()
        super().paintEvent(event)


# --- PyQt6 Overlay Window ---
class SwitcherOverlay(QWidget):
    """
    Native floating translucent overlay panel matching macOS TabCircle:
    - Pure horizontal card strip (no header, no title, no tab counter, no clutter)
    - 14px squircle continuous dark/light glass panel with 1px hairline border
    - Outer padding: 12px, spacing between cards: 8px
    - Deep 36px blur box shadow floating above desktop
    """
    MIN_VISIBLE_MS = 180

    def __init__(self):
        super().__init__()
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint |
            Qt.WindowType.WindowStaysOnTopHint |
            Qt.WindowType.BypassWindowManagerHint |
            Qt.WindowType.Tool
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)

        if os.path.exists(ICON_PATH):
            self.setWindowIcon(QIcon(ICON_PATH))

        self.tabs = []
        self.cards = []
        self.cursor = 0
        self.theme = get_current_theme()
        self.mouse_has_moved = False
        self.initial_mouse_pos = None
        self._gen = 0
        self._shown_at = 0.0

        # Generous shadow margins so the 36px blur + 10px offset shadow never clips
        self.SHADOW_MARGIN_X = 40
        self.SHADOW_MARGIN_TOP = 28
        self.SHADOW_MARGIN_BOTTOM = 48

        outer_layout = QVBoxLayout(self)
        outer_layout.setContentsMargins(
            self.SHADOW_MARGIN_X,
            self.SHADOW_MARGIN_TOP,
            self.SHADOW_MARGIN_X,
            self.SHADOW_MARGIN_BOTTOM
        )
        outer_layout.setSpacing(0)

        # Background Frame (Squircle Glass effect)
        self.container = SquircleContainer(theme=self.theme, parent=self)
        container_layout = QVBoxLayout(self.container)
        container_layout.setContentsMargins(12, 12, 12, 12)  # kOuterPadding = 12
        container_layout.setSpacing(0)

        # Cards Scroll Area (Horizontal strip)
        self.scroll_area = QScrollArea(self.container)
        self.scroll_area.setWidgetResizable(True)
        self.scroll_area.setFrameShape(QFrame.Shape.NoFrame)
        self.scroll_area.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.scroll_area.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.scroll_area.setStyleSheet(
            "QScrollArea { background: transparent; border: none; }"
            "QScrollArea > QWidget > QWidget { background: transparent; }"
        )
        self.scroll_area.viewport().setStyleSheet("background: transparent; border: none;")

        self.cards_widget = QWidget()
        self.cards_widget.setStyleSheet("background: transparent; border: none;")
        self.cards_layout = QHBoxLayout(self.cards_widget)
        self.cards_layout.setContentsMargins(0, 0, 0, 0)
        self.cards_layout.setSpacing(8)  # kCardSpacing = 8

        self.scroll_area.setWidget(self.cards_widget)
        container_layout.addWidget(self.scroll_area)

        outer_layout.addWidget(self.container)

        # Deep soft box-shadow effect on big background container
        self.container_shadow = QGraphicsDropShadowEffect(self)
        self.container_shadow.setBlurRadius(36)
        self.container_shadow.setColor(self.theme.container_shadow)
        self.container_shadow.setOffset(0, 10)
        self.container.setGraphicsEffect(self.container_shadow)

        # Pre-allocate card pool to eliminate first-show allocation latency
        for _ in range(8):
            card = TabCard({"id": -1, "title": "", "url": "", "favIconUrl": ""}, is_selected=False, theme=self.theme, parent=self.cards_widget)
            card.clicked.connect(self.on_card_clicked)
            card.hovered.connect(self.on_card_hovered)
            card.closed.connect(self.on_card_closed)
            card.hide()
            self.cards.append(card)
            self.cards_layout.addWidget(card)

        # Signal connections
        signals.show_overlay.connect(self.do_show)
        signals.hide_overlay.connect(self.do_hide)
        signals.select_next.connect(self.select_next)
        signals.select_prev.connect(self.select_prev)
        signals.commit_switch.connect(self.commit_switch)
        signals.update_thumb.connect(self.on_thumb_updated)
        signals.update_theme.connect(self.on_theme_updated)

    def on_theme_updated(self):
        self.theme = get_current_theme()
        self.container.set_theme(self.theme)
        self.container_shadow.setColor(self.theme.container_shadow)
        for card in self.cards:
            card.set_theme(self.theme)

    def adjust_panel_size(self):
        visible_cards = max(1, min(len(self.tabs), 7))
        content_width = visible_cards * 154 + max(0, visible_cards - 1) * 8
        container_width = content_width + 24  # 12px outer padding each side
        container_height = 150                # 126px card + 12px padding each side
        self.container.setFixedSize(container_width, container_height)
        self.setFixedSize(
            container_width + self.SHADOW_MARGIN_X * 2,
            container_height + self.SHADOW_MARGIN_TOP + self.SHADOW_MARGIN_BOTTOM
        )

    def do_show(self, tabs, initial_index, anchor=None):
        logger.debug(f"do_show start +{(time.monotonic()-_t_intercept)*1000:.0f}ms")
        # Refresh theme dynamically from cache without subprocess delay
        self.theme = get_current_theme()
        self.container.set_theme(self.theme)
        self.container_shadow.setColor(self.theme.container_shadow)

        self.tabs = list(tabs)
        if not self.tabs:
            return

        if anchor is not None:
            self._last_anchor = anchor

        self.mouse_has_moved = False
        self.initial_mouse_pos = QCursor.pos()
        _switcher_dismiss_event.clear()

        self.cursor = max(0, min(initial_index, len(self.tabs) - 1))
        num_needed = len(self.tabs)

        # 1. Update existing cached cards in place (sub-millisecond fast path)
        for i in range(min(len(self.cards), num_needed)):
            self.cards[i].update_data(self.tabs[i], is_selected=(i == self.cursor), theme=self.theme)
            self.cards[i].show()

        # 2. Allocate additional cards if needed
        if num_needed > len(self.cards):
            for i in range(len(self.cards), num_needed):
                card = TabCard(self.tabs[i], is_selected=(i == self.cursor), theme=self.theme, parent=self.cards_widget)
                card.clicked.connect(self.on_card_clicked)
                card.hovered.connect(self.on_card_hovered)
                card.closed.connect(self.on_card_closed)
                self.cards.append(card)
                self.cards_layout.addWidget(card)

        # 3. Hide any extra unused cards
        for i in range(num_needed, len(self.cards)):
            self.cards[i].hide()

        self.adjust_panel_size()
        self.center_on_screen(anchor)
        self.show()
        self.raise_()
        self._gen += 1
        self._shown_at = time.monotonic()
        self.ensure_cursor_visible()
        self.repaint()
        QApplication.processEvents()
        try:
            QGuiApplication.sync()
        except Exception:
            pass
        logger.debug(f"do_show done  +{(time.monotonic()-_t_intercept)*1000:.0f}ms")

    def park(self):
        self.move(-10000, -10000)

    def do_hide(self):
        gen = self._gen
        left = self.MIN_VISIBLE_MS - (time.monotonic() - self._shown_at) * 1000
        if left > 0:
            QTimer.singleShot(int(left), lambda: gen == self._gen and self.park())
        else:
            self.park()

    def center_on_screen(self, anchor=None):
        if anchor is not None:
            self._last_anchor = anchor
        info = anchor or getattr(self, "_last_anchor", None)

        c = None
        s_name = None
        if isinstance(info, dict):
            c = info.get("center")
            s_name = info.get("screen_name")
        elif isinstance(info, (tuple, list)):
            c = info

        target_screen = None

        # 1. Exact match by XRandR monitor output name (e.g. 'eDP-1-0', 'HDMI-1', 'DP-1')
        if s_name:
            for s in QGuiApplication.screens():
                if s.name() == s_name:
                    target_screen = s
                    break

        # 2. Geometric match accounting for fractional DPR
        if not target_screen and c:
            cx, cy = c
            for s in QGuiApplication.screens():
                dpr = s.devicePixelRatio()
                geo = s.geometry()
                phys_left = round(geo.x() * dpr)
                phys_top = round(geo.y() * dpr)
                phys_right = round((geo.x() + geo.width()) * dpr)
                phys_bottom = round((geo.y() + geo.height()) * dpr)
                if phys_left <= cx < phys_right and phys_top <= cy < phys_bottom:
                    target_screen = s
                    break
            if not target_screen:
                dpr = QApplication.primaryScreen().devicePixelRatio() or 1.0
                target_screen = QGuiApplication.screenAt(QPoint(int(cx / dpr), int(cy / dpr)))

        if not target_screen:
            target_screen = QGuiApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()

        if c:
            cx, cy = c
            logger.debug(f"Multi-monitor anchor: cx={cx}, cy={cy}, name={s_name} -> matched screen: {target_screen.name() if target_screen else 'primary'}")

        if target_screen:
            screen_geo = target_screen.availableGeometry()
            x = screen_geo.x() + (screen_geo.width() - self.width()) // 2
            y = screen_geo.y() + (screen_geo.height() - self.height()) // 2
            self.move(x, y)

    def select_next(self):
        if not self.tabs:
            return
        self.set_cursor((self.cursor + 1) % len(self.tabs))

    def select_prev(self):
        if not self.tabs:
            return
        self.set_cursor((self.cursor - 1) % len(self.tabs))

    def set_cursor(self, new_index):
        active_count = len(self.tabs)
        if active_count == 0:
            return
        if 0 <= self.cursor < min(len(self.cards), active_count):
            self.cards[self.cursor].set_selected(False)
        self.cursor = max(0, min(new_index, active_count - 1))
        if 0 <= self.cursor < min(len(self.cards), active_count):
            self.cards[self.cursor].set_selected(True)
            self.ensure_cursor_visible()

    def ensure_cursor_visible(self):
        if 0 <= self.cursor < len(self.cards):
            card = self.cards[self.cursor]
            self.scroll_area.ensureWidgetVisible(card, 50, 0)

    def on_card_hovered(self, tab_id):
        # Ignore hover until pointer has intentionally moved > 6px to avoid stealing selection on open
        if not self.mouse_has_moved:
            if self.initial_mouse_pos is not None:
                curr_pos = QCursor.pos()
                if (curr_pos - self.initial_mouse_pos).manhattanLength() > 6:
                    self.mouse_has_moved = True
                else:
                    return
            else:
                return

        for idx, t in enumerate(self.tabs):
            if t.get("id") == tab_id:
                if idx != self.cursor:
                    self.set_cursor(idx)
                break

    def on_card_clicked(self, tab_id):
        logger.info(f"Card clicked: tab {tab_id}")
        self.do_hide()
        _switcher_dismiss_event.set()
        emergency_ungrab()
        send_switch_command(tab_id)

    def on_card_closed(self, tab_id):
        logger.info(f"Closing tab {tab_id}")
        send_close_command(tab_id)

        target_idx = -1
        for idx, t in enumerate(self.tabs):
            if t.get("id") == tab_id:
                target_idx = idx
                break
        if target_idx != -1:
            self.tabs.pop(target_idx)

        if len(self.tabs) <= 1:
            _switcher_dismiss_event.set()
            self.do_hide()
            return

        self.cursor = min(self.cursor, len(self.tabs) - 1)
        self.do_show(self.tabs, self.cursor)

    def commit_switch(self):
        if 0 <= self.cursor < len(self.tabs):
            selected_tab = self.tabs[self.cursor]
            target_id = selected_tab.get("id")
            if target_id is not None:
                logger.info(f"Committing switch to tab {target_id}")
                send_switch_command(target_id)

    def on_thumb_updated(self, tab_id):
        tab_scaled_pixmaps.pop(tab_id, None)
        for card in self.cards:
            if card.tab_id == tab_id:
                card.update_thumbnail()
                break


# --- Thread-Safe Extension Communication ---
def send_switch_command(tab_id: int):
    """Safely dispatches the tab switch command to the asyncio WebSocket loop."""
    logger.info(f"Executing switch command -> tabId {tab_id}")
    if ws_loop and ws_loop.is_running():
        asyncio.run_coroutine_threadsafe(
            broadcast_message({"type": "switch", "tabId": int(tab_id)}),
            ws_loop
        )
    else:
        logger.warning("Cannot send switch command: WebSocket loop is not running.")

def send_close_command(tab_id: int):
    """Safely dispatches the tab close command to the extension."""
    logger.info(f"Executing close command -> tabId {tab_id}")
    if ws_loop and ws_loop.is_running():
        asyncio.run_coroutine_threadsafe(
            broadcast_message({"type": "close", "tabId": int(tab_id)}),
            ws_loop
        )
    else:
        logger.warning("Cannot send close command: WebSocket loop is not running.")

async def broadcast_message(msg_dict):
    """Sends a JSON message to all connected extension clients."""
    if not ws_clients:
        logger.warning("No extension connected to receive message!")
        return
    msg = json.dumps(msg_dict)
    for client in list(ws_clients):
        try:
            await client.send(msg)
            logger.debug(f"Message sent to extension: {msg}")
        except Exception as e:
            logger.error(f"Failed to send to client: {e}")

# --- WebSocket Server ---
async def ws_handler(websocket):
    global cached_tabs, cached_window_id
    # Security: Validate Origin to prevent Cross-Site WebSocket Hijacking (CSWSH) across websockets library versions
    origin = getattr(websocket, 'origin', None)
    if not origin:
        try:
            if hasattr(websocket, 'request') and websocket.request and hasattr(websocket.request, 'headers'):
                origin = websocket.request.headers.get("Origin")
            elif hasattr(websocket, 'request_headers'):
                origin = websocket.request_headers.get("Origin")
        except Exception:
            pass

    if origin and not origin.startswith("chrome-extension://"):
        logger.warning(f"Rejected unauthorized WebSocket connection from origin: {origin}")
        await websocket.close(1008, "Unauthorized origin")
        return

    logger.info("Chrome Extension connected.")
    ws_clients.add(websocket)
    global helper_config
    helper_config = load_helper_config()

    # Initial handshake (tabLifetimeHours: 0 disables idle closing until settings UI is added)
    try:
        await websocket.send(json.dumps({
            "type": "settings",
            "scopeToWindow": True,
            "tabLifetimeHours": 0,
            "captureThumbnails": not helper_config.get("low_resource_mode", False)
        }))
        await websocket.send(json.dumps({"type": "requestTheme"}))
        await websocket.send(json.dumps({"type": "requestMRU"}))
    except Exception as e:
        logger.error(f"Error in handshake: {e}")

    try:
        async for message in websocket:
            try:
                data = json.loads(message)
                msg_type = data.get("type", "unknown")

                if msg_type == "theme":
                    is_dark = data.get("isDark")
                    set_theme_mode(is_dark)

                elif msg_type == "mru":
                    if "isDark" in data:
                        set_theme_mode(data.get("isDark"))
                    raw_tabs = data.get("tabs", [])
                    cached_window_id = data.get("currentWindowId", -1)
                    cached_tabs = raw_tabs
                    save_cached_tabs(raw_tabs, cached_window_id)

                    # Memory leak prevention: prune stale thumbnails and favicons for closed tabs
                    active_ids = {t.get("id") for t in raw_tabs if t.get("id") is not None}
                    stale_thumbs = [tid for tid in list(tab_thumbnail_images.keys()) if tid not in active_ids]
                    for tid in stale_thumbs:
                        tab_thumbnail_images.pop(tid, None)
                        tab_scaled_pixmaps.pop(tid, None)
                    stale_favs = [tid for tid in list(cached_favicons.keys()) if tid not in active_ids]
                    for tid in stale_favs:
                        cached_favicons.pop(tid, None)
                        cached_favicon_images.pop(tid, None)

                    logger.info(f"MRU update: {len(raw_tabs)} tabs (window: {cached_window_id}). Pruned {len(stale_thumbs)} stale cached items.")
                    signals.update_mru.emit(raw_tabs, cached_window_id)

                elif msg_type == "thumb":
                    if helper_config.get("low_resource_mode", False):
                        continue
                    tab_id = data.get("tabId")
                    raw_b64 = data.get("data", "")
                    if tab_id is not None and raw_b64:
                        try:
                            if "," in raw_b64:
                                raw_b64 = raw_b64.split(",", 1)[1]
                            img_bytes = base64.b64decode(raw_b64)
                            qimg = QImage.fromData(img_bytes)
                            if not qimg.isNull():
                                # Thread-safe: store QImage in worker thread; convert to QPixmap on GUI thread
                                tab_thumbnail_images[tab_id] = qimg
                                signals.update_thumb.emit(tab_id)
                        except Exception as e:
                            logger.error(f"Error decoding thumbnail for tab {tab_id}: {e}")

                elif msg_type == "requestSettings":
                    helper_config = load_helper_config()
                    await websocket.send(json.dumps({
                        "type": "settings",
                        "scopeToWindow": True,
                        "tabLifetimeHours": 0,
                        "captureThumbnails": not helper_config.get("low_resource_mode", False)
                    }))
                elif msg_type == "log":
                    logger.info(f"[Extension Log] {data.get('message')}")
            except json.JSONDecodeError:
                pass
    except websockets.exceptions.ConnectionClosed:
        logger.info("Chrome Extension disconnected.")
    finally:
        ws_clients.discard(websocket)

def start_ws_server():
    global ws_loop
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    ws_loop = loop
    try:
        server_coro = websockets.serve(ws_handler, "127.0.0.1", 41573, compression=None)
        server = loop.run_until_complete(server_coro)
        logger.info("TabCircle WebSocket server listening on ws://127.0.0.1:41573/")
        loop.run_forever()
    except OSError as e:
        if e.errno == 98:
            logger.error("Port 41573 is already in use by another instance or process.")
        else:
            logger.error(f"WebSocket server error: {e}")
        emergency_ungrab()
        os._exit(1)


# --- Xlib Keyboard Interception ---
def get_active_window_class(d, root):
    """Returns the WM_CLASS of the active window."""
    try:
        net_active_win = d.intern_atom('_NET_ACTIVE_WINDOW')
        wm_class = d.intern_atom('WM_CLASS')
        prop = root.get_full_property(net_active_win, X.AnyPropertyType)
        if not prop or not prop.value:
            return ""
        win_id = prop.value[0]
        if win_id == 0:
            return ""
        win = d.create_resource_object('window', win_id)
        cls_prop = win.get_full_property(wm_class, X.AnyPropertyType)
        if cls_prop and cls_prop.value:
            if isinstance(cls_prop.value, bytes):
                raw = cls_prop.value.decode('utf-8', errors='ignore')
            elif isinstance(cls_prop.value, str):
                raw = cls_prop.value
            else:
                raw = ""
            parts = [p.strip().lower() for p in raw.split('\x00') if p.strip()]
            return " ".join(parts)
    except Exception:
        pass
    return ""

def get_session_type():
    return os.environ.get("XDG_SESSION_TYPE", "").lower()

def browser_is_native_wayland(d, root):
    """True only if the active browser has no X11 window at all (pure Wayland client)."""
    try:
        prop = root.get_full_property(d.intern_atom('_NET_ACTIVE_WINDOW'), X.AnyPropertyType)
        return not prop or not prop.value or prop.value[0] == 0
    except Exception:
        return True

def xlib_listener():
    global _ungrab_display
    d = display.Display()
    _ungrab_display = d
    root = d.screen().root

    tab_keycode = d.keysym_to_keycode(XK.string_to_keysym("Tab"))
    ctrl_mask = X.ControlMask
    kc_ctrl_l = d.keysym_to_keycode(XK.XK_Control_L)
    kc_ctrl_r = d.keysym_to_keycode(XK.XK_Control_R)

    try:
        ctrl_keycodes = [kc for kc in d.get_modifier_mapping()[X.ControlMapIndex] if kc != 0]
    except Exception:
        ctrl_keycodes = []
    if not ctrl_keycodes:
        ctrl_keycodes = [kc_ctrl_l, kc_ctrl_r]

    def is_ctrl_physically_down():
        try:
            # 1. Authoritative check: X server pointer modifier mask
            qp = root.query_pointer()
            if qp.mask & X.ControlMask:
                return True
            # 2. Keymap bit vector check
            km = d.query_keymap()
            for kc in ctrl_keycodes:
                if km[kc // 8] & (1 << (kc % 8)):
                    return True
            return False
        except Exception:
            return True  # Be conservative: do not prematurely commit on query failure

    # Modifier masks: Normal, NumLock (Mod2), CapsLock (Lock), ScrollLock (Mod5)
    modifiers = [
        0,
        X.Mod2Mask,
        X.LockMask,
        X.Mod5Mask,
        X.Mod2Mask | X.LockMask,
        X.Mod2Mask | X.Mod5Mask,
        X.LockMask | X.Mod5Mask,
        X.Mod2Mask | X.LockMask | X.Mod5Mask
    ]

    logger.info("Xlib Listener started. Listening for Ctrl+Tab...")

    # Keysyms that should not be treated as pass-through shortcuts when held/toggled
    ignored_modifier_keysyms = {
        XK.XK_Control_L, XK.XK_Control_R,
        XK.XK_Shift_L, XK.XK_Shift_R,
        XK.XK_Alt_L, XK.XK_Alt_R,
        XK.XK_Super_L, XK.XK_Super_R,
        XK.XK_Meta_L, XK.XK_Meta_R,
        XK.XK_Hyper_L, XK.XK_Hyper_R,
        XK.XK_Caps_Lock, XK.XK_Shift_Lock,
        XK.XK_Num_Lock, XK.XK_Scroll_Lock,
        XK.XK_Mode_switch,
        0xfe03,  # ISO_Level3_Shift
        0xfe08,  # ISO_Level5_Shift
    }

    # Dynamic Window-Targeted Grab (intercepts Ctrl+Tab on child browser windows, bypassing root-level grab replay skips)
    net_active_atom = d.intern_atom('_NET_ACTIVE_WINDOW')
    try:
        root.change_attributes(event_mask=X.PropertyChangeMask)
    except Exception as e:
        logger.debug(f"Could not select PropertyChangeMask on root: {e}")

    grabbed_win_id = None

    def sync_window_grab(target_win_id):
        nonlocal grabbed_win_id
        if grabbed_win_id == target_win_id:
            return

        if grabbed_win_id is not None:
            try:
                old_win = d.create_resource_object('window', grabbed_win_id)
                for mod in modifiers:
                    old_win.ungrab_key(tab_keycode, ctrl_mask | mod)
                    old_win.ungrab_key(tab_keycode, ctrl_mask | X.ShiftMask | mod)
                logger.debug(f"Released window-targeted grab from window {grabbed_win_id:#x}")
            except Exception:
                pass
            grabbed_win_id = None

        if target_win_id:
            try:
                new_win = d.create_resource_object('window', target_win_id)
                cls_prop = new_win.get_wm_class()
                if cls_prop:
                    wm_str = " ".join(cls_prop).lower()
                    if any(b in wm_str for b in BROWSER_CLASSES):
                        for mod in modifiers:
                            new_win.grab_key(tab_keycode, ctrl_mask | mod, False, X.GrabModeAsync, X.GrabModeSync)
                            new_win.grab_key(tab_keycode, ctrl_mask | X.ShiftMask | mod, False, X.GrabModeAsync, X.GrabModeSync)
                        grabbed_win_id = target_win_id
                        logger.debug(f"Attached window-targeted grab to {wm_str} ({target_win_id:#x})")
                    else:
                        logger.debug(f"Target window {target_win_id:#x} ({wm_str}) is not a browser; grab disarmed")
                else:
                    logger.debug(f"Target window {target_win_id:#x} has no WM_CLASS; grab disarmed")
            except Exception as e:
                logger.debug(f"Could not grab window {target_win_id:#x}: {e}")
        d.flush()

    try:
        init_prop = root.get_full_property(net_active_atom, X.AnyPropertyType)
        if init_prop and init_prop.value:
            sync_window_grab(init_prop.value[0])
    except Exception:
        pass

    while True:
        try:
            event = d.next_event()

            if getattr(event, 'send_event', False):
                continue

            if event.type == X.PropertyNotify and event.atom == net_active_atom:
                try:
                    p = root.get_full_property(net_active_atom, X.AnyPropertyType)
                    wid = p.value[0] if (p and p.value) else None
                    sync_window_grab(wid)
                except Exception:
                    pass
                continue

            if event.type in (X.KeyPress, X.KeyRelease):
                logger.debug(f"X key {'press' if event.type == X.KeyPress else 'release'} "
                             f"detail={event.detail} state={event.state:#06x}")

            if event.type == X.KeyPress and event.detail == tab_keycode:
                active_class = get_active_window_class(d, root)
                is_browser = any(b in active_class for b in BROWSER_CLASSES)

                # Filter tabs by scope (current window if available)
                tabs_to_show = cached_tabs
                if cached_window_id != -1:
                    scoped = [t for t in cached_tabs if t.get("windowId") == cached_window_id]
                    if scoped:
                        tabs_to_show = scoped

                # If active app is not a browser, extension is offline, or no tabs exist:
                # Replay this key event directly to the focused app untouched via XReplayKeyboard
                if not is_browser or not ws_clients or not tabs_to_show:
                    logger.debug(f"REPLAY is_browser={is_browser} class={active_class!r} "
                                 f"ws={len(ws_clients)} tabs={len(tabs_to_show)}")
                    d.allow_events(X.ReplayKeyboard, event.time)
                    d.flush()
                    continue

                logger.info(f"Ctrl+Tab intercepted in browser ({active_class}).")

                # Sample active browser window tab-strip in real time for 0-latency theme detection
                global _live_dark, _t_intercept
                s = sample_browser_is_dark(d, root)
                if s is not None:
                    _live_dark = s

                is_shift = bool(event.state & X.ShiftMask)
                initial_index = (len(tabs_to_show) - 1) if (is_shift and len(tabs_to_show) > 1) else (1 if len(tabs_to_show) > 1 else 0)

                # Compute active window center in physical X11 coordinates and match to XRandR monitor
                win_center = None
                win_screen_name = None
                try:
                    target_win = grabbed_win_id
                    if not target_win:
                        p = root.get_full_property(net_active_atom, X.AnyPropertyType)
                        if p and p.value:
                            target_win = p.value[0]
                    if target_win:
                        w_obj = d.create_resource_object('window', target_win)
                        g = w_obj.get_geometry()
                        pos = w_obj.translate_coords(root, 0, 0)
                        win_center = (-pos.x + g.width // 2, -pos.y + g.height // 2)

                        # Match active window center to XRandR output monitor name
                        try:
                            res = randr.get_screen_resources(root)
                            for o in res.outputs:
                                o_info = randr.get_output_info(root, o, res.config_timestamp)
                                if o_info.crtc:
                                    c_info = randr.get_crtc_info(root, o_info.crtc, res.config_timestamp)
                                    if (c_info.x <= win_center[0] < c_info.x + c_info.width and
                                        c_info.y <= win_center[1] < c_info.y + c_info.height):
                                        win_screen_name = o_info.name
                                        break
                        except Exception:
                            pass
                except Exception as e:
                    logger.debug(f"Failed to compute active window center: {e}")

                _switcher_dismiss_event.clear()
                _t_intercept = time.monotonic()
                signals.show_overlay.emit(tabs_to_show, initial_index, {"center": win_center, "screen_name": win_screen_name})

                # Safely grab keyboard for interactive navigation and swallow initial Tab
                grab_status = root.grab_keyboard(False, X.GrabModeAsync, X.GrabModeAsync, X.CurrentTime)
                d.allow_events(X.AsyncKeyboard, X.CurrentTime)
                d.flush()

                if grab_status != X.GrabSuccess:
                    logger.error(f"Failed to grab keyboard (status: {grab_status}). Switching directly.")
                    signals.hide_overlay.emit()
                    if len(tabs_to_show) > 1:
                        send_switch_command(tabs_to_show[initial_index].get("id"))
                    continue

                committed = False
                cancelled = False
                pass_through_key = None
                start_time = time.time()

                try:
                    while True:
                        now = time.time()
                        # 1. Safety watchdog: maximum 15s in interactive switcher grab
                        if now - start_time > 15.0:
                            logger.warning("Switcher grab safety watchdog (15s) triggered.")
                            committed = True
                            break

                        # 2. Check GUI dismissal (e.g. user clicked a card with the mouse)
                        if _switcher_dismiss_event.is_set():
                            cancelled = True
                            break

                        # 3. Drain and process queued keyboard events FIRST
                        while d.pending_events():
                            ev = d.next_event()
                            if getattr(ev, 'send_event', False):
                                continue

                            if ev.type == X.KeyRelease:
                                sym = d.keycode_to_keysym(ev.detail, 0)
                                if sym in (XK.XK_Control_L, XK.XK_Control_R) or ev.detail in ctrl_keycodes:
                                    committed = True
                                    break
                            elif ev.type == X.KeyPress:
                                if ev.detail == tab_keycode:
                                    logger.debug(f"Tab in loop   +{(time.monotonic()-_t_intercept)*1000:.0f}ms")
                                    if ev.state & X.ShiftMask:
                                        signals.select_prev.emit()
                                    else:
                                        signals.select_next.emit()
                                else:
                                    sym = d.keycode_to_keysym(ev.detail, 0)
                                    if sym in (XK.XK_Left, XK.XK_Up):
                                        signals.select_prev.emit()
                                    elif sym in (XK.XK_Right, XK.XK_Down):
                                        signals.select_next.emit()
                                    elif sym in (XK.XK_Return, XK.XK_KP_Enter, XK.XK_space):
                                        committed = True
                                        break
                                    elif sym == XK.XK_Escape:
                                        cancelled = True
                                        break
                                    elif (
                                        sym not in ignored_modifier_keysyms
                                        and ev.detail not in ctrl_keycodes
                                        and ev.detail != 66
                                    ):
                                        # Other shortcut key pressed (e.g. 'w' for Ctrl+W or 't' for Ctrl+T):
                                        # Cancel switcher, ungrab immediately, and replay keypress to browser!
                                        cancelled = True
                                        pass_through_key = (ev.detail, ev.state)
                                        break

                        if committed or cancelled or _switcher_dismiss_event.is_set():
                            break

                        # 4. Check if Ctrl is still physically held (with a 60ms grace period so initial tap doesn't race)
                        if (now - start_time > 0.06) and not is_ctrl_physically_down():
                            committed = True
                            break

                        time.sleep(0.01)  # 10ms poll
                finally:
                    # Guaranteed release of keyboard grab and thaw
                    try:
                        d.allow_events(X.AsyncKeyboard, X.CurrentTime)
                        d.ungrab_keyboard(X.CurrentTime)
                        d.flush()
                    except Exception as e:
                        logger.error(f"Error ungrabbing keyboard: {e}")

                    signals.hide_overlay.emit()

                    if committed and not cancelled and not _switcher_dismiss_event.is_set():
                        signals.commit_switch.emit()
                    elif pass_through_key:
                        # Replay non-navigation shortcut (like Ctrl+W or Ctrl+T)
                        key_detail, key_state = pass_through_key
                        logger.info(f"Replaying shortcut keycode {key_detail} (Ctrl held: {bool(key_state & X.ControlMask)})")
                        xtest.fake_input(d, X.KeyPress, key_detail)
                        xtest.fake_input(d, X.KeyRelease, key_detail)
                        d.flush()

                    # Re-sync window grab in case active window changed while overlay was open
                    try:
                        p = root.get_full_property(net_active_atom, X.AnyPropertyType)
                        wid = p.value[0] if (p and p.value) else None
                        sync_window_grab(wid)
                    except Exception:
                        pass

        except (Xlib.error.BadWindow, Xlib.error.BadDrawable, Xlib.error.BadMatch) as e:
            logger.debug(f"Transient X11 window error in listener loop: {e}")
            try:
                p = root.get_full_property(net_active_atom, X.AnyPropertyType)
                wid = p.value[0] if (p and p.value) else None
                sync_window_grab(wid)
            except Exception:
                pass
            continue
        except Exception as e:
            logger.error(f"Unhandled error in Xlib listener: {e}")
            try:
                d.allow_events(X.AsyncKeyboard, X.CurrentTime)
            except Exception:
                pass
            emergency_ungrab()


# --- Main Application Entry ---
def main():
    # Detect pure Wayland without XWayland/DISPLAY
    if get_session_type() == "wayland" and not os.environ.get("DISPLAY"):
        logger.error(
            "No X11 display found (pure Wayland, no XWayland). TabCircle needs "
            "your browser to run under XWayland. Add this launch flag to your "
            "browser shortcut: --ozone-platform=x11\n"
            "See: https://github.com/sniperravan/TabCircle#wayland"
        )
        sys.exit(1)

    # 0. Ensure single instance and terminate any stale zombie background instances
    ensure_single_instance()

    # Signal handlers for clean shutdown and guaranteed ungrab
    def cleanup_and_exit(signum, frame):
        logger.info("Interrupt signal received. Cleaning up X11 grabs and exiting...")
        emergency_ungrab()
        QApplication.quit()
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup_and_exit)
    signal.signal(signal.SIGTERM, cleanup_and_exit)

    # 1. Start WebSocket Server Thread
    ws_thread = threading.Thread(target=start_ws_server, daemon=True)
    ws_thread.start()

    # 2. Start Xlib Keyboard Listener Thread
    xlib_thread = threading.Thread(target=xlib_listener, daemon=True)
    xlib_thread.start()

    # 3. Start PyQt6 GUI Application
    app = QApplication(sys.argv)
    app.setApplicationName("TabCircle")
    if os.path.exists(ICON_PATH):
        app.setWindowIcon(QIcon(ICON_PATH))

    # 4. Check for updates in background (non-blocking)
    try:
        from update_checker import check_for_update, current_version
        logger.info(f"TabCircle v{current_version()} starting")
        threading.Thread(target=check_for_update, daemon=True).start()

        update_timer = QTimer()
        update_timer.timeout.connect(lambda: threading.Thread(target=check_for_update, daemon=True).start())
        update_timer.start(6 * 3600 * 1000)  # re-check every 6h (throttled to once/day)
    except Exception as e:
        logger.debug(f"Update checker setup note: {e}")

    # Warm up FreeType font metrics and FontConfig cache to avoid first-paint latency
    dummy_lbl = QLabel()
    dummy_lbl.fontMetrics().elidedText("Warmup", Qt.TextElideMode.ElideRight, 100)

    # Periodic timer to allow Python interpreter to process POSIX signals (Ctrl+C)
    sig_timer = QTimer()
    sig_timer.timeout.connect(lambda: None)
    sig_timer.start(200)

    # Periodic timer to instantly detect browser profile theme toggles in background
    theme_timer = QTimer()
    theme_timer.timeout.connect(get_current_theme)
    theme_timer.start(500)

    overlay = SwitcherOverlay()
    # Pre-map window off-screen once at startup so it remains mapped; showing it is just a move()
    overlay.park()
    overlay.show()
    QApplication.processEvents()

    sys.exit(app.exec())

if __name__ == "__main__":
    main()
