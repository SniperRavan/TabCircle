import Foundation
import ServiceManagement

/// Wrapper for "Launch at Login".
///
/// State is deliberately un-cached: `SMAppService.mainApp.status` is system-managed external state
/// that users can modify anytime under System Settings → General → Login Items. Reading on demand
/// whenever the menu opens guarantees accurate status.
enum LoginItem {

    enum State {
        /// Enabled, automatically launches on login
        case enabled
        /// Disabled
        case disabled
        /// macOS 13+ registered awaiting user approval in System Settings — appears in list but not yet active;
        /// must be distinguished from disabled to avoid confusion when clicking
        case requiresApproval
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        default:                return .disabled
        }
    }

    /// Toggle launch at login. Returns actual resulting state (not assumed state).
    @discardableResult
    static func toggle() -> State {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("Login item toggle failed: \(error.localizedDescription)")
        }
        return state   // Read back actual state; do not assume success
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
