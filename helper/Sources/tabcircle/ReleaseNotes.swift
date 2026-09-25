import AppKit
import SwiftUI

/// "What's New" release notes modal shown on the first launch after an update.
///
/// Detection logic resides in the updated binary itself: after the updater replaces
/// Contents and restarts, the new version detects that the last executed version differs from itself.
@MainActor
enum ReleaseNotes {

    private static let repo = "sniperravan/TabCircle"
    private static let lastRunKey = "lastRunVersion"
    /// Used as supporting evidence to detect previous installations
    private static let everCheckedKey = "lastUpdateCheck"
    /// Flag indicating release notes are pending presentation
    private static let pendingKey = "pendingNotesVersion"

    /// Initial delay before attempting to fetch notes. Avoids competing with initial extension handshake.
    private static let firstDelay: TimeInterval = 8
    /// Backoff retry intervals on failure.
    private static let retryGaps: [TimeInterval] = [12, 30]
    /// Timeout for silent background fetch.
    private static let backgroundTimeout: TimeInterval = 30
    /// Timeout when manually requested from Settings -> About.
    private static let manualTimeout: TimeInterval = 15

    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases")! }

    // MARK: - Decision Logic

    /// Launch decision outcome regarding notes fetching and state flags.
    struct StartupDecision: Equatable {
        var lastRun: String
        var pending: String?
        var shouldFetch: Bool
        var justUpgraded: Bool
    }

    /// Pure function determining startup actions without touching UserDefaults.
    nonisolated static func decide(lastRun: String?, pending: String?,
                                   everChecked: Bool, current: String) -> StartupDecision {
        let upgraded = lastRun.map { $0 != current } ?? everChecked

        if upgraded {
            return .init(lastRun: current, pending: current,
                         shouldFetch: true, justUpgraded: true)
        }
        return .init(lastRun: current,
                     pending: pending == current ? current : nil,
                     shouldFetch: pending == current, justUpgraded: false)
    }

    // MARK: - Fetching

    /// Fetch release notes for a specific version tag.
    static func fetch(version: String, timeout: TimeInterval) async -> String? {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/tags/v\(version)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = json["body"] as? String, !body.isEmpty else { return nil }
        return body
    }

    // MARK: - Presentation

    private static var window: NSWindow?

    /// Called after update: fetches notes and presents window when retrieved.
    static func presentIfUpgraded(currentVersion: String) {
        let defaults = UserDefaults.standard
        let decision = decide(lastRun: defaults.string(forKey: lastRunKey),
                              pending: defaults.string(forKey: pendingKey),
                              everChecked: defaults.object(forKey: everCheckedKey) != nil,
                              current: currentVersion)
        defaults.set(decision.lastRun, forKey: lastRunKey)
        if let pending = decision.pending {
            defaults.set(pending, forKey: pendingKey)
        } else {
            defaults.removeObject(forKey: pendingKey)
        }

        guard decision.shouldFetch else { return }
        log(decision.justUpgraded
            ? "🎉 Upgraded to \(currentVersion), fetching release notes shortly"
            : "Previous release notes fetch for \(currentVersion) incomplete, retrying on this launch")

        DispatchQueue.main.asyncAfter(deadline: .now() + firstDelay) {
            Task { @MainActor in await fetchAndPresent(currentVersion) }
        }
    }

    /// Fetch notes and present modal, retrying on failure.
    private static func fetchAndPresent(_ version: String) async {
        for attempt in 0...retryGaps.count {
            if let body = await fetch(version: version, timeout: backgroundTimeout) {
                UserDefaults.standard.removeObject(forKey: pendingKey)
                log("Release notes retrieved, presenting What's New window")
                present(version: version, body: body)
                return
            }
            log("Could not fetch release notes (attempt \(attempt + 1)/\(retryGaps.count + 1))")
            guard attempt < retryGaps.count else { break }
            try? await Task.sleep(nanoseconds: UInt64(retryGaps[attempt] * 1_000_000_000))
        }
        log("Could not fetch release notes for \(version) on this launch, will retry next launch")
    }

    /// Manually opened from Settings -> About.
    static func presentLatest(currentVersion: String) {
        Task { @MainActor in
            let body = await fetch(version: currentVersion, timeout: manualTimeout)
            if body != nil { UserDefaults.standard.removeObject(forKey: pendingKey) }
            present(version: currentVersion, body: body)
        }
    }

    private static func present(version: String, body: String?) {
        let parsed = body.map {
            ReleaseNotesParser.blocks(
                from: ReleaseNotesParser.section(from: $0, heading: "What's New"))
        } ?? []

        // Temporarily present as regular app so window receives focus and Dock presence
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        window?.close()
        let view = WhatsNewView(version: version, blocks: parsed) {
            window?.close()
        }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]

        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable]
        w.title = "What's New in TabCircle"
        w.isReleasedWhenClosed = false
        w.delegate = WindowWatcher.shared
        host.view.layoutSubtreeIfNeeded()
        w.setContentSize(host.view.fittingSize)
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    private final class WindowWatcher: NSObject, NSWindowDelegate {
        static let shared = WindowWatcher()
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                ReleaseNotes.window = nil
                if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0 !== notification.object as? NSWindow }) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}

// MARK: - Window View

private struct WhatsNewView: View {
    let version: String
    let blocks: [ReleaseNotesParser.Block]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updated to \(version)")
                        .font(.system(size: 15, weight: .semibold))
                    Text("What changed")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if blocks.isEmpty {
                        Text("Couldn't load the notes for this version — they're on GitHub.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            row(block)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .frame(width: 480, height: 320)

            Divider()

            HStack {
                Link("View on GitHub", destination: ReleaseNotes.releasesPage)
                    .font(.system(size: 12))
                Spacer()
                Button("OK", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func row(_ block: ReleaseNotesParser.Block) -> some View {
        switch block {
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                markdown(text).fixedSize(horizontal: false, vertical: true)
            }
        case .callout(let text):
            markdown(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                }
        case .paragraph(let text):
            markdown(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func markdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed).font(.system(size: 12))
        }
        return Text(text).font(.system(size: 12))
    }
}
