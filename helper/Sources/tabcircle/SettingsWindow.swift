import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Uniform width across all settings panes to ensure consistent window dimensions.
/// Fixed at 560 to accommodate full folder paths in folder management without truncation.
private let kSettingsPaneWidth: CGFloat = 560

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { _ in settings.toggleLaunchAtLogin() }
                )) {
                    Text(L10n.t("Open at Login"))
                }
                .toggleStyle(.switch)

                if settings.launchNeedsApproval {
                    Label(L10n.t("Needs approval in System Settings → General → Login Items"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Picker(L10n.t("Language"), selection: $settings.language) {
                    ForEach(L10n.Language.allCases) { lang in
                        Text(lang.label).tag(lang)
                    }
                }
                Picker(L10n.t("Appearance"), selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            Section {
                Picker(L10n.t("Check for updates"), selection: $settings.updateCheckFrequency) {
                    ForEach(UpdateCheckFrequency.allCases) { freq in
                        Text(freq.label).tag(freq)
                    }
                }

                Text(L10n.t(
                    "Prompts you when there's a new version, then installs and restarts."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("Log file"))
                        Text(kLogPath)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button(L10n.t("Open")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: kLogPath))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: kSettingsPaneWidth)
    }
}

// MARK: - Switcher

private struct SwitcherPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.scopeToWindow) {
                    Text(L10n.t("Limit switching to the current window"))
                }
                .toggleStyle(.switch)

                Text(L10n.t(
                    "Off means all windows share one list. Each window keeps its own order either way."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("Scope"))
            }

            Section {
                Picker(L10n.t("Style"), selection: $settings.switcherLayout) {
                    ForEach(SwitcherLayout.allCases) { layout in
                        Text(layout.label).tag(layout)
                    }
                }

                Text(L10n.t(
                    "Strip is one row; grid wraps to fill the screen. In grid mode, ⌃ plus arrows moves in all four directions."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("Layout"))
            }

            Section {
                Toggle(isOn: $settings.globalSwitcher) {
                    Text(L10n.t("Open outside the browser"))
                }
                .toggleStyle(.switch)

                Picker(L10n.t("Style"), selection: $settings.globalSwitcherStyle) {
                    ForEach(GlobalSwitcherStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .disabled(!settings.globalSwitcher)

                Text(L10n.t(
                    "Lists tabs from every browser, grouped by browser. It reuses the switcher shortcut and only opens outside a browser — give it its own key under Shortcuts to use it anywhere."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("Global switcher"))
            }

            excludedSection
        }
        .formStyle(.grouped)
        .frame(width: kSettingsPaneWidth)
    }

    /// Exclusion list: When these apps are frontmost, the global switcher does not intercept shortcuts.
    /// Disabled when global switcher is turned off.
    @ViewBuilder
    private var excludedSection: some View {
        Section {
            ForEach(sortedExcluded) { app in
                excludedRow(app)
            }

            Button {
                chooseApp()
            } label: {
                Label(L10n.t("Add App…"), systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Text(L10n.t("Excluded apps"))
        }
        .disabled(!settings.globalSwitcher)
    }

    /// Sorted alphabetically by name.
    private var sortedExcluded: [ExcludedApp] {
        settings.globalExcludedApps.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func exclude(bundleID: String, name: String) {
        guard !settings.globalExcludedApps.contains(where: { $0.bundleID == bundleID }) else { return }
        settings.globalExcludedApps.append(ExcludedApp(bundleID: bundleID, name: name))
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = FileManager.default
            .urls(for: .applicationDirectory, in: .localDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.t("Can't identify this app")
            alert.informativeText = L10n.t("Its identifier couldn't be read. Try another one.")
            alert.addButton(withTitle: L10n.t("OK"))
            alert.runModal()
            return
        }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        exclude(bundleID: bundleID, name: name)
    }

    @ViewBuilder
    private func excludedRow(_ app: ExcludedApp) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            Text(app.name)
            // Keep app name visible even if application is uninstalled.
            if url == nil {
                Text(L10n.t("Not installed"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                settings.globalExcludedApps.removeAll { $0.bundleID == app.bundleID }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("Stop excluding"))
        }
    }
}

// MARK: - Browsers

/// Displays connection and extension version status for each Chromium-based browser.
private struct BrowserPane: View {
    let browsers: [MRUController.BrowserStatus]

    var body: some View {
        Form {
            Section {
                if browsers.isEmpty {
                    Text(L10n.t("No Chromium-based browsers found."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(browsers) { browser in
                        browserRow(browser)
                    }
                }
            } header: {
                Text(L10n.t("Installed browsers"))
            }

            Section {
                Text(L10n.t(
                    "Not connected means no extension there, or the browser isn't running. Install it once per browser."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button(L10n.t("Download Extension")) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/sniperravan/TabCircle/releases/latest/download/TabCircle-Extension.zip")!)
                    }
                    Link(L10n.t("Install Guide"),
                         destination: URL(string: "https://www.sniperravan.com/TabCircle/install-extension.html")!)
                        .font(.system(size: 11))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: kSettingsPaneWidth)
    }

    @ViewBuilder
    private func browserRow(_ browser: MRUController.BrowserStatus) -> some View {
        HStack(spacing: 8) {
            appIcon(browser.bundleID)
            Text(browser.name)
            Spacer()
            if !browser.connected {
                Label(L10n.t("Not connected"), systemImage: "circle.dashed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if browser.needsUpdate {
                Label(L10n.t("Connected · extension v\(browser.extVersion ?? "?"), needs v\(MRUController.requiredExtensionVersion)+"),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else {
                Label(L10n.t("Connected") + (browser.extVersion.map { " · v\($0)" } ?? ""),
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private func appIcon(_ bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tab Management

private struct TabManagementPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                if settings.favorites.isEmpty {
                    Text(L10n.t("Nothing pinned yet. Pin any tab in your browser."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if settings.favorites.count > 6 {
                    // Limit scroll height when favorites count is large.
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(settings.favorites) { fav in
                                favoriteRow(fav)
                                    .padding(.vertical, 5)
                                if fav.id != settings.favorites.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(height: 250)
                } else {
                    ForEach(settings.favorites) { fav in
                        favoriteRow(fav)
                    }
                }

                Text(L10n.t(
                    "Syncs both ways: pinning adds, unpinning removes, ⌘W doesn't. Restored on restart, at the page you last viewed."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(settings.favorites.isEmpty
                     ? L10n.t("Pinned tabs")
                     : L10n.t("Pinned tabs · \(settings.favorites.count)"))
            }

            Section {
                Toggle(isOn: $settings.allowTabClose) {
                    Text(L10n.t("Show close button on hover in the switcher"))
                }
                .toggleStyle(.switch)

                Text(L10n.t(
                    "Hidden when only two tabs are left. Not available in the global switcher."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("Closing tabs"))
            }

            Section {
                Picker(L10n.t("Auto-clean unused tabs"),
                       selection: $settings.tabLifetime) {
                    ForEach(TabLifetime.allCases) { lifetime in
                        Text(lifetime.label).tag(lifetime)
                    }
                }

                Text(L10n.t(
                    "Closes tabs you haven't used in that long. Pinned, audible, grouped, and current tabs stay."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("Tab lifetime"))
            }
        }
        .formStyle(.grouped)
        .frame(width: kSettingsPaneWidth)
    }

    private var hasMultipleBrowsers: Bool {
        Set(settings.favorites.map(\.browser)).count > 1
    }

    private func browserName(_ bundleID: String) -> String {
        BrowserSupport.displayName(bundleID)
    }

    @ViewBuilder
    private func favoriteRow(_ fav: FavoriteTab) -> some View {
        HStack(spacing: 8) {
            FaviconView(fav: fav)
            VStack(alignment: .leading, spacing: 2) {
                Text(fav.title.isEmpty ? fav.url : fav.title)
                    .lineLimit(1)
                // Shows last visited URL instead of initial pin URL.
                Text((hasMultipleBrowsers ? browserName(fav.browser) + " · " : "")
                     + (settings.favoriteCurrentUrls[fav.id] ?? fav.url))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                settings.favorites.removeAll { $0.id == fav.id }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("Remove and unpin"))
        }
    }
}

/// Favicon view for pinned tabs row.
private struct FaviconView: View {
    let fav: FavoriteTab
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .task(id: fav.id) {
            image = await Self.load(fav)
        }
    }

    private static func load(_ fav: FavoriteTab) async -> NSImage? {
        var candidates: [URL] = []
        if let stored = fav.favIconUrl, !stored.isEmpty, let url = URL(string: stored) {
            candidates.append(url)
        }
        if let page = URL(string: fav.url), let host = page.host,
           let ico = URL(string: "\(page.scheme ?? "https")://\(host)/favicon.ico") {
            candidates.append(ico)
        }
        for url in candidates {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let image = NSImage(data: data), image.isValid {
                return image
            }
        }
        return nil
    }
}

// MARK: - Folders

private struct FoldersPane: View {
    @ObservedObject var folders: FavoriteFolderStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                if folders.entries.isEmpty {
                    Text(L10n.t("Nothing yet. Use “Add Folder…” in the menu bar, or open a folder in Finder and use “Add Current Finder Folder”."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if folders.entries.count > 12 {
                    // Limit scroll height when folder count is large.
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(folders.entries, id: \.path) { folder in
                                folderRow(folder)
                                    .padding(.vertical, 5)
                                if folder.path != folders.entries.last?.path {
                                    Divider()
                                }
                            }
                        }
                        .padding(.trailing, 14)
                    }
                    .frame(height: 400)
                } else {
                    ForEach(folders.entries, id: \.path) { folder in
                        folderRow(folder)
                    }
                }

                Picker(L10n.t("Shown in the menu"),
                       selection: $settings.inlineFolderLimit) {
                    ForEach(AppSettings.inlineFolderLimitChoices(including: settings.inlineFolderLimit),
                            id: \.self) { n in
                        Text(L10n.t("\(n)")).tag(n)
                    }
                }

                Text(L10n.t(
                    "The menu lists the \(settings.inlineFolderLimit) most recently opened; the rest live under More."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } header: {
                Text(folders.entries.isEmpty
                     ? L10n.t("Favorite Folders")
                     : L10n.t("Favorite Folders · \(folders.entries.count)"))
            }

        }
        .formStyle(.grouped)
        .frame(width: kSettingsPaneWidth)
    }

    @ViewBuilder
    private func folderRow(_ folder: FavoriteFolder) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .lineLimit(1)
                Text(folder.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                folders.remove(path: folder.path)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("Remove"))
        }
    }
}

// MARK: - Open With

/// Opener application management.
private struct OpenWithPane: View {
    @ObservedObject var folders: FavoriteFolderStore

    var body: some View {
        Form {
            openWithSection
        }
        .formStyle(.grouped)
        .frame(width: kSettingsPaneWidth)
    }

    @ViewBuilder
    private var openWithSection: some View {
        let apps = OpenerCatalog.candidates(extras: folders.openerExtras)
            .filter { !folders.openerHidden.contains($0.id) }
        Section {
            if apps.count > 12 {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(apps) { app in
                            openerRow(app)
                                .padding(.vertical, 4)
                            if app.id != apps.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.trailing, 14)
                }
                .frame(height: 340)
            } else {
                ForEach(apps) { app in
                    openerRow(app)
                }
            }

            Button {
                addOpenerApp()
            } label: {
                Label(L10n.t("Add App…"), systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Text(L10n.t(
                "Removing an app takes it out of the Open With menu; use “Add App…” to bring any back — or to add editors and terminals the system misses."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        } header: {
            Text(L10n.t("Open With"))
        }
    }

    @ViewBuilder
    private func openerRow(_ app: OpenerApp) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
            Text(app.name)
            Spacer()
            Button {
                folders.removeOpenerExtra(appPath: app.id)
                folders.setOpenerHidden(true, appPath: app.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("Remove from Open With"))
        }
    }

    private func addOpenerApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = FileManager.default
            .urls(for: .applicationDirectory, in: .localDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            folders.addOpenerExtra(appPath: url.standardizedFileURL.path)
        }
    }
}

// MARK: - Shortcuts

private struct HotkeyPane: View {
    @ObservedObject var settings: AppSettings

    private enum Target { case switcher, global, pin }
    @State private var recording: Target?
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section {
                row(label: L10n.t("Open the switcher (hold to cycle)"),
                    target: .switcher,
                    current: settings.switcherHotkey?.displaySpaced,
                    placeholder: "⌃ ⇥",
                    clear: { settings.switcherHotkey = nil })

                row(label: L10n.t("Open the global switcher (all browsers)"),
                    target: .global,
                    current: settings.globalHotkey?.displaySpaced,
                    placeholder: L10n.t("Same as switcher"),
                    clear: { settings.globalHotkey = nil })
                    .disabled(!settings.globalSwitcher)

                row(label: L10n.t("Pin / unpin current tab"),
                    target: .pin,
                    current: settings.pinHotkey?.displaySpaced,
                    placeholder: nil,
                    clear: { settings.pinHotkey = nil })

                Text(L10n.t(
                    "Use at least one of ⌘ / ⌃ / ⌥; ⇧ is reserved for reverse. Esc cancels.\nAll but the global switcher work only while a browser is frontmost. Watch out for ⌘T, ⌘D, and the ⌃⇥ in terminals and editors."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                if !settings.globalSwitcher {
                    Text(L10n.t("The global switcher is off — turn it on under Switcher."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L10n.t("Shortcuts"))
            }
        }
        .formStyle(.grouped)
        .frame(width: kSettingsPaneWidth)
        .onDisappear { stopRecording() }
    }

    @ViewBuilder
    private func row(label: String, target: Target,
                     current: String?, placeholder: String?,
                     clear: @escaping () -> Void) -> some View {
        let isRecording = recording == target
        HStack(spacing: 8) {
            Text(label)
            Spacer()
            Button {
                isRecording ? stopRecording() : startRecording(target)
            } label: {
                Text(isRecording
                     ? L10n.t("Press shortcut…")
                     : (current ?? placeholder ?? L10n.t("Record")))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(current != nil || isRecording ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isRecording ? Color.accentColor.opacity(0.18)
                                              : Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            if current != nil && !isRecording {
                Button(action: clear) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(placeholder == nil ? L10n.t("Clear")
                                         : L10n.t("Reset to default"))
            }
        }
    }

    private func startRecording(_ target: Target) {
        stopRecording()
        recording = target
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopRecording() }
            if event.keyCode == 53 { return nil }   // Esc cancels
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !mods.intersection([.command, .control, .option]).isEmpty,
                  let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
            let config = HotkeyConfig(keyCode: event.keyCode,
                                      modifiers: mods.rawValue,
                                      character: chars.lowercased())
            switch target {
            case .switcher: settings.switcherHotkey = config
            case .global:   settings.globalHotkey = config
            case .pin:      settings.pinHotkey = config
            }
            return nil   // Consumed by recording
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}

// MARK: - About

private struct AboutPane: View {
    @ObservedObject var updates: UpdateChecker

    private var icon: NSImage {
        NSApp.applicationIconImage ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 72, height: 72)

            VStack(spacing: 3) {
                Text("TabCircle").font(.system(size: 16, weight: .semibold))
                Text(L10n.t("Version \(updates.currentVersion)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Button(L10n.t("What's New")) {
                    ReleaseNotes.presentLatest(currentVersion: updates.currentVersion)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }

            Text(L10n.t(
                "MRU tab switching, plus tab management and pins that persist."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button {
                    updates.check(userInitiated: true)
                } label: {
                    if updates.status == .checking {
                        Text(L10n.t("Checking…"))
                    } else if updates.isDownloading {
                        Text(L10n.t("Downloading…"))
                    } else {
                        Text(L10n.t("Check for Updates"))
                    }
                }
                .disabled(updates.status == .checking || updates.isDownloading)

                Button {
                    NSWorkspace.shared.open(URL(string: "https://www.sniperravan.com/sponsor/")!)
                } label: {
                    Label(L10n.t("Sponsor"), systemImage: "heart.fill")
                }
            }

            HStack(spacing: 16) {
                Link(L10n.t("Website"),
                     destination: URL(string: "https://www.sniperravan.com/TabCircle/")!)
                Link("GitHub",
                     destination: URL(string: "https://github.com/sniperravan/TabCircle")!)
                Link(L10n.t("Report an Issue"),
                     destination: URL(string: "https://github.com/sniperravan/TabCircle/issues")!)
            }
            .font(.system(size: 11))

            Text("MIT License © sniperravan")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .frame(width: kSettingsPaneWidth)
    }
}

// MARK: - Window

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let settings: AppSettings
    private let updates: UpdateChecker
    private let folders: FavoriteFolderStore
    private var window: NSWindow?
    private var connected = false

    private var generalHost: NSHostingController<GeneralPane>?
    private var switcherHost: NSHostingController<SwitcherPane>?
    private var tabManagementHost: NSHostingController<TabManagementPane>?
    private var foldersHost: NSHostingController<FoldersPane>?
    private var openWithHost: NSHostingController<OpenWithPane>?
    private var browserHost: NSHostingController<BrowserPane>?
    private var hotkeyHost: NSHostingController<HotkeyPane>?
    private var aboutHost: NSHostingController<AboutPane>?

    private var browserStatuses: [MRUController.BrowserStatus] = []

    func setBrowserStatuses(_ statuses: [MRUController.BrowserStatus]) {
        guard statuses != browserStatuses else { return }
        browserStatuses = statuses
        refreshContentIfVisible()
    }
    private var tabController: NSTabViewController?

    init(settings: AppSettings, updates: UpdateChecker, folders: FavoriteFolderStore) {
        self.settings = settings
        self.updates = updates
        self.folders = folders
        super.init()
    }

    func setConnected(_ value: Bool) {
        guard connected != value else { return }
        connected = value
        refreshContentIfVisible()
    }

    /// Rebuilds window content when language changes.
    func reloadForLanguageChange() {
        guard let tabController else { return }
        for (item, title) in zip(tabController.tabViewItems, Self.paneTitles) {
            item.label = title
        }
        tabController.title = L10n.t("Settings")
        refreshContentIfVisible()
    }

    private static var paneTitles: [String] {
        [L10n.t("General"),
         L10n.t("Switcher"),
         L10n.t("Tabs"),
         L10n.t("Folders"),
         L10n.t("Open With"),
         L10n.t("Browsers"),
         L10n.t("Shortcuts"),
         L10n.t("About")]
    }

    private func refreshContentIfVisible() {
        guard let window, window.isVisible else { return }
        generalHost?.rootView = GeneralPane(settings: settings)
        switcherHost?.rootView = SwitcherPane(settings: settings)
        tabManagementHost?.rootView = TabManagementPane(settings: settings)
        foldersHost?.rootView = FoldersPane(folders: folders, settings: settings)
        openWithHost?.rootView = OpenWithPane(folders: folders)
        browserHost?.rootView = BrowserPane(browsers: browserStatuses)
        hotkeyHost?.rootView = HotkeyPane(settings: settings)
        aboutHost?.rootView = AboutPane(updates: updates)
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        settings.refreshLaunchAtLogin()

        if window == nil {
            let general = NSHostingController(rootView: GeneralPane(settings: settings))
            let switcher = NSHostingController(rootView: SwitcherPane(settings: settings))
            let tabManagement = NSHostingController(rootView: TabManagementPane(settings: settings))
            let foldersPane = NSHostingController(rootView: FoldersPane(folders: folders, settings: settings))
            let openWith = NSHostingController(rootView: OpenWithPane(folders: folders))
            let browser = NSHostingController(rootView: BrowserPane(browsers: browserStatuses))
            let hotkey = NSHostingController(rootView: HotkeyPane(settings: settings))
            let about = NSHostingController(rootView: AboutPane(updates: updates))

            general.sizingOptions = [.preferredContentSize]
            switcher.sizingOptions = [.preferredContentSize]
            tabManagement.sizingOptions = [.preferredContentSize]
            foldersPane.sizingOptions = [.preferredContentSize]
            openWith.sizingOptions = [.preferredContentSize]
            browser.sizingOptions = [.preferredContentSize]
            hotkey.sizingOptions = [.preferredContentSize]
            about.sizingOptions = [.preferredContentSize]
            generalHost = general
            switcherHost = switcher
            tabManagementHost = tabManagement
            foldersHost = foldersPane
            openWithHost = openWith
            browserHost = browser
            hotkeyHost = hotkey
            aboutHost = about

            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            let symbols = ["gearshape", "rectangle.on.rectangle.angled", "rectangle.stack", "folder", "arrow.up.forward.app", "globe", "command", "info.circle"]
            for (index, controller) in ([general, switcher, tabManagement, foldersPane, openWith, browser, hotkey, about] as [NSViewController]).enumerated() {
                let item = NSTabViewItem(viewController: controller)
                item.label = Self.paneTitles[index]
                item.image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)
                tabs.addTabViewItem(item)
            }
            tabs.title = L10n.t("Settings")
            tabController = tabs

            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self

            tabs.view.layoutSubtreeIfNeeded()
            w.setContentSize(general.view.fittingSize)
            w.center()
            window = w
        } else {
            refreshContentIfVisible()
        }

        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let hasVisibleWindow = NSApp.windows.contains { w in
                w.isVisible && !(w is NSPanel) && w.styleMask.contains(.titled) && !w.title.isEmpty
            }
            if !hasVisibleWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
