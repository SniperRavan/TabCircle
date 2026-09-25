#!/usr/bin/env swift
//
//  spike-eventtap.swift
//
//  Spike: verify CGEventTap intercepts and consumes Ctrl+Tab in Chrome,
//  and captures Ctrl key release timing.
//
//  Run:  swift spike-eventtap.swift
//  Stop: Ctrl+C
//

import Cocoa
import Carbon.HIToolbox

// MARK: - Global State

private let kChromeBundleID = "com.google.Chrome"

private var gFrontIsChrome = false
private var gCycling = false
private var gCycleSteps = 0
private var gTap: CFMachPort?

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

private func log(_ msg: String) {
    print("[\(logFormatter.string(from: Date()))] \(msg)")
    fflush(stdout)
}

// MARK: - Event Tap Callback

private let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        let reason = (type == .tapDisabledByTimeout) ? "callback timeout" : "user input"
        log("⚠️  event tap disabled by system (\(reason)) -> re-enabling")
        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return nil

    case .keyDown:
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        guard code == Int64(kVK_Tab),
              flags.contains(.maskControl),
              gFrontIsChrome else { break }

        let backward = flags.contains(.maskShift)
        gCycling = true
        gCycleSteps += 1
        log("⌃\(backward ? "⇧" : "")⇥  Intercepted and swallowed  <- step \(gCycleSteps) (\(backward ? "backward" : "forward"))")
        return nil   // Swallow: Chrome does not receive this event

    case .flagsChanged:
        if gCycling && !event.flags.contains(.maskControl) {
            log("⌃ released -> commit switch now (cycle \(gCycleSteps) steps)")
            print("")
            gCycling = false
            gCycleSteps = 0
        }

    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Startup

let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
guard AXIsProcessTrustedWithOptions(promptOptions) else {
    print("""
    ❌ Missing Accessibility permissions.
    Please enable Accessibility for your terminal in System Settings -> Privacy & Security -> Accessibility,
    then rerun.
    """)
    exit(1)
}

let eventMask = (1 << CGEventType.keyDown.rawValue)
              | (1 << CGEventType.flagsChanged.rawValue)

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .headInsertEventTap,
                                  options: .defaultTap,
                                  eventsOfInterest: CGEventMask(eventMask),
                                  callback: tapCallback,
                                  userInfo: nil) else {
    print("❌ CGEvent.tapCreate failed.")
    exit(1)
}
gTap = tap

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

let workspace = NSWorkspace.shared
gFrontIsChrome = workspace.frontmostApplication?.bundleIdentifier == kChromeBundleID
workspace.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil,
    queue: .main
) { note in
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    let bid = app?.bundleIdentifier ?? "(unknown)"
    gFrontIsChrome = (bid == kChromeBundleID)
    log("Frontmost -> \(bid)\(gFrontIsChrome ? "   ✅ intercepting" : "   (passthrough)")")
}

print("""
╭──────────────────────────────────────────────────────────╮
│  TabCircle — CGEventTap Spike Verification               │
╰──────────────────────────────────────────────────────────╯

Current frontmost: \(workspace.frontmostApplication?.bundleIdentifier ?? "?")\(gFrontIsChrome ? "  ✅" : "")

Press Ctrl+C to exit.
──────────────────────────────────────────────────────────
""")
fflush(stdout)

CFRunLoopRun()
