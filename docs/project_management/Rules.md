# Rules & Constraints

## 1. Coding Conventions
- **Python (Linux Helper):** Follow PEP 8. Use `asyncio` for WebSocket concurrency to avoid blocking the UI thread (PyQt6). 
- **JavaScript (Extension):** Keep it Vanilla JS. No heavy frameworks (React, Vue, etc.).
- **Relative Paths:** Never hardcode absolute system paths (e.g. system root or user home directories). Always use relative paths (`../src`, `./components`, `os.path.dirname(__file__)`) relative to the project or file location.

## 2. Constraints & Boundaries
- **Extension Integrity:** The core logic of the `extension/` directory is highly optimized for performance and memory. Modify it *only* if explicitly necessary to support the Linux Helper. The extension must remain compatible with the original macOS helper if possible.
- **AI Boundaries:** Read PRD and Architecture before suggesting structural changes. Do not introduce new technologies (e.g., Rust, Electron) without explicit user permission, as Python+PyQt6 has been locked in the Architecture.md.

## 3. Libraries to Avoid
- Avoid `pynput` if it causes X11 lockups during global grabs. Prefer raw `xlib` or `evdev` for safer key interception on Linux.
- Avoid heavy JS libraries in the extension.

## 4. UI/UX Rules
- Maintain the visual design established in the macOS version (rounded corners, dark/light theme, thumbnail grid). Do not redesign the interface.
