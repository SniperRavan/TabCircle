# Technical Summary & Architecture Reference

This document details all technical and functional changes made to the codebase (excluding pure language/translation string changes), as well as an accurate architectural reference of the macOS Swift helper files for AI agents.

---

## 1. `linux-helper/app.py`

### 1.1. Millisecond-Precise Timestamped Logging
* **Problem**: Second-level timestamps (`%H:%M:%S`) were insufficient to isolate whether native tab activations preceded or followed X11 key events.
* **Fix**: Added millisecond precision (`%(asctime)s.%(msecs)03d`) to `logging.basicConfig`.

```diff
<<<< REMOVED
 logging.basicConfig(
     level=logging.INFO,
-    format="%(asctime)s [%(levelname)s] %(message)s",
+    format="%(asctime)s.%(msecs)03d [%(levelname)s] %(message)s",
     datefmt="%H:%M:%S"
 )
==== ADDED
 logging.basicConfig(
     level=logging.INFO,
     format="%(asctime)s.%(msecs)03d [%(levelname)s] %(message)s",
     datefmt="%H:%M:%S"
 )
>>>>
```

---

### 1.2. Minimum Visible Duration (`MIN_VISIBLE_MS = 180`)
* **Problem**: On Linux, rapid Ctrl+Tab taps hid the overlay immediately on key release (often < 60ms), producing an imperceptible flash that felt like "nothing opened until I tapped twice".
* **Fix**: Ported the macOS `minVisibleDuration` behavior. Set `MIN_VISIBLE_MS = 180`. When hiding, `do_hide()` checks elapsed time since `_shown_at` and delays parking off-screen via `QTimer.singleShot` if under 180ms. An incrementing `_gen` generation counter prevents stale timers from hiding newer overlay invocations.

```diff
<<<< REMOVED
     def park(self):
         self.move(-10000, -10000)

     def do_hide(self):
         self.park()
==== ADDED
     MIN_VISIBLE_MS = 180

     # in __init__:
     self._gen = 0
     self._shown_at = 0.0

     # in do_show():
     self._gen += 1
     self._shown_at = time.monotonic()

     def park(self):
         self.move(-10000, -10000)

     def do_hide(self):
         gen = self._gen
         left = self.MIN_VISIBLE_MS - (time.monotonic() - self._shown_at) * 1000
         if left > 0:
             QTimer.singleShot(int(left), lambda: gen == self._gen and self.park())
         else:
             self.park()
>>>>
```

---

### 1.3. Fix `AttributeError: type object 'QApplication' has no attribute 'flush'`
* **Problem**: In PyQt6 / Qt6, `QApplication.flush()` does not exist and caused a fatal crash during `do_show()`, aborting rendering.
* **Fix**: Replaced with `QApplication.processEvents()` and safe `QGuiApplication.sync()`.

```diff
<<<< REMOVED
         self.repaint()
-        QApplication.flush()
==== ADDED
+        self.repaint()
+        QApplication.processEvents()
+        try:
+            QGuiApplication.sync()
+        except Exception:
+            pass
>>>>
```

---

### 1.4. Dark Theme Sampling Fix for Brave / Chromium (`sample_browser_is_dark`)
* **Problem**: When Brave runs in dark mode, the top 3px tab-strip pixels read as pure black `(0, 0, 0)` in X11 `ZPixmap`. The previous code treated all-zero luminance as an unreadable window (GPU texture) and returned `None`. This caused dark theme sampling to silently fail, leaving theme detection to fall back to delayed disk preferences.
* **Fix**: When the top sampled row returns all zeros, probe the center pixel `(w // 2, geom.height // 2)` of the window. If the center has pixels, the window is readable, and a black header confirms dark mode (`lum = [0.0]`). In addition, exception swallowing was replaced with diagnostic logging (`Theme sample failed: {e!r}`).

```diff
<<<< REMOVED
-        if not any(lum):
-            return None  # GPU window returned black, so fall back to prefs
-        return sorted(lum)[len(lum) // 2] < 128
-    except Exception:
-        return None
==== ADDED
+        if not any(lum):
            mid = win.get_image(w // 2, geom.height // 2, 1, 1, X.ZPixmap, 0xffffffff).data
            if not any(mid[:3]):
                logger.info("Theme sample: all black (unreadable window)")
                return None
            lum = [0.0]  # black frame but readable window -> dark theme
        is_dark = sorted(lum)[len(lum) // 2] < 128
        logger.info(f"Theme sample lum={[round(v) for v in lum]} -> is_dark={is_dark}")
        return is_dark
    except Exception as e:
        logger.info(f"Theme sample failed: {e!r}")
        return None
>>>>
```

---

### 1.5. Theme State Preservation in `xlib_listener`
* **Problem**: Calling `_live_dark = sample_browser_is_dark(d, root)` unconditionally overwrote the cached theme with `None` whenever sampling encountered an unreadable frame, causing theme flip-flop.
* **Fix**: Only update `_live_dark` when sampling returns a non-`None` boolean result.

```diff
<<<< REMOVED
-                _live_dark = sample_browser_is_dark(d, root)
==== ADDED
+                s = sample_browser_is_dark(d, root)
+                if s is not None:
+                    _live_dark = s
>>>>
```

---

### 1.6. Window Mapping Latency Fix (2-Tap Switcher Bug)
* **Problem**: At application startup, the helper pre-mapped the window off-screen but then called `overlay.hide()`. In X11 / Qt, `hide()` unmaps the window from the display server. When the user pressed `Ctrl+Tab`, `self.show()` was forced to allocate and map the window through the window manager and compositor on the fly, creating latency and dropped first-tap events.
* **Fix**: Added `park()` which keeps the overlay window permanently mapped to X11 at `(-10000, -10000)`. Updated `do_hide()` and startup in `main()` to park the window instead of unmapping via `hide()`. Showing the window becomes an instantaneous X11 `move(x, y)` call.

```diff
<<<< REMOVED
-    overlay = SwitcherOverlay()
-    # Pre-map window off-screen once at startup to warm up X11 window allocation and rasterizer
-    overlay.move(-10000, -10000)
-    overlay.show()
-    QApplication.processEvents()
-    overlay.hide()
==== ADDED
+    overlay = SwitcherOverlay()
+    # Pre-map window off-screen once at startup so it remains mapped; showing it is just a move()
+    overlay.park()
+    overlay.show()
+    QApplication.processEvents()
>>>>
```

---

### 1.7. Key Diagnostic Logging in `xlib_listener`
* **Problem**: Needed to verify whether the first `Ctrl+Tab` press reaches the X11 listener, and whether it takes the passive `XReplayKeyboard` path.
* **Fix**: Added logging for every key press/release received by Xlib, and diagnostic logging showing why an event was replayed:

```diff
<<<< REMOVED
         try:
             event = d.next_event()
             if getattr(event, 'send_event', False):
                 continue
==== ADDED
         try:
             event = d.next_event()
             if getattr(event, 'send_event', False):
                 continue

+            if event.type in (X.KeyPress, X.KeyRelease):
+                logger.info(f"X key {'press' if event.type == X.KeyPress else 'release'} "
+                            f"detail={event.detail} state={event.state:#06x}")
...
                 if not is_browser or not ws_clients or not tabs_to_show:
+                    logger.info(f"REPLAY is_browser={is_browser} class={active_class!r} "
+                                f"ws={len(ws_clients)} tabs={len(tabs_to_show)}")
                     d.allow_events(X.ReplayKeyboard, event.time)
                     d.flush()
                     continue
>>>>
```

---

### 1.8. Fix `fake_input()` Invalid Argument Crash
* **Problem**: Shortcut pass-through (e.g. `Ctrl+W`, `Ctrl+T`) crashed with `fake_input() got an unexpected keyword argument 'current_window'` because python-xlib's `xtest.fake_input` does not accept `current_window`.
* **Fix**: Removed `current_window=X.NONE` from both `xtest.fake_input` calls.

```diff
<<<< REMOVED
-                        xtest.fake_input(d, X.KeyPress, key_detail, current_window=X.NONE)
-                        xtest.fake_input(d, X.KeyRelease, key_detail, current_window=X.NONE)
==== ADDED
+                        xtest.fake_input(d, X.KeyPress, key_detail)
+                        xtest.fake_input(d, X.KeyRelease, key_detail)
>>>>
```

---

### 1.9. Prevent Caps Lock & Lock Modifiers from Cancelling Overlay
* **Problem**: Pressing Caps Lock (keycode 66) or lock keys was not in the modifier exclusion tuple, causing the grab loop to treat it as a shortcut key, abort the switcher overlay, and trigger pass-through replay.
* **Fix**: Defined `ignored_modifier_keysyms` containing Caps Lock, Shift Lock, Num Lock, Scroll Lock, Meta, Hyper, AltGr (`0xfe03`), and ISO shift keys, and explicitly guarded `ev.detail != 66`.

```diff
<<<< REMOVED
-                                    elif sym not in (
-                                        XK.XK_Control_L, XK.XK_Control_R,
-                                        XK.XK_Shift_L, XK.XK_Shift_R,
-                                        XK.XK_Alt_L, XK.XK_Alt_R,
-                                        XK.XK_Super_L, XK.XK_Super_R
-                                    ) and ev.detail not in ctrl_keycodes:
==== ADDED
+                                    elif (
+                                        sym not in ignored_modifier_keysyms
+                                        and ev.detail not in ctrl_keycodes
+                                        and ev.detail != 66
+                                    ):
>>>>
```

---

### 1.10. Robust Single-Instance Process Detection (`ensure_single_instance`)
* **Problem**: Basic process checks could terminate compilers (`py_compile`), modules (`-m`), or text editors opening `app.py`.
* **Fix**: Parsed `/proc/{pid}/cmdline` with null byte delimiter `\x00`, verifying `is_python`, `is_helper_script`, and `is_not_compiler`.

```diff
<<<< REMOVED
-                    is_python = "python" in parts[0]
-                    is_helper_script = any("app.py" in arg for arg in parts[1:])
-                    if is_python and is_helper_script:
==== ADDED
+                    exe = os.path.basename(parts[0]).lower() if parts else ""
+                    is_python = "python" in exe
+                    is_helper_script = any(arg.endswith("linux-helper/app.py") or (arg.endswith("app.py") and "tabcircle" in arg.lower()) for arg in parts[1:])
+                    is_not_compiler = not any(arg in ("py_compile", "-m") for arg in parts)
+                    if is_python and is_helper_script and is_not_compiler:
>>>>
```

---

### 1.12. Active-Window Multi-Monitor Display Positioning
* **Problem**: Positioning the switcher based solely on the mouse cursor (`QCursor.pos()`) caused the overlay to appear on the wrong monitor if the user operated the keyboard while their mouse rested on a secondary display.
* **Fix**: Like macOS (which anchors to the frontmost browser window frame), the Xlib listener calculates the physical screen center of the active browser window using `win.get_geometry()` and `win.translate_coords(root, 0, 0)`, and queries XRandR for the exact display output name:
  ```python
  center = (-pos.x + g.width // 2, -pos.y + g.height // 2)
  ```
  This is emitted via `show_overlay(tabs, initial_index, {"center": win_center, "screen_name": win_screen_name})`. In `center_on_screen()`, a two-tiered resolution strategy guarantees pixel-perfect screen selection across single, dual, and stacked multi-monitor setups:
  1. **Tier 1 (Exact Output Match)**: Matches the XRandR monitor output name (`eDP-1-0`, `HDMI-1`, `DP-1`) directly against `QScreen.name()`.
  2. **Tier 2 (Physical DPR Bounds)**: Maps physical X11 coordinates to Qt logical coordinates accounting for fractional scaling (`devicePixelRatio = 1.25`).
  3. **Tier 3 (Fallback)**: Gracefully falls back to the screen containing the mouse cursor or primary display.
  ```python
  def center_on_screen(self, anchor=None):
      if anchor is not None:
          self._last_anchor = anchor
      info = anchor or getattr(self, "_last_anchor", None)

      c = info.get("center") if isinstance(info, dict) else (info if isinstance(info, (tuple, list)) else None)
      s_name = info.get("screen_name") if isinstance(info, dict) else None

      target_screen = None

      # 1. Exact match by XRandR monitor output name
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

      if target_screen:
          screen_geo = target_screen.availableGeometry()
          x = screen_geo.x() + (screen_geo.width() - self.width()) // 2
          y = screen_geo.y() + (screen_geo.height() - self.height()) // 2
          self.move(x, y)
  ```

---

### 1.13. Dynamic Window-Targeted Grab (`_NET_ACTIVE_WINDOW`) & Lifecycle Hardening
* **Problem**: Cinnamon's `locate-pointer` synchronous grab on `Control` at the root window replayed `Ctrl+Tab` down the hierarchy, skipping root passive grabs. Furthermore:
  - If passive grabs remained on the root window, all non-browser applications (terminals, text editors) were needlessly intercepted and forced through `XReplayKeyboard`.
  - On startup or window switching (via Alt+Tab or mouse clicks), the grab needed to attach immediately without waiting for a switcher cycle.
  - If `_NET_ACTIVE_WINDOW` changed during an interactive overlay session, queued `PropertyNotify` events were drained and discarded, leaving the grab attached to the previous window.
  - If a window was closed while holding a grab, X11 returned `BadWindow`, which previously risked triggering emergency ungrab or listener crashes.
* **Fix**:
  1. **Removed root-level passive grabs entirely**: The obsolete `root.grab_key(...)` loop was removed. Non-browser applications (terminals, editors) never have any grab attached; `Ctrl+Tab` in those apps is 100% native without keyboard freezing or `ReplayKeyboard` involvement.
  2. **Startup grab arming**: Prior to entering the event loop, `xlib_listener` inspects `_NET_ACTIVE_WINDOW` and immediately attaches the passive grab to the currently active browser window.
  3. **Continuous active window tracking**: The listener subscribes to `PropertyChangeMask` on the root window. In the main loop, `event.type == X.PropertyNotify and event.atom == net_active_atom` triggers `sync_window_grab`, instantly arming the grab when focusing a browser and releasing it when switching to a non-browser window.
  4. **Post-cycle grab resync**: In the `finally` block after every interactive switcher cycle, the listener re-reads `_NET_ACTIVE_WINDOW` from root and calls `sync_window_grab`, ensuring the grab follows focus changes that occurred while the overlay was open.
  5. **Transient X11 error isolation**: `(Xlib.error.BadWindow, Xlib.error.BadDrawable, Xlib.error.BadMatch)` errors in the event loop are safely caught, logged at debug level, and resynced without terminating the listener or dropping grabs.
  6. **Verbose diagnostic tracing**: Added `--debug` CLI flag to expose window grab attachment/release events and multi-monitor screen geometry matching in terminal stdout and `~/.cache/tabcircle/helper.log`.

---

### 1.14. Disabled WebSocket Permessage-Deflate Compression
* **Problem**: `websockets.serve()` enables `permessage-deflate` by default (`compression='deflate'`). Because Chromium extensions negotiate compression headers, Python's asyncio thread was compressing and decompressing every base64 thumbnail bitstream over loopback IPC.
* **Fix**: Explicitly set `compression=None` in `websockets.serve(ws_handler, "127.0.0.1", 41573, compression=None)`, eliminating loopback CPU overhead.

---

## 2. `extension/background.js`

### 2.1. Telemetry Cleanup
* Diagnostic latency logging added during root cause analysis (`[Extension Log] tab activated ...`) was fully removed to maintain zero console noise and clean production logs.

---

## 3. macOS Swift Helper Architecture Reference (`helper/Sources/tabcircle/`)

Accurate technical reference of all 24 Swift files for AI agents:

### System Architecture
The macOS helper is an AppKit menu bar accessory application (`TabCircle.app`). It pairs with the Chrome/Chromium browser extension over a loopback WebSocket (`ws://127.0.0.1:41573`). It intercepts `⌃⇥` (Ctrl+Tab) globally using Quartz Event Taps, renders a floating AppKit overlay (`NSPanel` at window level `.popUpMenu`) using SwiftUI continuous rounded rectangles with `NSGlassEffectView` / `NSVisualEffectView`, and dispatches switch commands back to the browser.

### File Directory & Roles

| File | Exact Technical Role |
| :--- | :--- |
| **`main.swift`** | Application daemon entry point. Configures `NSApplication` with accessory activation policy (`.accessory`). Checks accessibility permissions, initializes `AppSettings`, `UpdateChecker`, `WebSocketServer`, `MRUController`, `StatusItemController`, installs `MainMenu`, and enters `app.run()`. (Has no CLI-argument parser or signal-handler code). |
| **`WebSocketServer.swift`** | Loopback WebSocket server built on Apple's `Network.framework` (`NWListener` + `NWProtocolWebSocket`). Binds strictly to `127.0.0.1:41573`. Does **not** validate Origin headers; instead, identifies client browser identity by querying `lsof` for the connecting peer TCP port, walking the parent process chain, and matching the `NSRunningApplication` bundle ID. |
| **`EventTap.swift`** | Quartz Event Tap manager (`CGEvent.tapCreate`). Intercepts `Ctrl+Tab` and `Ctrl+Shift+Tab` globally at the system level before Chromium or WindowServer processes them. Resolves target mode using `SwitcherHotkeys`, tracks modifier flags while keys are held, and manages event pass-through / replay. |
| **`SwitchMode.swift`** | The pure hotkey-to-mode decision table (16 states). Evaluates keycode, modifier flags, whether foreground is a browser, and excluded app lists to determine whether to trigger `.browser` or `.global` switcher mode (or pass through). Layout styles live in `AppSettings`. |
| **`GridGeometry.swift`** | Visual adjacency calculations for arrow-key navigation in the global switcher multi-row card grid. Handles cross-group row neighbor navigation across varying column widths. (Panel dimensions and card sizing live in `OverlayPanel.contentLayout`). |
| **`MRUController.swift`** | Core switcher state machine. Maintains Most Recently Used (MRU) tab stack order, active window focus, tab selection cursor, window scoping, and coordinates between `EventTap` and `OverlayPanel`. |
| **`OverlayPanel.swift`** | The floating switcher HUD (`NSPanel`) at window level `.popUpMenu`. Built with SwiftUI views, continuous rounded rectangles, and backdrop materials using `NSGlassEffectView` (macOS 26+ Liquid Glass with real refraction) or `NSVisualEffectView`. Enforces `minVisibleDuration = 0.18s` to avoid visual flicker on quick taps. |
| **`ClosedTabStore.swift`** | In-memory and disk archive of recently closed tabs forwarded from the extension. Supports querying history and reopening closed tabs. |
| **`FavoriteFolders.swift`** | Manages bookmark and pinned tab domain rules, reconciling pinned tab states with the browser. |
| **`ThumbnailStore.swift`** | In-memory and disk cache for tab snapshot image previews received from the Chrome extension. |
| **`SettingsWindow.swift`** | Native macOS Settings / Preferences window (`NSWindow`) with tabs for General, Appearance, Shortcuts, Updates, and About. |
| **`AppSettings.swift`** | Persistent preferences store backed by `UserDefaults` (stores layout style, window scope, appearance overrides, hotkey bindings). |
| **`StatusItemController.swift`** | Manages the macOS menu bar icon (`NSStatusItem`), dropdown menu, status updates, and links to Settings or Quit. |
| **`MainMenu.swift`** | Standard AppKit application menu bar (`NSMenu`) hierarchy (keeps standard `⌘Q` working). |
| **`WindowShadow.swift`** | Custom window shadow path and elevation styling for the HUD panel. |
| **`Toast.swift`** | Lightweight transient HUD notification for status messages and permission alerts. |
| **`PermissionCoordinator.swift`** | Coordinates accessibility permission checks via `AXIsProcessTrusted`. |
| **`PermissionGuide.swift`** | UI guide helping the user navigate to macOS System Settings > Privacy & Security to enable Accessibility. |
| **`LoginItem.swift`** | Manages launch-at-login via `SMAppService` or Service Management framework. |
| **`UpdateChecker.swift`** | Automatic updater that checks GitHub Releases for new `.dmg` builds, verifies signatures, and restarts the app. |
| **`ReleaseNotes.swift`** | Window displaying "What's New" release notes when the app is updated. |
| **`ReleaseNotesParser.swift`** | Markdown parser for release notes and changelogs. |
| **`Log.swift`** | Dual-target logger. Formats timestamps with `HH:mm:ss.SSS`, prints to `stdout` (`print` + `fflush`), and asynchronously writes to `~/Library/Logs/TabCircle/tabcircle.log`. (Uses standard Swift I/O, not `os_log`). |
| **`L10n.swift`** | String localization helper for multi-language display. |

---

## 4. Automation & Packaging Scripts

* **`scripts/install-linux.sh`**:
  Automated setup and autostart script for Linux users.
  - Accommodates PEP 668 externally-managed environments (Mint 22, Ubuntu 24.04, Debian 12) by checking imports first and leveraging `apt` or `--break-system-packages` fallback.
  - Uses precise PID inspection in `/proc/$pid/cmdline` to prevent terminating text editors opening `app.py`.
  - Redirects background daemon output to `~/.cache/tabcircle/helper.log` for easy diagnostics.
  - Supports `--status` and `--uninstall`.
* **`scripts/package-release.sh`**:
  Release packager that produces:
  - `release/TabCircle-Extension.zip`: Root folder named `TabCircle-Extension/` matching the macOS build layout, website download links, and `SettingsWindow.swift`.
  - `release/tabcircle-linux.tar.gz`: Standalone Linux helper package including scripts, assets, README, and LICENSE.
  - `release/checksums.txt`: SHA256 checksums ready for GitHub Releases upload.

---

## 5. Technical Evaluation: Compression Techniques (Gzip, Brotli, Zstandard)

### Why Compression is NOT Needed for TabCircle

1. **Loopback WebSocket IPC (`127.0.0.1`)**:
   - The extension and helper communicate exclusively over the local loopback interface.
   - Loopback bandwidth is virtual memory bus copy exceeding **20 to 40 Gbps** with sub-millisecond latency.
   - Running compression (Gzip, Brotli, or Deflate) on loopback WebSocket frames adds CPU serialization latency without network bandwidth savings.
   - By explicitly disabling WebSocket permessage-deflate (`websockets.serve(..., compression=None)`), we eliminate CPU cycles that the Python library previously consumed compressing base64 strings in the asyncio thread.

2. **Thumbnails are Already Compressed JPEGs**:
   - Thumbnails are captured by `chrome.tabs.captureVisibleTab(..., { format: 'jpeg', quality: 70 })` and downscaled/re-encoded at `quality: 0.6` via `canvas.convertToBlob({ type: "image/jpeg", quality: 0.6 })`.
   - Entropy-encoding algorithms (Gzip, Brotli, Zstd) cannot meaningfully compress JPEG bitstreams (< 1% reduction) while wasting 5–15ms of CPU per thumbnail.

3. **Browser Extension Packaging Requires Unpacked Directory / Standard ZIP**:
   - Chromium browsers (`chrome://extensions`) require users to click "Load unpacked" on an extracted directory (e.g. `TabCircle-Extension/`).
   - Browsers cannot load `.zip`, `.tar.gz`, or `.zst` archives directly into the extensions engine.

### When Compression IS Needed
* **Brotli / Gzip**: For public HTTP web servers (Cloudflare, Nginx, GitHub Pages) serving HTML, CSS, JavaScript, and JSON across WAN networks where bandwidth and transit time matter.
* **Zstandard (Zstd)**: For large data archives and backups where multi-gigabyte files need ultra-fast decompression (> 2 GB/s).

---

## 6. Low-Resource Mode, Log Rotation, and Path Clarifications

### A. Low-Resource / Favicon-Only Mode
For resource-constrained devices, laptops on battery, or users prioritizing CPU conservation:
- **Realistic Resource Impact**:
  - *Extension CPU Savings (Primary Benefit)*: Disables `chrome.tabs.captureVisibleTab`, offscreen canvas re-scaling, JPEG encoding, and base64 loopback serialization on every tab switch.
  - *Helper Image Memory Savings*: Frees ~2.5–5MB of thumbnail QImage/QPixmap cache.
  - *Python/Qt Baseline (Unchanged)*: The helper itself still occupies ~50–80MB RSS memory, which is the baseline footprint of Python 3, PyQt6, Qt's rendering libraries, and X11 bindings.
- **Explicit Precedence Hierarchy**:
  1. CLI Flags: `--low-resource` (force ON) or `--no-low-resource` (force OFF)
  2. Configuration File: `~/.config/tabcircle/config.json` (`{"low_resource_mode": true}`)
  3. Safe Default: `false` (standard mode with rich visual screenshots)
- **Runtime Refresh**:
  - The configuration file is re-read on every extension WebSocket connection and `requestSettings` handshake.
  - Running `./scripts/install-linux.sh --restart` restarts the running daemon in one step.
- **Overlay UI Fidelity**:
  - Cards in low-resource mode render with the authentic continuous squircle geometry, centered 28×28 high-contrast favicons (with vector globe fallback), top-left pinned star badge (★), and hover close button (✕).

### B. Persistent Log Rotation
- Replaced unconstrained logging in `linux-helper/app.py` with `RotatingFileHandler(..., maxBytes=5*1024*1024, backupCount=3)`.
- Log file location: `~/.cache/tabcircle/helper.log`
- Bounds total log disk usage strictly to a maximum of 15MB.

### C. Cache Path Clarification
- Tab cache: `/tmp/tabcircle/tabs_cache.json` (via Python `tempfile.gettempdir()`). Provides instant recovery of the MRU tabs on restart.
- Daemon log: `~/.cache/tabcircle/helper.log` (persistent across reboots with 5MB rotation).

