import AppKit
import ApplicationServices

/// Accessibility permission utilities.
///
/// The onboarding guide UI is in `PermissionWindowController` — requiring a draggable app icon
/// and a persistent waiting state, neither of which NSAlert can provide (NSAlert is modal and blocks polling).
enum PermissionGuide {

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Relaunch the application.
    ///
    /// Permissions are only read when the process starts, so the app must restart after authorization.
    /// Doing this automatically is much cleaner than asking the user to manually quit and reopen.
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        // Terminate first then launch: two running instances would collide on the same WebSocket port.
        // Use a detached shell command with a brief delay, terminating the current instance immediately.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "sleep 1; open \(shellQuoted(path))"]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
