import CoreGraphics

/// Which switcher should be invoked by this key event.
enum SwitchMode: Equatable {
    /// Tabs of the current browser (standard behavior).
    case browser
    /// Tabs across all connected browsers, grouped by browser.
    case global
}

/// Current shortcut configuration for both switchers.
///
/// Extracted as a pure function (zero dependencies besides CoreGraphics) because the decision
/// table has 16 states: both key matches × whether foreground is a browser × whether foreground is excluded.
/// Logic bugs here produce no errors — they merely manifest as reversed key behaviors in specific apps.
/// Validation check in checks/switch-mode-check.swift.
struct SwitcherHotkeys: Equatable {
    var switchKeyCode: Int64
    var switchModifiers: CGEventFlags
    var globalKeyCode: Int64
    var globalModifiers: CGEventFlags
    /// Whether the global switcher is enabled (defaults to false). When disabled, global key is never matched.
    var globalEnabled: Bool

    /// Resolves pressed key + foreground application into switcher mode. Nil means unrelated event, pass-through.
    ///
    /// Rules:
    ///   - Distinct keys: Each acts independently. Global key triggers even in a browser (no need to focus another app first);
    ///     switcher key only acts when a browser is in the foreground.
    ///   - Same key (default, both ⌃⇥): Browser in foreground → current browser switcher prioritized;
    ///     non-browser foreground → global switcher.
    ///   - Exclusion list only vetoes global switcher: intra-browser switching is core and exempt from exclusion —
    ///     it resolves conflicts where terminal / editor native ⌃⇥ would be intercepted.
    ///
    /// Modifiers use `contains` rather than equality so Shift can combine for reverse navigation (both ⌃⇥ and ⌃⇧⇥ match).
    /// If modifiers are subsets (e.g., ⌃⇥ and ⌃⌥⇥), dual hits follow same-key rules with browser prioritized.
    func mode(code: Int64,
              flags: CGEventFlags,
              frontIsBrowser: Bool,
              frontIsExcluded: Bool) -> SwitchMode? {
        let hitsSwitcher = code == switchKeyCode && flags.contains(switchModifiers)
        let hitsGlobal = globalEnabled && !frontIsExcluded
                         && code == globalKeyCode && flags.contains(globalModifiers)

        if hitsSwitcher && hitsGlobal { return frontIsBrowser ? .browser : .global }
        if hitsGlobal { return .global }
        // Switcher key outside browser does not belong to us — pass through to terminal/editor native ⌃⇥
        if hitsSwitcher { return frontIsBrowser ? .browser : nil }
        return nil
    }
}
