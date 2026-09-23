# Delivery Phases

## Phase 1: Planning & Setup (Current)
- Rename project to TabCircle.
- Put the files (docs/project_managment/*.md) files in the .gitignore.
- Rename all the chinese langs into English.
- So, there should be no lifedever's name in the project anywhere.
- And for proper big changes and all which is necessary for git commit properly no ai sloppy type commits and the git add and commits should be proper so that it didn't became bloated but whcih helps. 
- Update documentation and references.
- Establish PRD, Architecture, Rules, and Design specs.

## Phase 2: Linux Helper Skeleton
- Create Python `linux-helper/` project.
- Implement the WebSocket server (`ws://127.0.0.1:41573`).
- Verify successful connection between the existing Chrome extension and the Python server.

## Phase 3: Input Interception
- Implement Linux-native keyboard interception.
- Detect when Chromium is the active window.
- Successfully capture `Ctrl+Tab` without passing it to the OS, but only when Chromium is focused.

## Phase 4: UI Overlay Implementation
- Build the PyQt6 borderless, transparent window.
- Replicate the macOS thumbnail grid design.
- Implement data binding (render UI based on WebSocket messages from the extension).
- Add keyboard/mouse navigation within the PyQt6 UI.

## Phase 5: Polish & Distribution
- Handle multi-monitor positioning (center on active Chromium window).
- Add startup scripts/systemd services to run the helper in the background.
- Final testing on X11 and Wayland environments.
