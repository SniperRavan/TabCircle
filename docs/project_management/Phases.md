# Delivery Phases

## Phase 1: Planning, Branding & Sanitization (Completed)
- [x] Configure TabCircle project structure and branding.
- [x] Add project management files and python artifacts to `.gitignore`.
- [x] Translate all documentation, comments, logs, and tests into English.
- [x] Update copyright and author information to `sniperravan`.
- [x] Replace SVG icons with `icon-128.png`.
- [x] Establish PRD, Architecture, Rules, and Design specs.

## Phase 2: Linux Helper Skeleton & Networking (Completed)
- [x] Create Python `linux-helper/` project structure and dependencies.
- [x] Implement WebSocket server (`ws://127.0.0.1:41573`).
- [x] Establish two-way communication between Chrome extension and Python server.
- [x] Fix cross-thread asyncio scheduling (`asyncio.run_coroutine_threadsafe`) so switch commands deliver reliably.

## Phase 3: Safe Input Interception (Completed)
- [x] Implement robust Linux X11 keyboard interception.
- [x] Accurately detect when a Chromium-based browser (Chrome, Brave, Edge, Chromium, etc.) is the active window.
- [x] Implement safe, non-blocking grab loop with physical modifier polling (`query_pointer`).
- [x] Eliminate system freeze risks with strict `try...finally` ungrabs, `atexit`, and signal handlers.
- [x] Passthrough `Ctrl+Tab` to non-browser applications using synthetic events.

## Phase 4: UI Overlay, Tab Switching & Stability Hardening (Completed)
- [x] Build the PyQt6 borderless, translucent switcher overlay matching native macOS TabCircle metrics (12px outer padding, 8px card spacing).
- [x] Authentic Apple continuous squircle ($n=4.2$ superellipse) clipping for outer panel and tab thumbnail cards.
- [x] Box shadows: Deep soft drop shadow (`blur=48, offset=12`) on floating container and glowing blue halo (`blur=18`) on active selection.
- [x] Render authentic tab cards (154x126) with 140x88 anti-aliased squircle thumbnails.
- [x] Implement macOS accent blue (#2C6BED) border + soft glowing halo on selected cards, with Arc-style white translucent background pill.
- [x] Top-left pinned star badge (★) with gold accent (#FFC733) and top-right close button (✕) on card hover.
- [x] Title row (140x20) with 13x13 favicon (with asynchronous loader and vector fallback) + 11px single-line elided title.
- [x] Remove bulky header bar and domain subtitles to preserve authentic minimal floating design.
- [x] Implement keyboard cycling (`Tab`, `Shift+Tab`, arrows, `Esc` cancel, `Ctrl` release to switch).
- [x] Support mouse interactions (hover selection, click to switch, click ✕ to close tab).
- [x] Real-time thumbnail decoding and caching from base64 JPEG messages.
- [x] Prevent shortcut interception: forward non-navigation keys (`Ctrl+W`, `Ctrl+T`, etc.) to the browser via `xtest.fake_input`.
- [x] Fix keyboard lockup root cause (`d.ungrab_keyboard` vs `root.ungrab_keyboard`), add 15s watchdog timer, and `SIGINT`/`SIGTERM` handlers.
- [x] Eliminate memory leaks by pruning thumbnails and favicon caches for closed tabs.
- [x] Security audit & vulnerability hardening: CSWSH origin check, SSRF-safe `http.client` favicon fetch, Semgrep 0-finding clean scan.

## Phase 5: Polish & Distribution (Next)
- [ ] Multi-monitor positioning and active window centering refinements.
- [ ] Add background desktop runner / systemd user unit / autostart `.desktop` file.
- [ ] Testing on additional Linux window managers and desktop environments.
