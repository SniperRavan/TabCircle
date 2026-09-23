# Product Requirements Document (PRD)

## 1. Product Overview
**Name:** TabCircle (formerly TabCircle)
**Purpose:** Supercharge Chromium's tab experience on Linux by providing a macOS-like `Ctrl+Tab` Most Recently Used (MRU) tab switcher with a persistent visual overlay.

## 2. Target Audience
- Linux power users and developers.
- Users of Chromium-based browsers (Chrome, Brave, Edge, Vivaldi) on Linux.
- Users who rely heavily on keyboard navigation and find the default tab-strip cycling inefficient.

## 3. Core Features
1. **MRU Tab Switching:** `Ctrl+Tab` cycles through tabs in the order they were last used, not their physical order.
2. **Visual Overlay:** A floating, centered UI overlay showing tab thumbnails when `Ctrl+Tab` is held.
3. **Live Thumbnails:** Every tab card displays a recent screenshot of the page.
4. **Input Support:** Navigate the overlay using `Ctrl+Tab`, Arrow Keys, or Mouse hover/clicks.
5. **Fallback:** If the Linux Helper app is not running, the extension degrades gracefully and allows Chromium's default `Ctrl+Tab` behavior.

## 4. Out of Scope (For Now)
- Support for Firefox or Safari (due to different API extensions and behaviors).
- Complex window management (moving tabs between windows is not the goal).
- Replacing the macOS version entirely (this is a Linux port).

## 5. Success Metrics
- Seamless interception of `Ctrl+Tab` on standard Linux desktop environments (X11, with Wayland as a stretch goal/fallback).
- Less than 50ms latency between keystroke and overlay rendering.
