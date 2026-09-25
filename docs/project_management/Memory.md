# Session Memory

## Current State
- **Project Name:** TabCircle
- **Author:** sniperravan
- **Phase:** Phase 4 - UI Overlay & Reliable Tab Switching

## Completed Work
- **Keyboard Freeze & Lockup Root Cause Fixed:**
  - *Root Cause Identified:* In `python-xlib`, `grab_keyboard` exists on `Window` and `Display`, but `ungrab_keyboard` **only exists on `Display`**. Calling `root.ungrab_keyboard()` threw an unhandled `AttributeError`, leaving the entire X11 server keyboard grabbed and freezing user input, window dragging, and virtual keyboards.
  - *Fix:* Replaced all ungrab calls with `d.ungrab_keyboard(X.CurrentTime)` on the Display instance.
  - *Safety Guardrails:* Added a 15-second safety watchdog timeout in the event loop, guaranteed `try...finally` ungrabs, and installed `SIGINT`/`SIGTERM` handlers to cleanly release grabs on exit.
- **Browser Shortcut Swallow Fixed (`Ctrl+W`, `Ctrl+T`):**
  - Resolved shortcut conflicts where keys were consumed while holding `Ctrl`. When any non-navigation key (e.g. `W`, `T`, `R`, letters/digits) is pressed while `Ctrl` is held, TabCircle immediately cancels the overlay, releases the X11 keyboard grab, and forwards the exact keypress to the focused browser window using `xtest.fake_input`.
- **UI Layout & Squircle Cutoff Fix:**
  - *Root Cause:* The superellipse math in `make_superellipse_squircle` previously had an inverted top-left quadrant calculation, creating an internal diagonal cut across the top of the container, cards, and selection pill.
  - *Fix:* Rebuilt `make_superellipse_squircle` using verified parametric angle tracing with seamless edge alignments.
  - *Box Shadow & Padding:* Adjusted `TabCard` spacing to 4px (exact 126px height) and enlarged `SwitcherOverlay` margins (`SHADOW_MARGIN_X = 40`, `SHADOW_MARGIN_TOP = 28`, `SHADOW_MARGIN_BOTTOM = 48`) so the 36px container drop shadow never clips against the transparent window border.
  - *Fallback Placeholders:* When screenshots are pending or unavailable, thumbnails render a centered 28x28 favicon against a clean translucent backdrop.
- **Immediate `Ctrl+C` Terminal Exit & Clean Scoping:**
  - *Fix:* Added a periodic 200ms `QTimer` waking Python interpreter bytecode and wired `cleanup_and_exit` to call `emergency_ungrab()`, `QApplication.quit()`, and `sys.exit(0)`.
  - Promoted `emergency_ungrab()` to module-level scope so signal handlers and `atexit` can invoke it cleanly without `NameError`.
- **Single-Instance Manager & Stale Process Auto-Cleanup:**
  - *Root Cause of Port 41573 In-Use & X11 BadAccess:* Stopping the helper with `Ctrl+Z` suspends the process (`SIGTSTP`) in the background instead of killing it. The zombie process continues holding port 41573 and the X11 `grab_key`, causing subsequent runs to crash with `OSError: [Errno 98] address already in use` and `Xlib.error.BadAccess`, preventing TabCircle from starting and making Brave fall back to its native next-tab switching.
  - *Fix:* Added [`ensure_single_instance()`](linux-helper/app.py#L60-L105) at startup in `main()`. It inspects `/proc/<pid>/cmdline`, detects any prior stale/stopped TabCircle helper processes, terminates them cleanly, releases port 41573 and X11 grabs, and manages a PID lockfile with automatic cleanup.
- **Thumbnail Capture & ActiveTab Handling:**
  - Added URL filtering in `captureThumbnail` in `extension/background.js` to skip browser-internal pages (`brave://`, `chrome://`, `about:`, etc.) that cannot be captured by design.
  - Added `"activeTab"` to `permissions` in `extension/manifest.json` alongside `"<all_urls>"`.
- **Synchronous X11 Key Interception & Zero-Leak Event Replay:**
  - *Root Cause of Premature Tab Switch:* Passive key grab using `X.GrabModeAsync` permitted Chromium's XInput2 pipeline to receive `Ctrl+Tab` concurrently before the helper could claim keyboard focus.
  - *Fix:* Configured `root.grab_key` with `keyboard_mode = X.GrabModeSync` for both `Ctrl+Tab` and `Ctrl+Shift+Tab`.
  - *Event Flow:*
    - If active window is not a browser, extension is disconnected (`not ws_clients`), or no tabs exist: `d.allow_events(X.ReplayKeyboard, event.time)` immediately replays the keystroke to the focused application untouched.
    - If active window is a browser with connected extension: helper calls `signals.show_overlay.emit(...)`, actively grabs keyboard via `root.grab_keyboard(...)`, and executes `d.allow_events(X.AsyncKeyboard, X.CurrentTime)` to thaw the keyboard pipeline and swallow the initial Tab keystroke.
  - *Safety:* Added `d.allow_events(X.AsyncKeyboard, X.CurrentTime)` inside `emergency_ungrab()` to guarantee the X server keyboard pipeline is never left frozen.
- **Zero-Latency Real-Time Theme Sampling (`sample_browser_is_dark`):**
  - *Root Cause of 10s Theme Latency:* Chromium batches writing `Preferences` (`color_scheme2`) roughly 10 seconds after toggling appearance in settings. Polling `Preferences` or watching `mtime` had nothing to read during those 10 seconds.
  - *Fix:* Added [`sample_browser_is_dark(d, root)`](file://linux-helper/app.py) which samples the active browser window's tab strip pixels in real time using `XGetImage` and computes relative ITU-R BT.709 luminance (`0.2126*R + 0.7152*G + 0.0722*B`).
  - *Fallbacks:* If GPU window returns all black/zeros, falls back to disk `Preferences` (with `profile.last_used` profile resolution from `Local State`), offscreen extension reporting, and OS dark mode.
  - *Decoupled State:* Separated live window sample (`_live_dark`), disk preference, and offscreen reporting to avoid stale theme lockup when browser reverts to system default (`color_scheme2 == 0`).
- **Thread-Safe Qt Rendering & Pre-Scaled Thumbnail Caching:**
  - *Root Cause of Random Crashes & Paint Jank:* `QPixmap` was being instantiated inside background worker threads (`ws_handler` and favicon fetch thread), violating Qt's GUI thread affinity on X11. Additionally, full-resolution 900px thumbnails were being smoothly rescaled on every single `paintEvent`.
  - *Fix:*
    - Separated image storage: worker threads decode into `QImage` (`tab_thumbnail_images`, `cached_favicon_images`).
    - `QPixmap` creation is strictly confined to the Qt GUI thread.
    - Pre-scales and center-crops thumbnails to 140x88 once, caching them in `tab_scaled_pixmaps[tab_id]` for `O(1)` rendering in `ThumbnailWidget.paintEvent`.
- **First-Paint Overlay Mapping & Qt6 Event Dispatch:**
  - *Root Cause of Missing/Crash on First Tap:* In PyQt6 / Qt6, `QApplication.flush()` does not exist and throws an `AttributeError`, causing `do_show()` to crash mid-paint. Consequently, the window remained unmapped to the X11 server until subsequent events.
  - *Fix:* Replaced `QApplication.flush()` with `QApplication.processEvents()` followed by `QGuiApplication.sync()` to guarantee immediate X round-trip buffer delivery.
  - *Zero-Latency Warmup:* Added an off-screen pre-map in `main()` (`overlay.move(-10000, -10000); overlay.show(); QApplication.processEvents(); overlay.hide()`) ensuring X server window structures are allocated before the user triggers `Ctrl+Tab`.
  - *Persistent Live Theme:* Removed `_live_dark = None` from `do_hide()` so sampled browser luminance persists between switches, eliminating theme flip-flop in Device mode.
  - *Clean WM_CLASS Parsing:* Split null-separated strings in `WM_CLASS` via `raw.split('\x00')` to eliminate garbled window names like `brave-originbrave-origin`.
- **UI Hover & Mouse Selection Fixes:**
  - *Hover Stealing Selection:* When the overlay opened centered under the mouse, `enterEvent` immediately triggered `set_cursor`, stealing focus. Fixed by ignoring hover until the cursor intentionally moves > 6px (`mouse_has_moved`).
  - *Mouse Click Double Commit:* Clicking a card dispatched a switch command while the Xlib grab loop was still running, causing a second commit when Ctrl was released. Fixed with `_switcher_dismiss_event = threading.Event()`, cleanly aborting the grab loop on card clicks.
  - *Scroll Visibility for > 7 Tabs:* Moved `self.ensure_cursor_visible()` after `self.show()` and `self.raise_()` so the scroll area viewport geometry is active when scrolling to the 8th tab.
- **Settings Handshake & Protocol Hardening:**
  - *tabLifetimeHours:* Set `tabLifetimeHours: 0` in helper handshake and `requestSettings` reply to prevent unintended tab closure until settings UI is added.
  - *Origin Validation:* Updated WebSocket origin validation to inspect `websocket.request.headers.get("Origin")` and `request_headers` alongside `websocket.origin`, ensuring CSWSH protection across all `websockets` versions (>= 14 compatible).
  - *PID Recycle Safety:* Narrowed `ensure_single_instance()` command-line matching to `linux-helper/app.py` and `tabcircle`, preventing unintended termination of unrelated Python scripts named `app.py`.
- **Security & Quality Audits:**
  - Full Semgrep SAST scan completed across codebase with **0 findings (0 blocking)**.
  - Extension test suite (`closed-tabs.test.js`, `lifetime-sweep.test.js`): **100% pass rate (19/19 tests)**.

- **Cinnamon Locate-Pointer Grab Bypass (Known Limitation & Solution):**
  - *Symptom:* When `org.cinnamon.desktop.peripherals.mouse locate-pointer` is `true`, the first `Ctrl+Tab` of each hold reaches the browser natively within 40ms, and the helper only activates upon auto-repeat (~496ms) or second tap.
  - *Mechanism:* Cinnamon holds a synchronous grab on `Control` at the root window. When `Tab` is pressed, Cinnamon calls `XReplayKeyboard`, which by X11 specification skips all passive grabs on that same root window. The replayed event bypasses the helper's root grab and reaches Brave directly.
  - *Fix:* Run `gsettings set org.cinnamon.desktop.peripherals.mouse locate-pointer false` to disable the pointer locator grab, or migrate the passive key grab from `root` to the active browser window.

## Next Steps
- Verify helper with quiet logging (`python3 linux-helper/app.py`).
- Validate quick tap visual persistence (>= 180ms).
