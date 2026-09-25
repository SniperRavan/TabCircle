import Cocoa
import Carbon.HIToolbox

// MARK: - File-Level State for C Callback
//
// CGEventTap callbacks are C function pointers without Swift context capture;
// state is maintained at file scope. All access occurs on the main run loop.

private var gFrontIsBrowser = false

/// Notifies callers when the active supported browser changes.
private var gOnActiveBrowserChange: (() -> Void)?

func setActiveBrowserChangeHandler(_ handler: (() -> Void)?) {
    gOnActiveBrowserChange = handler
}

/// Global switcher exclusion list (bundle IDs) and cached foreground status.
private var gExcludedBundleIDs: Set<String> = []
private var gFrontIsExcluded = false

/// Called on main thread when exclusion list changes.
@MainActor
func configureExcludedApps(_ bundleIDs: Set<String>) {
    gExcludedBundleIDs = bundleIDs
    refreshFrontmostAppState()
}

/// Recomputes whether frontmost application is a supported browser or excluded.
@MainActor
func refreshFrontmostAppState() {
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let previous = ChromeWindowLocator.activeBundleID
    gFrontIsBrowser = BrowserSupport.isSupported(front)
    gFrontIsExcluded = front.map(gExcludedBundleIDs.contains) ?? false
    if gFrontIsBrowser, let front { ChromeWindowLocator.activeBundleID = front }
    if ChromeWindowLocator.activeBundleID != previous { gOnActiveBrowserChange?() }
}

/// Switcher shortcut (defaults to ⌃⇥). Shift modifier reserved for reverse direction.
private var gSwitchKeyCode: Int64 = Int64(kVK_Tab)
private var gSwitchModifiers: CGEventFlags = .maskControl

/// Global switcher shortcut.
private var gGlobalKeyCode: Int64 = Int64(kVK_Tab)
private var gGlobalModifiers: CGEventFlags = .maskControl
private var gGlobalEnabled = false

/// Strips Shift modifier so it remains reserved for reverse cycling.
private func normalizedHotkeyModifiers(_ flags: CGEventFlags) -> CGEventFlags {
    let stripped = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
    return stripped.isEmpty ? .maskControl : stripped
}

/// Called on main thread when switcher shortcut changes.
func configureSwitcherHotkey(keyCode: Int64?, flags: CGEventFlags) {
    gSwitchKeyCode = keyCode ?? Int64(kVK_Tab)
    gSwitchModifiers = normalizedHotkeyModifiers(flags)
}

/// Called on main thread when global shortcut changes.
func configureGlobalHotkey(keyCode: Int64?, flags: CGEventFlags, enabled: Bool) {
    gGlobalEnabled = enabled
    if let keyCode {
        gGlobalKeyCode = keyCode
        gGlobalModifiers = normalizedHotkeyModifiers(flags)
    } else {
        gGlobalKeyCode = gSwitchKeyCode
        gGlobalModifiers = gSwitchModifiers
    }
}

private var gCycling = false
private var gCyclingGlobal = false
private var gCycleModifiers: CGEventFlags = .maskControl

var eventTapCyclingIsGlobal: Bool { gCyclingGlobal }

private var gTap: CFMachPort?

/// Whether extension is connected and ready with at least 2 switchable tabs.
private var gReady = false
private var gGlobalReady = false

/// Set when event tap is permanently relinquished due to excessive timeouts.
private var gDisabledPermanently = false
private var gOnGaveUp: (() -> Void)?
private var gOnPermissionLost: (() -> Void)?

func setEventTapReady(_ ready: Bool) {
    gReady = ready
}

func setEventTapGlobalReady(_ ready: Bool) {
    gGlobalReady = ready
}

func resetEventTapCycling() {
    gCycling = false
}

var eventTapIsCycling: Bool { gCycling }

func stopEventTap() {
    if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: false) }
    gCycling = false
    gReady = false
    gGlobalReady = false
}

private var gPinHotkeyCode: Int64 = -1
private var gPinHotkeyFlags: CGEventFlags = []
private var gOnPinHotkey: (() -> Void)?

func configurePinHotkey(keyCode: Int64?, flags: CGEventFlags, handler: (() -> Void)?) {
    gPinHotkeyCode = keyCode ?? -1
    gPinHotkeyFlags = flags
    gOnPinHotkey = handler
}

enum ArrowDirection { case left, right, up, down }

private var gOnStep: ((Bool) -> Void)?
private var gOnArrow: ((ArrowDirection) -> Void)?
private var gOnCommit: (() -> Void)?

private var gTapDisableCount = 0
private var gLastTapDisable: CFAbsoluteTime = 0
private let kMaxRapidDisables = 3
private let kRapidWindow: CFAbsoluteTime = 10

private func resolveSwitchMode(code: Int64, flags: CGEventFlags) -> SwitchMode? {
    SwitcherHotkeys(switchKeyCode: gSwitchKeyCode,
                    switchModifiers: gSwitchModifiers,
                    globalKeyCode: gGlobalKeyCode,
                    globalModifiers: gGlobalModifiers,
                    globalEnabled: gGlobalEnabled)
        .mode(code: code, flags: flags,
              frontIsBrowser: gFrontIsBrowser,
              frontIsExcluded: gFrontIsExcluded)
}

private func tabcircleTapCallback(proxy: CGEventTapProxy,
                                 type: CGEventType,
                                 event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        let now = CFAbsoluteTimeGetCurrent()
        gTapDisableCount = (now - gLastTapDisable) < kRapidWindow ? gTapDisableCount + 1 : 1
        gLastTapDisable = now

        guard gTapDisableCount <= kMaxRapidDisables else {
            gDisabledPermanently = true
            gCycling = false
            gOnGaveUp?()
            return nil
        }

        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return nil

    case .keyDown:
        if gDisabledPermanently { break }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Self-heal missed flagsChanged
        if gCycling && !flags.contains(gCycleModifiers) {
            gCycling = false
            gOnCommit?()
        }

        // Intercept arrow navigation during active cycling
        if gCycling, flags.contains(gCycleModifiers) {
            switch code {
            case Int64(kVK_LeftArrow):  gOnArrow?(.left);  return nil
            case Int64(kVK_RightArrow): gOnArrow?(.right); return nil
            case Int64(kVK_UpArrow):    gOnArrow?(.up);    return nil
            case Int64(kVK_DownArrow):  gOnArrow?(.down);  return nil
            default: break
            }
        }

        // User-configured pin shortcut
        if gPinHotkeyCode >= 0,
           code == gPinHotkeyCode,
           gFrontIsBrowser,
           flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == gPinHotkeyFlags {
            gOnPinHotkey?()
            return nil
        }

        guard let mode = resolveSwitchMode(code: code, flags: flags) else { break }
        guard (mode == .global) ? gGlobalReady : gReady else { break }

        if !gCycling {
            gCyclingGlobal = (mode == .global)
            gCycleModifiers = (mode == .global) ? gGlobalModifiers : gSwitchModifiers
        }
        gCycling = true
        gOnStep?(flags.contains(.maskShift))
        return nil

    case .flagsChanged:
        if gCycling && !event.flags.contains(gCycleModifiers) {
            gCycling = false
            gOnCommit?()
        }

    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Public Interface

enum EventTapError: Error, CustomStringConvertible {
    case accessibilityDenied
    case tapCreationFailed

    var description: String {
        switch self {
        case .accessibilityDenied:
            return """
                Accessibility permission is required.

                Open: System Settings → Privacy & Security → Accessibility
                Enable TabCircle (or the terminal app running it), then start again.
                """
        case .tapCreationFailed:
            return """
                CGEvent.tapCreate failed.

                Besides Accessibility, macOS sometimes also requires:
                  System Settings → Privacy & Security → Input Monitoring
                After changing either, fully quit and reopen the app —
                macOS only reads these permissions at process launch.
                """
        }
    }
}

/// Global event tap intercepting shortcuts when a supported browser is active.
@MainActor
final class EventTap {

    private var runLoopSource: CFRunLoopSource?
    private var workspaceObserver: NSObjectProtocol?
    private var permissionTimer: Timer?

    func start(onStep: @escaping (Bool) -> Void,
               onArrow: @escaping (ArrowDirection) -> Void,
               onCommit: @escaping () -> Void,
               onGaveUp: @escaping () -> Void,
               onPermissionLost: @escaping () -> Void) throws {

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw EventTapError.accessibilityDenied
        }

        gOnStep = onStep
        gOnArrow = onArrow
        gOnCommit = onCommit
        gOnGaveUp = onGaveUp
        gOnPermissionLost = onPermissionLost

        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: tabcircleTapCallback,
                                          userInfo: nil) else {
            throw EventTapError.tapCreationFailed
        }
        gTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        runLoopSource = source

        startTrackingFrontmostApp()
        startPermissionWatch()
    }

    private func startPermissionWatch() {
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            guard !gDisabledPermanently, !AXIsProcessTrusted() else { return }
            gDisabledPermanently = true
            stopEventTap()
            Task { @MainActor in gOnPermissionLost?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func startTrackingFrontmostApp() {
        refreshFrontmostAppState()

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                refreshFrontmostAppState()
                if !gFrontIsBrowser && gCycling && !gCyclingGlobal {
                    gCycling = false
                    gOnCommit?()
                }
            }
        }
    }
}
