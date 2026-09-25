// Decision table validation for SwitcherHotkeys.mode.
//
// Running (under helper/):
//   swiftc -parse-as-library Sources/tabcircle/SwitchMode.swift \
//          checks/switch-mode-check.swift -o ./switchmodecheck && ./switchmodecheck
//
// Rationale: 16 cells in the decision table (switcher key matches/doesn't × global key matches/doesn't
// × foreground is browser/isn't × is excluded/isn't). None of these produce runtime errors when wrong;
// symptoms manifest as reversed behavior in specific applications. Expected values are hand-written
// rather than derived from implementation to avoid duplicating identical reasoning bugs.

import CoreGraphics

private let kTab: Int64 = 48   // kVK_Tab
private let kA: Int64 = 0      // kVK_ANSI_A

/// Default: both share the same key (global key follows switcher key, configureGlobalHotkey nil branch).
private func sameKey(enabled: Bool) -> SwitcherHotkeys {
    SwitcherHotkeys(switchKeyCode: kTab, switchModifiers: .maskControl,
                    globalKeyCode: kTab, globalModifiers: .maskControl,
                    globalEnabled: enabled)
}

/// Distinct keys: switcher ⌃⇥, global ⌥⇥.
private func diffKey(enabled: Bool) -> SwitcherHotkeys {
    SwitcherHotkeys(switchKeyCode: kTab, switchModifiers: .maskControl,
                    globalKeyCode: kTab, globalModifiers: .maskAlternate,
                    globalEnabled: enabled)
}

/// Modifiers are subsets: ⌃⇥ and ⌃⌥⇥ — pressing ⌃⌥⇥ matches both keys simultaneously.
private func subsetKey(enabled: Bool) -> SwitcherHotkeys {
    SwitcherHotkeys(switchKeyCode: kTab, switchModifiers: .maskControl,
                    globalKeyCode: kTab, globalModifiers: [.maskControl, .maskAlternate],
                    globalEnabled: enabled)
}

private struct Case {
    let name: String
    let keys: SwitcherHotkeys
    let code: Int64
    let flags: CGEventFlags
    let browser: Bool
    let excluded: Bool
    let want: SwitchMode?
}

private let ctrlTab: CGEventFlags = .maskControl
private let ctrlShiftTab: CGEventFlags = [.maskControl, .maskShift]
private let optTab: CGEventFlags = .maskAlternate
private let ctrlOptTab: CGEventFlags = [.maskControl, .maskAlternate]
private let cmdTab: CGEventFlags = .maskCommand

private let cases: [Case] = [
    // ── Same Key + Global switcher disabled: exclusion list has no effect ──────────
    Case(name: "same-key/off/browser/not-excluded", keys: sameKey(enabled: false),
         code: kTab, flags: ctrlTab, browser: true, excluded: false, want: .browser),
    Case(name: "same-key/off/browser/excluded", keys: sameKey(enabled: false),
         code: kTab, flags: ctrlTab, browser: true, excluded: true, want: .browser),
    Case(name: "same-key/off/non-browser/not-excluded", keys: sameKey(enabled: false),
         code: kTab, flags: ctrlTab, browser: false, excluded: false, want: nil),
    Case(name: "same-key/off/non-browser/excluded", keys: sameKey(enabled: false),
         code: kTab, flags: ctrlTab, browser: false, excluded: true, want: nil),

    // ── Same Key + Global switcher enabled (default configuration) ───────────────────
    Case(name: "same-key/on/browser/not-excluded", keys: sameKey(enabled: true),
         code: kTab, flags: ctrlTab, browser: true, excluded: false, want: .browser),
    // Exclusion list only governs global switcher: intra-browser switching is core and exempt
    Case(name: "same-key/on/browser/excluded", keys: sameKey(enabled: true),
         code: kTab, flags: ctrlTab, browser: true, excluded: true, want: .browser),
    Case(name: "same-key/on/non-browser/not-excluded", keys: sameKey(enabled: true),
         code: kTab, flags: ctrlTab, browser: false, excluded: false, want: .global),
    // Core exclusion behavior: pass through to terminal / editor's native ⌃⇥
    Case(name: "same-key/on/non-browser/excluded", keys: sameKey(enabled: true),
         code: kTab, flags: ctrlTab, browser: false, excluded: true, want: nil),
    // Reverse direction (with Shift) shares matching logic; exclusion must also apply
    Case(name: "same-key/on/non-browser/not-excluded/ctrl-shift-tab", keys: sameKey(enabled: true),
         code: kTab, flags: ctrlShiftTab, browser: false, excluded: false, want: .global),
    Case(name: "same-key/on/non-browser/excluded/ctrl-shift-tab", keys: sameKey(enabled: true),
         code: kTab, flags: ctrlShiftTab, browser: false, excluded: true, want: nil),
    // Unrelated shortcuts must never be intercepted
    Case(name: "same-key/on/browser/cmd-tab", keys: sameKey(enabled: true),
         code: kTab, flags: cmdTab, browser: true, excluded: false, want: nil),
    Case(name: "same-key/on/non-browser/ctrl-a", keys: sameKey(enabled: true),
         code: kA, flags: ctrlTab, browser: false, excluded: false, want: nil),

    // ── Different Keys: switcher ⌃⇥, global ⌥⇥ ────────────────────────────────────────
    Case(name: "diff-key/on/browser/not-excluded/opt-tab", keys: diffKey(enabled: true),
         code: kTab, flags: optTab, browser: true, excluded: false, want: .global),
    // Browser itself added to exclusion list: global key passes through without activating cross-browser switcher
    Case(name: "diff-key/on/browser/excluded/opt-tab", keys: diffKey(enabled: true),
         code: kTab, flags: optTab, browser: true, excluded: true, want: nil),
    // Switcher key unaffected by exclusion list
    Case(name: "diff-key/on/browser/excluded/ctrl-tab", keys: diffKey(enabled: true),
         code: kTab, flags: ctrlTab, browser: true, excluded: true, want: .browser),
    Case(name: "diff-key/on/non-browser/not-excluded/ctrl-tab", keys: diffKey(enabled: true),
         code: kTab, flags: ctrlTab, browser: false, excluded: false, want: nil),
    Case(name: "diff-key/on/non-browser/not-excluded/opt-tab", keys: diffKey(enabled: true),
         code: kTab, flags: optTab, browser: false, excluded: false, want: .global),
    Case(name: "diff-key/on/non-browser/excluded/opt-tab", keys: diffKey(enabled: true),
         code: kTab, flags: optTab, browser: false, excluded: true, want: nil),
    Case(name: "diff-key/off/non-browser/not-excluded/opt-tab", keys: diffKey(enabled: false),
         code: kTab, flags: optTab, browser: false, excluded: false, want: nil),

    // ── Modifiers are subsets (⌃⇥ and ⌃⌥⇥): dual match follows same-key rule ──────────
    Case(name: "subset/on/non-browser/not-excluded/ctrl-opt-tab", keys: subsetKey(enabled: true),
         code: kTab, flags: ctrlOptTab, browser: false, excluded: false, want: .global),
    Case(name: "subset/on/browser/not-excluded/ctrl-opt-tab", keys: subsetKey(enabled: true),
         code: kTab, flags: ctrlOptTab, browser: true, excluded: false, want: .browser),
    // When the global half of a dual match is vetoed by exclusion, the remaining switcher key follows its rule
    Case(name: "subset/on/non-browser/excluded/ctrl-opt-tab", keys: subsetKey(enabled: true),
         code: kTab, flags: ctrlOptTab, browser: false, excluded: true, want: nil),
    Case(name: "subset/on/browser/excluded/ctrl-opt-tab", keys: subsetKey(enabled: true),
         code: kTab, flags: ctrlOptTab, browser: true, excluded: true, want: .browser),
]

private func describe(_ mode: SwitchMode?) -> String {
    switch mode {
    case .browser: return "browser"
    case .global:  return "global"
    case nil:      return "pass-through"
    }
}

@main
struct SwitchModeCheck {
    static func main() {
        var failures = 0
        for c in cases {
            let got = c.keys.mode(code: c.code, flags: c.flags,
                                  frontIsBrowser: c.browser, frontIsExcluded: c.excluded)
            if got != c.want {
                failures += 1
                print("✗ \(c.name): Expected \(describe(c.want)), got \(describe(got))")
            }
        }

        print(failures == 0
              ? "All passed (\(cases.count) cases)"
              : "\(failures) failed (out of \(cases.count) cases)")
        if failures > 0 { fatalError("SwitcherHotkeys decision table validation failed") }
    }
}
