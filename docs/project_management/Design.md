# Design Document

## 1. Visual Language
The design of TabCircle strictly follows the premium, native-feeling aesthetics established by the original macOS version (TabCircle). The goal on Linux is to replicate this exact look using PyQt6.

## 2. Color Palette
The interface adapts to the system's Light/Dark mode.
- **Dark Mode:**
  - Background: Semi-transparent deep gray/black (e.g., `#1C1C1C` at 80% opacity).
  - Text: `#FFFFFF` (Primary), `#A0A0A0` (Secondary).
  - Selected Card Highlight: Soft white outline or lighter gray background (`#2C2C2C`).
- **Light Mode:**
  - Background: Semi-transparent white/light gray (`#F5F5F5` at 80% opacity).
  - Text: `#000000` (Primary), `#666666` (Secondary).
  - Selected Card Highlight: Soft dark outline or slight shadow.

## 3. Typography
- **Font Family:** System sans-serif (e.g., `Inter`, `Roboto`, `Ubuntu`, or `San Francisco` fallback).
- **Weights:** Regular (400) for secondary text, Semi-Bold (600) for active/primary text.

## 4. UI Components
- **Main Overlay:** A centered, frameless, borderless window with rounded corners.
- **Tab Cards:** 
  - Thumbnail image taking up the top 75%.
  - Favicon and Page Title in the bottom 25%.
  - Rounded corners on the cards themselves.
- **Layouts:** Support for both a single horizontal strip (for few tabs) and a grid layout (for many tabs).
