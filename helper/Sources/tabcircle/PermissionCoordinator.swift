import AppKit
import ApplicationServices
import PermissionFlow

/// Accessibility authorization coordinator.
///
/// Deliberately windowless. PermissionFlow overlay is only visible when System Settings
/// is the foreground app and anchors alongside the System Settings window. Custom app windows
/// would occlude or displace it.
///
/// The entry point is in the menu bar: clicking it dismisses the menu immediately,
/// keeping foreground unblocked so the overlay can anchor beside System Settings.
@MainActor
final class PermissionCoordinator {

    private var pollTimer: Timer?
    private var onGranted: (() -> Void)?

    /// `promptForAccessibilityTrust: false` — macOS native modal only appears on first request.
    /// If user clicks "Deny", subsequent calls fail silently, so it is unreliable for onboarding.
    private let controller = PermissionFlow.makeController(
        configuration: .init(
            requiredAppURLs: [Bundle.main.bundleURL],
            promptForAccessibilityTrust: false
        )
    )

    /// Begin polling for authorization. Calls back once granted (caller handles relaunching).
    func startWaiting(onGranted: @escaping () -> Void) {
        self.onGranted = onGranted
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard AXIsProcessTrusted() else { return }
                self?.pollTimer?.invalidate()
                self?.pollTimer = nil
                log("Accessibility granted — relaunching")
                self?.onGranted?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Display the PermissionFlow drag-to-authorize overlay.
    func authorize() {
        // Missing resource bundle causes SIGTRAP in PermissionFlow at Bundle.module
        guard Self.bundleAvailable() else {
            log("⚠️  PermissionFlow resource bundle missing — falling back to plain deeplink")
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
            return
        }

        // Overlay animates from mouse location towards the System Settings window
        let location = NSEvent.mouseLocation
        let sourceFrame = CGRect(x: location.x - 16, y: location.y - 16, width: 32, height: 32)

        controller.authorize(
            pane: .accessibility,
            suggestedAppURLs: [Bundle.main.bundleURL],
            sourceFrameInScreen: sourceFrame,
            panelHint: "Drag this icon into the Accessibility list",
            panelTitle: "Authorize TabCircle"
        )
    }

    /// Check if resource bundle is available.
    ///
    /// Must check both locations: code-signed builds place it in `Contents/Resources`,
    /// while SwiftPM accessors expect `.app` bundle root. Checking only one causes false positives.
    private static func bundleAvailable() -> Bool {
        let name = "PermissionFlow_PermissionFlow.bundle"
        let candidates: [URL?] = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        return candidates.contains { candidate in
            guard let url = candidate?.appendingPathComponent(name) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }
}
