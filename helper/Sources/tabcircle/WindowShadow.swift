import AppKit

/// Applies standard macOS window shadow parameters to panels and floating windows.
///
/// System window shadows operate at two tiers (empirically measured via `CGSGetWindowShadowAndRimParameters`):
///
/// | Window Type | standardDeviation | density | offsetY |
/// |---|---|---|---|
/// | Standard Window (active) | 32.941 | 0.40 | 18 |
/// | borderless / panel / inactive | 13.176 | 0.25 | 4 |
///
/// Non-activating borderless panels naturally receive the lower tier. This module dynamically
/// resolves SkyLight SPIs via `dlsym` to apply the active tier shadow cleanly without side effects.
@MainActor
enum WindowShadow {

    /// Empirically verified values for standard active windows.
    private static let standardDeviation: Float = 32.941
    private static let density: Float = 0.40
    private static let offsetY: Int32 = 18

    /// Avoid retrying if this SPI is confirmed unavailable on the host system.
    private static var unavailable = false

    /// Apply standard active window shadow tier to the specified window.
    static func applyStandardWindowShadow(to window: NSWindow) {
        apply(to: window, deviation: standardDeviation, density: density, offsetY: offsetY)
    }

    /// Compact shadow tier suitable for smaller elements like toasts and pills.
    static func applyCompactShadow(to window: NSWindow) {
        apply(to: window, deviation: 22, density: 0.32, offsetY: 8)
    }

    private static func apply(to window: NSWindow, deviation: Float, density: Float,
                              offsetY: Int32, attempt: Int = 0) {
        guard !unavailable,
              let cid = connectionID, let set = setShadow, let get = getShadow else { return }
        // windowNumber can be <= 0 before the window is mapped on-screen; casting negative integers to UInt32 crashes.
        guard window.windowNumber > 0 else { return }
        let wid = UInt32(window.windowNumber)

        var sd: Float = 0, den: Float = 0
        var offsetX: Int32 = 0, currentOffsetY: Int32 = 0, flags: UInt32 = 0
        let err = get(cid, wid, &sd, &den, &offsetX, &currentOffsetY, &flags)

        // Verifies whether shadow parameters are initialized and ABI types match expected ranges.
        guard err == 0, sd > 0, sd < 200, den > 0, den <= 1 else {
            guard attempt < 30 else {           // ~240ms timeout; mark SPI unavailable
                unavailable = true
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) {
                guard window.isVisible else { return }
                apply(to: window, deviation: deviation, density: density,
                      offsetY: offsetY, attempt: attempt + 1)
            }
            return
        }

        _ = set(cid, wid, deviation, density, 0, offsetY)
        _ = invalidate?(cid, wid)
    }

    // MARK: - Private Symbols (dynamically resolved)

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SetShadowFn = @convention(c) (Int32, UInt32, Float, Float, Int32, Int32) -> Int32
    private typealias GetShadowFn = @convention(c) (Int32, UInt32,
        UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>,
        UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>,
        UnsafeMutablePointer<UInt32>) -> Int32
    private typealias InvalidateFn = @convention(c) (Int32, UInt32) -> Int32

    private static let skyLight: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = skyLight, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    private static let connectionID: Int32? = symbol("CGSMainConnectionID", as: MainConnectionFn.self)?()
    private static let setShadow = symbol("CGSSetWindowShadowParameters", as: SetShadowFn.self)
    private static let getShadow = symbol("CGSGetWindowShadowAndRimParameters", as: GetShadowFn.self)
    /// Invalidation helper; non-essential since next redraw also updates shadow.
    private static let invalidate = symbol("CGSInvalidateWindowShadow", as: InvalidateFn.self)
}
