import AppKit

/// Menu bar icon and status menu.
///
/// TabCircle is an `LSUIElement` without a Dock icon or main window — the menu bar is its only
/// visible presence and the only indicator of whether it is running. The status line must accurately
/// reflect the extension's connection state rather than just showing a static icon.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    /// Browser rows (one row per connected browser, each with its own tab submenu).
    /// Rebuilt on every menu open (`menuNeedsUpdate`) without incremental caching —
    /// tabs change frequently, so caching would require complex invalidation logic.
    private var browserItems: [NSMenuItem] = []

    /// Data source for browser rows (active browser sorted first).
    var menuBrowsersProvider: (() -> [MRUController.MenuBrowser])?
    /// Clicked a tab item in a browser submenu. Parameters: (tab.id, browser bundle id).
    var onPickTabInBrowser: ((Int, String) -> Void)?
    /// Clicked an item in "Recently Closed". Parameters: (ClosedTab.id, browser bundle id).
    var onReopenClosedTab: ((String, String) -> Void)?
    /// Cleared closed tab history for a browser. Parameter: browser bundle id.
    var onClearClosedTabs: ((String) -> Void)?

    /// "Pin Current Tab" menu item. Title and icon toggle according to pin state.
    private let favoriteItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// Whether the current tab is pinned; nil = no current tab (disconnected), menu item disabled.
    var favoriteState: (() -> Bool?)?
    /// Clicked "Pin / Unpin Current Tab".
    var onToggleFavorite: (() -> Void)?
    /// Pin shortcut (displayed on the right side of the menu item). nil = not configured.
    var pinHotkeyProvider: (() -> (key: String, modifiers: NSEvent.ModifierFlags)?)?

    /// "Favorite Folders" section. Folder rows are rebuilt dynamically on menu open,
    /// inserted below sepAfterPin. "Add Current Finder Folder" and "Pin Current Tab"
    /// share the contextual action slot (mutually exclusive).
    private var folderItems: [NSMenuItem] = []
    private let addFinderFolderItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// "Add Folder…": Displays an open panel to add any folder. Persistently stays at
    /// the end of the folder list regardless of foreground app.
    private let addFolderItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    /// "Add / Remove Current App from Exclusion List". Visible only when foreground app is not a browser.
    /// Right when a shortcut conflict occurs, the user is in that app, which is much faster than opening settings.
    private let excludeAppItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// The frontmost app captured at the moment the menu opens.
    private var frontAppForExclude: (bundleID: String, name: String)?

    /// Whether this app is in the exclusion list.
    var isAppExcluded: ((String) -> Bool)?
    /// Clicked exclude / stop excluding. Parameters: bundle id and display name.
    var onToggleExcludeApp: ((String, String) -> Void)?
    /// Whether the global switcher is enabled. If disabled, key interception is off, so hide this item.
    var globalSwitcherEnabled: (() -> Bool)?

    /// Separators before and after the action slot. Cleaned up dynamically depending on contextual visibility.
    private var sepAfterStatus = NSMenuItem.separator()
    private var sepAfterPin = NSMenuItem.separator()

    /// Data source for favorite folders.
    var favoriteFoldersProvider: (() -> [FavoriteFolder])?
    /// Inline folder limit (Settings -> Folder Management). nil uses default.
    var inlineFolderLimitProvider: (() -> Int)?
    /// Clicked "Add Current Finder Folder".
    var onAddFinderFolder: (() -> Void)?
    /// Selected a directory in "Add Folder…". Returns whether it was successfully added.
    var onAddFolder: ((String) -> Bool)?
    /// Clicked "Remove from Favorites" for a folder.
    var onRemoveFolder: ((String) -> Void)?
    /// A folder was opened with an opener app (records recency). Parameters: (normalized path, opener app).
    var onFolderOpened: ((String, OpenerApp) -> Void)?
    /// Opener apps list for folders.
    var folderOpenersProvider: (() -> [OpenerApp])?

    /// "Extension update required" warning item.
    private let warningItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var extensionWarning: (() -> String?)?
    var onExtensionWarningClick: (() -> Void)?

    /// Open app settings window.
    var onOpenSettings: (() -> Void)?
    /// Clicked "Authorize" in unauthorized state.
    var onRequestAuthorization: (() -> Void)?

    /// Unauthorized mode: Menu shows only authorization prompt and quit.
    /// Must stay in a menu rather than a window so it does not steal focus from System Settings.
    private var unauthorized = false

    func showUnauthorized() {
        unauthorized = true
        statusLine.submenu = nil
        buildMenu()
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                accessibilityDescription: "TabCircle")
            image?.isTemplate = true
            button.image = image
            button.alphaValue = 1.0
        }
        statusLine.title = L10n.t("Not authorized — Accessibility permission required")
        statusLine.icon = Self.symbol("exclamationmark.triangle")
    }
    var onCheckForUpdates: (() -> Void)?

    private var connected = false
    private var lastTabCount = 0
    private var lastBrowserName: String?

    override init() {
        super.init()
        buildMenu()
        render(connected: false, tabCount: 0, browserName: nil)
    }

    // MARK: - Menu

    private func buildMenu() {
        // statusLine / favoriteItem are reused stored properties, and an NSMenuItem can only
        // belong to one menu at a time. Must remove from old menu before inserting.
        statusLine.menu?.removeItem(statusLine)
        favoriteItem.menu?.removeItem(favoriteItem)
        warningItem.menu?.removeItem(warningItem)
        addFinderFolderItem.menu?.removeItem(addFinderFolderItem)

        let menu = NSMenu()
        // autoenablesItems disabled to prevent empty submenus from getting permanently disabled.
        menu.autoenablesItems = false
        menu.delegate = self

        statusLine.isEnabled = false
        menu.addItem(statusLine)

        // Extension version warning item, updated in menuNeedsUpdate.
        warningItem.target = self
        warningItem.action = #selector(warningClicked)
        warningItem.isHidden = true
        menu.addItem(warningItem)

        sepAfterStatus = .separator()
        menu.addItem(sepAfterStatus)

        // Standardize icons: either all items have icons or none.
        if unauthorized {
            let grant = NSMenuItem(title: L10n.t("Authorize TabCircle…"),
                                   action: #selector(requestAuthorization), keyEquivalent: "")
            grant.target = self
            grant.icon = Self.symbol("lock.shield")
            menu.addItem(grant)
            menu.addItem(.separator())

            let quitOnly = NSMenuItem(title: L10n.t("Quit TabCircle"),
                                      action: #selector(quit), keyEquivalent: "q")
            quitOnly.target = self
            quitOnly.icon = Self.symbol("power")
            menu.addItem(quitOnly)
            statusItem.menu = menu
            return
        }

        favoriteItem.target = self
        favoriteItem.action = #selector(toggleFavorite)
        favoriteItem.title = L10n.t("Pin Current Tab")
        favoriteItem.icon = Self.symbol("pin")
        favoriteItem.isEnabled = false   // Refreshed in menuNeedsUpdate
        menu.addItem(favoriteItem)

        // Shared slot with "Pin Current Tab": mutually exclusive based on frontmost app.
        addFinderFolderItem.target = self
        addFinderFolderItem.action = #selector(addFinderFolder)
        addFinderFolderItem.title = L10n.t("Add Current Finder Folder")
        addFinderFolderItem.icon = Self.symbol("folder.badge.plus")
        addFinderFolderItem.isEnabled = true
        menu.addItem(addFinderFolderItem)

        excludeAppItem.target = self
        excludeAppItem.action = #selector(toggleExcludeCurrentApp)
        excludeAppItem.isEnabled = true
        menu.addItem(excludeAppItem)

        sepAfterPin = .separator()
        menu.addItem(sepAfterPin)

        // Favorite folders list inserted below sepAfterPin, "Add Folder…" stays at bottom.
        addFolderItem.target = self
        addFolderItem.action = #selector(pickFolder)
        addFolderItem.title = L10n.t("Add Folder…")
        addFolderItem.icon = Self.symbol("plus.rectangle.on.folder")
        addFolderItem.isEnabled = true
        menu.addItem(addFolderItem)

        menu.addItem(.separator())

        let updates = NSMenuItem(title: L10n.t("Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        updates.icon = Self.symbol("arrow.triangle.2.circlepath")
        menu.addItem(updates)

        let settings = NSMenuItem(title: L10n.t("Settings…"),
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        settings.icon = Self.symbol("gearshape")
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.t("Quit TabCircle"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.icon = Self.symbol("power")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Rebuilds the menu on language or configuration change.
    func rebuildMenu() {
        buildMenu()
        render(connected: connected, tabCount: lastTabCount, browserName: lastBrowserName)
    }

    // MARK: - Status

    /// browserName: Display name of active browser.
    func render(connected: Bool, tabCount: Int, browserName: String?) {
        self.connected = connected
        self.lastTabCount = tabCount
        self.lastBrowserName = browserName

        statusItem.button?.image = Self.cardIcon
        // Dim icon when disconnected without changing symbol geometry.
        statusItem.button?.alphaValue = connected ? 1.0 : 0.45

        // Status line is shown only when disconnected.
        statusLine.title = L10n.t("Extension not connected")
        statusLine.icon = Self.symbol("exclamationmark.circle")
        statusLine.isEnabled = false
    }

    // MARK: - Tab Submenu

    /// Builds browser rows and submenus on every menu open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        refreshBrowserLines(in: menu)

        // Action items adjust to frontmost context.
        let frontApp = NSWorkspace.shared.frontmostApplication
        let front = frontApp?.bundleIdentifier
        let pinVisible = refreshFavoriteItem(browserIsFront: BrowserSupport.isSupported(front))
        let finderIsFront = front == "com.apple.finder"
        addFinderFolderItem.isHidden = !finderIsFront
        let excludeVisible = refreshExcludeItem(frontApp)
        refreshFolderLines(in: menu)
        refreshWarningItem()

        // Clean up consecutive separators.
        if !unauthorized {
            sepAfterPin.isHidden = !(pinVisible || finderIsFront || excludeVisible)
        }
    }

    /// One row per connected browser.
    private func refreshBrowserLines(in menu: NSMenu) {
        for item in browserItems { menu.removeItem(item) }
        browserItems.removeAll()

        let browsers = menuBrowsersProvider?() ?? []
        statusLine.isHidden = !browsers.isEmpty
        guard !browsers.isEmpty else { return }

        var insertIndex = menu.index(of: statusLine) + 1
        for browser in browsers {
            let count = browser.entries.count
            let item = NSMenuItem(title: L10n.t("\(browser.name) · \(count) tab\(count == 1 ? "" : "s")"),
                                  action: nil, keyEquivalent: "")
            item.icon = Self.browserIcon(browser.bundleID)
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            fillTabsMenu(submenu, browser: browser)
            item.submenu = submenu
            item.isEnabled = true
            menu.insertItem(item, at: insertIndex)
            insertIndex += 1
            browserItems.append(item)
        }
    }

    /// Resizes browser app icon to standard 16pt.
    private static func browserIcon(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return symbol("globe")
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    private func refreshWarningItem() {
        guard let text = extensionWarning?() else {
            warningItem.isHidden = true
            return
        }
        warningItem.isHidden = false
        warningItem.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.systemOrange,
                         .font: NSFont.menuFont(ofSize: 0)])
        warningItem.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                    accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
    }

    @objc private func warningClicked() {
        onExtensionWarningClick?()
    }

    /// Returns whether the menu item is visible. Hidden when browser is frontmost.
    private func refreshExcludeItem(_ app: NSRunningApplication?) -> Bool {
        frontAppForExclude = nil
        excludeAppItem.isHidden = true
        guard globalSwitcherEnabled?() ?? false,
              let app,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              !BrowserSupport.isSupported(bundleID) else { return false }

        let name = app.localizedName ?? bundleID
        frontAppForExclude = (bundleID, name)
        excludeAppItem.isHidden = false
        let excluded = isAppExcluded?(bundleID) ?? false
        excludeAppItem.title = excluded
            ? L10n.t("Stop Excluding \(name)")
            : L10n.t("Exclude \(name)")
        excludeAppItem.icon = Self.symbol(excluded ? "hand.raised.slash" : "hand.raised")
        return true
    }

    @objc private func toggleExcludeCurrentApp() {
        guard let app = frontAppForExclude else { return }
        onToggleExcludeApp?(app.bundleID, app.name)
    }

    /// Returns whether the favorite menu item is visible.
    private func refreshFavoriteItem(browserIsFront: Bool) -> Bool {
        favoriteItem.isHidden = !browserIsFront
        guard browserIsFront else { return false }
        if let isFavorited = favoriteState?() {
            favoriteItem.isEnabled = true
            favoriteItem.title = isFavorited
                ? L10n.t("Unpin Current Tab")
                : L10n.t("Pin Current Tab")
            favoriteItem.icon = Self.symbol(isFavorited ? "pin.fill" : "pin")
        } else {
            favoriteItem.isEnabled = false
            favoriteItem.title = L10n.t("Pin Current Tab")
            favoriteItem.icon = Self.symbol("pin")
        }
        if let hotkey = pinHotkeyProvider?() {
            favoriteItem.keyEquivalent = hotkey.key
            favoriteItem.keyEquivalentModifierMask = hotkey.modifiers
        } else {
            favoriteItem.keyEquivalent = ""
            favoriteItem.keyEquivalentModifierMask = []
        }
        return true
    }

    private func fillTabsMenu(_ menu: NSMenu, browser: MRUController.MenuBrowser) {
        menu.removeAllItems()
        let entries = browser.entries

        // Group by window when multiple windows exist.
        var windowOrder: [Int] = []
        for entry in entries where !windowOrder.contains(entry.tab.windowId) {
            windowOrder.append(entry.tab.windowId)
        }

        for (groupIndex, windowId) in windowOrder.enumerated() {
            let group = entries.filter { $0.tab.windowId == windowId }
            if windowOrder.count > 1 {
                menu.addItem(.sectionHeader(title: L10n.t(
                    "Window \(groupIndex + 1) · \(group.count) tab\(group.count == 1 ? "" : "s")")))
            }
            for entry in group {
                let raw = entry.tab.title.isEmpty ? entry.tab.url : entry.tab.title
                let title = raw.count > 60 ? String(raw.prefix(60)) + "…" : raw
                let item = NSMenuItem(title: title, action: #selector(pickTab(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["tabId": entry.tab.id, "browser": browser.bundleID] as [String: Any]
                item.icon = Self.faviconIcon(entry.icon)
                if entry.tab.id == entries.first?.tab.id {
                    item.state = .on   // MRU first entry is current tab
                }
                if let rel = entry.tab.relativeLastAccessed {
                    item.badge = NSMenuItemBadge(string: rel)
                }
                menu.addItem(item)
            }
        }

        fillClosedSection(menu, browser: browser)
    }

    /// Recently closed tabs section. Hidden if empty.
    private func fillClosedSection(_ menu: NSMenu, browser: MRUController.MenuBrowser) {
        guard !browser.closed.isEmpty else { return }

        menu.addItem(.separator())
        let shown = browser.closed.count
        let total = max(browser.closedTotal, shown)
        menu.addItem(.sectionHeader(title: total > shown
            ? L10n.t("Recently closed · \(shown) of \(total)")
            : L10n.t("Recently closed · \(shown)")))

        for entry in browser.closed {
            let raw = entry.tab.displayTitle
            let title = raw.count > 60 ? String(raw.prefix(60)) + "…" : raw
            let item = NSMenuItem(title: title, action: #selector(reopenClosed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["closedId": entry.tab.id,
                                      "browser": browser.bundleID] as [String: Any]
            item.icon = Self.faviconIcon(entry.icon)
            let reason = entry.tab.reason.label
            item.badge = NSMenuItemBadge(
                string: entry.tab.relativeClosedAt.map { "\(reason) · \($0)" } ?? reason)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let clear = NSMenuItem(title: L10n.t("Clear All \(total) Records"),
                               action: #selector(clearClosed(_:)), keyEquivalent: "")
        clear.target = self
        clear.representedObject = browser.bundleID
        clear.icon = Self.symbol("trash")
        menu.addItem(clear)
    }

    /// Standardize favicon size to 16pt.
    private static func faviconIcon(_ icon: NSImage?) -> NSImage? {
        guard let icon, let copy = icon.copy() as? NSImage else { return symbol("globe") }
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    // MARK: - Favorite Folders

    /// Default inline folder limit.
    private static let kInlineFolderLimit = AppSettings.defaultInlineFolderLimit

    /// Favorite folders list: top recent folders inline, overflow in "More ▸".
    private func refreshFolderLines(in menu: NSMenu) {
        for item in folderItems { item.menu?.removeItem(item) }
        folderItems.removeAll()
        // Hidden in unauthorized mode.
        guard sepAfterPin.menu === menu else { return }

        var insertIndex = menu.index(of: sepAfterPin) + 1
        let header = NSMenuItem.sectionHeader(title: L10n.t("Favorite Folders"))
        menu.insertItem(header, at: insertIndex)
        folderItems.append(header)
        insertIndex += 1

        let folders = FavoriteFolderStore.byRecency(favoriteFoldersProvider?() ?? [])
        guard !folders.isEmpty else { return }

        // Query opener apps once for all folders.
        let openers = folderOpenersProvider?() ?? []
        // Disambiguate titles across the full collection.
        let titles = FavoriteFolderStore.displayTitles(folders)
        let limit = max(1, inlineFolderLimitProvider?() ?? Self.kInlineFolderLimit)

        for (folder, title) in zip(folders.prefix(limit), titles.prefix(limit)) {
            let item = folderMenuItem(folder, title: title, openers: openers)
            menu.insertItem(item, at: insertIndex)
            insertIndex += 1
            folderItems.append(item)
        }

        let overflowFolders = folders.dropFirst(limit)
        if !overflowFolders.isEmpty {
            let more = NSMenuItem(title: L10n.t("More"), action: nil, keyEquivalent: "")
            more.icon = Self.symbol("ellipsis.circle")
            more.badge = NSMenuItemBadge(count: overflowFolders.count)
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for (folder, title) in zip(overflowFolders, titles.dropFirst(limit)) {
                submenu.addItem(folderMenuItem(folder, title: title, openers: openers))
            }
            more.submenu = submenu
            more.isEnabled = true
            menu.insertItem(more, at: insertIndex)
            insertIndex += 1
            folderItems.append(more)
        }
    }

    /// Single favorite folder menu item.
    private func folderMenuItem(_ folder: FavoriteFolder, title: String,
                                openers: [OpenerApp]) -> NSMenuItem {
        let exists = FileManager.default.fileExists(atPath: folder.path)
        let item = NSMenuItem(title: exists ? title : title + L10n.t(" (missing)"),
                              action: nil, keyEquivalent: "")
        item.toolTip = folder.path
        item.icon = exists
            ? Self.menuIcon(NSWorkspace.shared.icon(forFile: folder.path))
            : Self.symbol("questionmark.folder")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        // If missing on disk, only allow copy path and remove from favorites.
        fillFolderMenu(submenu, folder: folder, openers: exists ? openers : [])
        item.submenu = submenu
        item.isEnabled = true
        return item
    }

    private func fillFolderMenu(_ menu: NSMenu, folder: FavoriteFolder,
                                openers: [OpenerApp]) {
        if !openers.isEmpty {
            menu.addItem(.sectionHeader(title: L10n.t("Open With")))
            for opener in openers {
                let item = NSMenuItem(title: opener.name,
                                      action: #selector(openFolder(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["path": folder.path, "opener": opener] as [String: Any]
                item.icon = Self.menuIcon(NSWorkspace.shared.icon(forFile: opener.url.path))
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let copy = NSMenuItem(title: L10n.t("Copy Path"),
                              action: #selector(copyFolderPath(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = folder.path
        copy.icon = Self.symbol("doc.on.doc")
        menu.addItem(copy)

        let remove = NSMenuItem(title: L10n.t("Remove from Favorites"),
                                action: #selector(removeFolder(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = folder.path
        remove.icon = Self.symbol("folder.badge.minus")
        menu.addItem(remove)
    }

    /// Resizes icon to standard 16pt.
    private static func menuIcon(_ icon: NSImage) -> NSImage {
        guard let copy = icon.copy() as? NSImage else { return icon }
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    @objc private func addFinderFolder() {
        onAddFinderFolder?()
    }

    /// "Add Folder…": Open folder selection panel.
    @objc private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.t("Choose a folder to add to favorites")
        panel.prompt = L10n.t("Add")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard onAddFolder?(url.path) == true else { return }
        // Re-open status menu after adding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    @objc private func openFolder(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let path = info["path"] as? String,
              let opener = info["opener"] as? OpenerApp else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let appName = opener.name
        let folderName = folder.lastPathComponent
        let report: (Error?) -> Void = { error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error {
                        log("⚠️  open folder failed: \(error.localizedDescription)")
                        Toast.show(L10n.t("Failed to open"),
                                   detail: error.localizedDescription, kind: .failure)
                    } else {
                        Toast.show(L10n.t("Opened “\(folderName)” in \(appName)"),
                                   detail: path)
                    }
                }
            }
        }
        switch opener.launch {
        case .document:
            NSWorkspace.shared.open([folder], withApplicationAt: opener.url,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                report(error)
            }
        case .claudeCode:
            guard let link = OpenerCatalog.claudeCodeURL(folder: path) else {
                log("⚠️  claude code deep link failed to build for \(path)")
                return
            }
            NSWorkspace.shared.open(link, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                report(error)
            }
        }
        log("📁 open \(path) with \(opener.id)")
        onFolderOpened?(path, opener)
    }

    @objc private func copyFolderPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        Toast.show(L10n.t("Path copied"), detail: path)
    }

    @objc private func removeFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onRemoveFolder?(path)
    }

    @objc private func pickTab(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let tabId = info["tabId"] as? Int,
              let browser = info["browser"] as? String else { return }
        onPickTabInBrowser?(tabId, browser)
    }

    @objc private func reopenClosed(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let id = info["closedId"] as? String,
              let browser = info["browser"] as? String else { return }
        onReopenClosedTab?(id, browser)
    }

    @objc private func clearClosed(_ sender: NSMenuItem) {
        guard let browser = sender.representedObject as? String else { return }
        onClearClosedTabs?(browser)
    }

    // MARK: - Icons

    /// Menu bar icon: stacked cards with front solid card and back outlined tilted card.
    private static let cardIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let w: CGFloat = 9.5, h: CGFloat = 12, r: CGFloat = 2.25, stroke: CGFloat = 1.2

            let front = NSRect(x: 0, y: 0, width: w, height: h)

            // Back card: same size, rotated -9 degrees.
            let backCenter = NSPoint(x: front.midX + 3.2, y: front.midY - 3.2)
            let t = NSAffineTransform()
            t.translateX(by: backCenter.x, yBy: backCenter.y)
            t.rotate(byDegrees: -9)
            t.translateX(by: -backCenter.x, yBy: -backCenter.y)
            let backRect = NSRect(x: backCenter.x - w / 2, y: backCenter.y - h / 2,
                                  width: w, height: h)
            let back = NSBezierPath(roundedRect: backRect, xRadius: r, yRadius: r)
            back.transform(using: t as AffineTransform)
            back.lineWidth = stroke

            // Center ink within icon bounds.
            let ink = front.union(back.bounds.insetBy(dx: -stroke / 2, dy: -stroke / 2))
            NSGraphicsContext.current?.cgContext.translateBy(x: rect.midX - ink.midX,
                                                             y: rect.midY - ink.midY)

            NSColor.black.setStroke()
            back.stroke()

            // Cut out boundary around front card.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(roundedRect: front.insetBy(dx: -1.3, dy: -1.3),
                         xRadius: r + 1.3, yRadius: r + 1.3).fill()
            NSGraphicsContext.restoreGraphicsState()

            // Front card fill.
            NSColor.black.setFill()
            NSBezierPath(roundedRect: front, xRadius: r, yRadius: r).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "TabCircle"
        return image
    }()

    // MARK: - Actions

    @objc private func requestAuthorization() {
        onRequestAuthorization?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func toggleFavorite() {
        onToggleFavorite?()
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension NSMenuItem {
    /// Standardized menu item icon visibility helper.
    var icon: NSImage? {
        get { image }
        set {
            image = newValue
            if #available(macOS 27, *) {
                preferredImageVisibility = newValue == nil ? .automatic : .visible
            }
        }
    }
}
