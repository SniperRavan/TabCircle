#if os(macOS)
import AppKit
import ApplicationServices
import Combine
import SystemSettingsKit
import SwiftUI

@available(macOS 13.0, *)
@MainActor
public final class PermissionFlowController: ObservableObject {
    /// The package exposes a single active floating panel at a time so opening
    /// a second permission flow closes the previous panel automatically.
    private static var activeController: PermissionFlowController?
    private let systemSettingsBundleIdentifier = "com.apple.systempreferences"

    /// Apps currently represented in the floating panel.
    @Published public private(set) var droppedApps: [URL]

    /// The permission pane currently being guided.
    @Published public private(set) var currentPane: PermissionFlowPane?

    /// Optional secondary text shown above the drag card. Hosts use this to
    /// hint flow-specific instructions such as "remove the existing entry first".
    @Published public private(set) var panelHint: String?

    /// Optional title that overrides the default "Sandbox Permission" string.
    /// Useful when the pane is not actually a sandbox-related permission, e.g.
    /// Accessibility, where a more accurate title improves clarity.
    @Published public private(set) var panelTitle: String?

    /// Drives the visibility of the "reopen settings" action.
    @Published var isSettingsFrontmost = false

    /// Drives the header icon animation while the app card is being dragged.
    @Published var isDraggingApp = false

    /// Drives the locale environment used by the floating SwiftUI panel.
    @Published public private(set) var localeIdentifier: String?

    public var onDrop: ((URL) -> Void)?

    private let configuration: PermissionFlowConfiguration
    private let tracker = SettingsWindowTracker()

    private var panel: FloatingDropPanel?
    private var pendingLaunchSourceFrame: CGRect?
    private var previousFrontmostApplicationPID: pid_t?
    private var previousFrontmostApplicationBundleIdentifier: String?
    private var trustCheckTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    public init(configuration: PermissionFlowConfiguration = .init()) {
        self.configuration = configuration
        self.droppedApps = configuration.requiredAppURLs.uniqueAppURLs()
        self.localeIdentifier = configuration.localeIdentifier

        updateFrontmostAppState()
        bindTrackerCallbacks()
        observeFrontmostApplication()
    }

    /// Opens the requested privacy pane and starts the floating guidance flow.
    public func authorize(
        pane: PermissionFlowPane,
        suggestedAppURLs: [URL] = [],
        sourceFrameInScreen: CGRect? = nil,
        panelHint: String? = nil,
        panelTitle: String? = nil
    ) {
        closeOtherActivePanelIfNeeded()

        rememberPreviousFrontmostApplication()
        currentPane = pane
        self.panelHint = panelHint
        self.panelTitle = panelTitle
        pendingLaunchSourceFrame = sourceFrameInScreen
        mergeDroppedApps(with: suggestedAppURLs)
        SystemSettings.open(url: pane.settingsURL)

        Self.activeController = self
        showPanel()
        tracker.startTracking(promptIfNeeded: configuration.promptForAccessibilityTrust)
        startTrustCheckIfNeeded(for: pane)
    }

    /// Shows the panel immediately. If the target System Settings frame is
    /// already known, the panel is positioned or animated into place at once.
    public func showPanel() {
        if panel == nil {
            panel = FloatingDropPanel(controller: self)
        }

        guard let panel else { return }

        if let settingsFrame = tracker.currentFrame {
            presentPanel(panel, for: settingsFrame)
            return
        }

        if let sourceFrame = pendingLaunchSourceFrame {
            panel.show(at: sourceFrame)
        } else {
            panel.center()
            panel.show()
        }
    }

    public func closePanel(returnToPreviousApp: Bool = false) {
        tracker.stopTracking()
        trustCheckTimer?.invalidate()
        trustCheckTimer = nil
        panel?.close()
        panel = nil
        pendingLaunchSourceFrame = nil
        panelHint = nil
        panelTitle = nil

        if Self.activeController === self {
            Self.activeController = nil
        }

        if returnToPreviousApp {
            reactivatePreviousFrontmostApplication()
        }
    }

    public func resetDroppedApps() {
        droppedApps = configuration.requiredAppURLs.uniqueAppURLs()
    }

    /// Updates the locale injected into the floating panel.
    public func setLocaleIdentifier(_ localeIdentifier: String?) {
        guard self.localeIdentifier != localeIdentifier else { return }
        self.localeIdentifier = localeIdentifier
        panel?.updateLocaleIdentifier(localeIdentifier)
    }

    /// Registers a unique `.app` bundle URL and notifies the host if needed.
    public func registerDroppedApp(_ url: URL) {
        guard url.pathExtension.lowercased() == "app" else { return }
        let normalizedURL = url.standardizedFileURL
        guard droppedApps.contains(normalizedURL) == false else { return }
        droppedApps.append(normalizedURL)
        onDrop?(normalizedURL)
    }

    /// The panel always renders a single primary app card. If the host has not
    /// supplied one yet, the host application's bundle becomes the fallback.
    var preferredAppURL: URL? {
        if let first = droppedApps.first {
            return first
        }
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        return bundleURL.pathExtension.lowercased() == "app" ? bundleURL : nil
    }

    /// The panel becomes mouse-transparent while dragging so System Settings
    /// underneath can receive the drop.
    func setPanelDragging(_ isDragging: Bool) {
        isDraggingApp = isDragging
        panel?.setDraggingPassthrough(isDragging)
    }

    /// Keeps System Settings visually present whenever the floating panel is
    /// clicked or momentarily considered for focus.
    func keepSettingsVisible() {
        SystemSettings.activate()
        panel?.orderFrontRegardless()
    }

    func reopenCurrentSettingsPane() {
        guard let currentPane else { return }
        SystemSettings.open(url: currentPane.settingsURL)
        panel?.orderFrontRegardless()
    }

    /// Merges unique app bundle URLs into the current panel list.
    func mergeDroppedApps(with urls: [URL]) {
        for url in urls.uniqueAppURLs() {
            registerDroppedApp(url)
        }
    }

    private func bindTrackerCallbacks() {
        tracker.onFrameChange = { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.presentPanel(self.panel, for: frame)
            }
        }
        tracker.onTrackingEnded = { [weak self] in
            Task { @MainActor [weak self] in
                self?.closePanel()
            }
        }
    }

    private func observeFrontmostApplication() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateFrontmostAppState()
            }
            .store(in: &cancellables)
    }

    private func closeOtherActivePanelIfNeeded() {
        if let activeController = Self.activeController, activeController !== self {
            activeController.closePanel()
        }
    }

    private func rememberPreviousFrontmostApplication() {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        guard frontmostApplication?.bundleIdentifier != systemSettingsBundleIdentifier else { return }
        previousFrontmostApplicationPID = frontmostApplication?.processIdentifier
        previousFrontmostApplicationBundleIdentifier = frontmostApplication?.bundleIdentifier
    }

    private func reactivatePreviousFrontmostApplication() {
        defer {
            previousFrontmostApplicationPID = nil
            previousFrontmostApplicationBundleIdentifier = nil
        }

        if let previousFrontmostApplicationPID,
           let application = NSRunningApplication(processIdentifier: previousFrontmostApplicationPID) {
            application.activate(options: [.activateIgnoringOtherApps])
            return
        }

        guard let previousFrontmostApplicationBundleIdentifier else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: previousFrontmostApplicationBundleIdentifier)
            .first?
            .activate(options: [.activateIgnoringOtherApps])
    }

    private func presentPanel(_ panel: FloatingDropPanel?, for settingsFrame: CGRect) {
        guard let panel else { return }

        if let sourceFrame = pendingLaunchSourceFrame {
            panel.present(from: sourceFrame, to: settingsFrame)
            pendingLaunchSourceFrame = nil
        } else {
            panel.snap(to: settingsFrame)
        }
    }

    private func updateFrontmostAppState() {
        let wasSettingsFrontmost = isSettingsFrontmost
        isSettingsFrontmost =
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == systemSettingsBundleIdentifier

        // Mirror the panel visibility to System Settings so the helper hides
        // when the user switches to another app and returns when they come back
        // to settings. Skipping during drag avoids killing an active drop.
        guard let panel, isDraggingApp == false else { return }
        if isSettingsFrontmost {
            panel.orderFrontRegardless()
        } else if wasSettingsFrontmost {
            panel.orderOut(nil)
        }
    }

    /// Starts polling the system trust state for panes whose grant status can
    /// be observed from the host process (currently Accessibility). The panel
    /// closes itself the moment authorization succeeds so the user sees an
    /// immediate confirmation of the action they just performed.
    private func startTrustCheckIfNeeded(for pane: PermissionFlowPane) {
        trustCheckTimer?.invalidate()
        trustCheckTimer = nil
        guard pane == .accessibility, AXIsProcessTrusted() == false else { return }

        trustCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard AXIsProcessTrusted() else { return }
                self.closePanel(returnToPreviousApp: true)
            }
        }
    }
}

@available(macOS 13.0, *)
private extension Array where Element == URL {
    /// Normalizes and de-duplicates `.app` bundle URLs.
    func uniqueAppURLs() -> [URL] {
        var seen = Set<String>()
        return compactMap { url in
            let normalized = url.standardizedFileURL
            guard normalized.pathExtension.lowercased() == "app" else { return nil }
            return seen.insert(normalized.path).inserted ? normalized : nil
        }
    }

    /// Uses normalized file paths for containment because equivalent file URLs
    /// can differ in their string representation.
    func contains(_ url: URL) -> Bool {
        contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path })
    }
}
#endif
