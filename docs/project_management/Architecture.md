# Architecture Document

## 1. System Overview
TabCircle operates in two distinct halves that communicate via a local WebSocket connection (`ws://127.0.0.1:41573`).
1. **Chrome Extension (MV3):** Manages tab states, captures screenshots, and performs the actual tab switching.
2. **Linux Helper (Native):** Intercepts global keyboard inputs and draws the UI overlay.

## 2. Tech Stack
### Extension
- **Environment:** Chromium Extension Manifest V3.
- **Languages:** HTML, CSS, Vanilla JavaScript.
- **APIs:** `chrome.tabs`, `chrome.windows`, `chrome.offscreen` (for WebSocket persistence).

### Linux Helper
- **Language:** Python 3.
- **UI Framework:** PyQt6 (for borderless, transparent, always-on-top window rendering).
- **Input Interception:**
  - `python-xlib` or `evdev` for global key interception (`Ctrl+Tab`).
  - `xprop` / `wmctrl` to determine if Chromium is the active window.
- **Networking:** `websockets` library (Asyncio based) to host the server.

## 3. Folder Structure
```text
.
├── extension/          # The Chrome MV3 Extension (Cross-platform)
├── linux-helper/       # The new Python-based Linux helper app
├── docs/               # Project documentation
│   └── project_management/ # PRD, Architecture, Rules, etc.
└── ...
```

## 4. App Flow
1. **Startup:** Helper starts WebSocket server. Extension connects.
2. **Browsing:** User browses; Extension silently builds MRU history and captures thumbnails.
3. **Trigger:** User presses `Ctrl+Tab` on Linux.
4. **Interception:** Helper detects `Ctrl+Tab`. Checks if Chromium is active. If yes, blocks key from reaching OS/Chromium.
5. **Display:** Helper displays PyQt6 overlay window.
6. **Interaction:** User cycles tabs. Helper sends `switch` commands to Extension via WebSocket.
7. **Action:** Extension calls `chrome.tabs.update` to bring the selected tab to the front.
