import Cocoa

let kPort: UInt16 = 41573

/// Authorization workflow coordinator. Must be strongly retained to prevent timer deallocation.
@MainActor var permissionCoordinator: PermissionCoordinator?
/// Status item displayed during unauthorized state as user entry point.
@MainActor var permissionStatusItem: StatusItemController?

@MainActor
private func fatalAlert(_ title: String, _ message: String) -> Never {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "Quit")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
    exit(1)
}

MainActor.assumeIsolated {

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    log("tabcircle started — binary built \(binaryBuildTime())")

    // Check accessibility permissions before attaching keyboard hooks.
    if !PermissionGuide.isTrusted {
        log("Accessibility permission missing — waiting via menu bar")

        MainMenu.install(openSettings: nil)   // Keep standard ⌘Q working

        let coordinator = PermissionCoordinator()
        let statusItem = StatusItemController()
        statusItem.showUnauthorized()
        statusItem.onRequestAuthorization = {
            MainActor.assumeIsolated { coordinator.authorize() }
        }
        coordinator.startWaiting { PermissionGuide.relaunch() }

        permissionCoordinator = coordinator
        permissionStatusItem = statusItem

        coordinator.authorize()
    } else {
        let settings = AppSettings()
        settings.applyAppearance()

        let updates = UpdateChecker()
        let server = WebSocketServer(port: kPort)
        let controller = MRUController(server: server, settings: settings)
        let statusItem = StatusItemController()
        let folders = FavoriteFolderStore()
        let settingsWindow = SettingsWindowController(settings: settings, updates: updates,
                                                     folders: folders)

        MainMenu.install(openSettings: {
            MainActor.assumeIsolated { settingsWindow.show() }
        })

        updates.frequency = { MainActor.assumeIsolated { settings.updateCheckFrequency } }
        updates.startPeriodicChecks()

        ReleaseNotes.presentIfUpgraded(currentVersion: updates.currentVersion)

        // Settings change handlers
        settings.onChange = { [weak controller] in
            MainActor.assumeIsolated { controller?.pushSettingsToAll() }
        }
        settings.onFavoritesRemoved = { [weak controller] removed in
            MainActor.assumeIsolated { controller?.unpinRemovedFavorites(removed) }
        }
        settings.onLanguageChange = {
            MainActor.assumeIsolated {
                statusItem.rebuildMenu()
                settingsWindow.reloadForLanguageChange()
                MainMenu.rebuild()
            }
        }

        controller.onStatusChange = { connected, tabCount in
            MainActor.assumeIsolated {
                statusItem.render(connected: connected, tabCount: tabCount,
                                  browserName: controller.activeBrowserDisplayName)
                settingsWindow.setConnected(connected)
                settingsWindow.setBrowserStatuses(controller.browserStatuses)
            }
        }

        // Extension version warning badge
        statusItem.extensionWarning = {
            MainActor.assumeIsolated {
                let outdated = controller.browserStatuses.filter(\.needsUpdate)
                guard !outdated.isEmpty else { return nil }
                let names = outdated.map(\.name).joined(separator: ", ")
                return "Extension update needed: \(names)"
            }
        }
        statusItem.onExtensionWarningClick = {
            NSWorkspace.shared.open(URL(string: "https://www.sniperravan.com/TabCircle/install-extension.html")!)
        }

        statusItem.onOpenSettings = {
            MainActor.assumeIsolated { settingsWindow.show() }
        }
        controller.onExtensionRequestedSettings = {
            MainActor.assumeIsolated { settingsWindow.show() }
        }
        statusItem.onCheckForUpdates = {
            MainActor.assumeIsolated { updates.check(userInitiated: true) }
        }

        // Browser row actions
        statusItem.menuBrowsersProvider = {
            MainActor.assumeIsolated { controller.menuBrowsers }
        }
        statusItem.onPickTabInBrowser = { tabId, browser in
            MainActor.assumeIsolated { controller.activateFromMenu(tabId: tabId, browser: browser) }
        }

        // Reopen closed tabs
        statusItem.onReopenClosedTab = { id, browser in
            MainActor.assumeIsolated { controller.reopenClosedTab(id: id, browser: browser) }
        }
        statusItem.onClearClosedTabs = { browser in
            MainActor.assumeIsolated { controller.clearClosedTabs(browser: browser) }
        }

        // Favorite folders integration
        statusItem.favoriteFoldersProvider = {
            MainActor.assumeIsolated { folders.entries }
        }
        statusItem.inlineFolderLimitProvider = {
            MainActor.assumeIsolated { settings.inlineFolderLimit }
        }
        statusItem.onRemoveFolder = { path in
            MainActor.assumeIsolated {
                folders.remove(path: path)
                let name = URL(fileURLWithPath: path).lastPathComponent
                Toast.show("Removed “\(name)” from favorites", detail: path)
            }
        }
        statusItem.onFolderOpened = { path, opener in
            MainActor.assumeIsolated {
                folders.touch(path: path)
                folders.touchOpener(appPath: opener.id)
            }
        }
        statusItem.folderOpenersProvider = {
            MainActor.assumeIsolated { OpenerCatalog.menuOpeners(store: folders) }
        }

        @MainActor @discardableResult
        func addFolder(_ path: String) -> Bool {
            let name = URL(fileURLWithPath: path).lastPathComponent
            switch folders.add(path: path) {
            case .added:
                Toast.show("Added “\(name)” to favorites", detail: path)
                return true
            case .movedToFront:
                Toast.show("“\(name)” is already a favorite — moved to front", detail: path, kind: .info)
                return true
            case .invalid:
                return false
            }
        }
        statusItem.onAddFolder = { path in
            MainActor.assumeIsolated { addFolder(path) }
        }
        statusItem.onAddFinderFolder = {
            FinderFront.fetchFolder { result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let path):
                        addFolder(path)
                    case .failure(.notAuthorized):
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = "Automation permission needed"
                        alert.informativeText = "To favorite the current Finder folder, TabCircle asks Finder which folder its front window shows.\n\nAllow TabCircle to control Finder under System Settings → Privacy & Security → Automation."
                        alert.addButton(withTitle: "Open System Settings")
                        alert.addButton(withTitle: "Later")
                        NSApp.activate(ignoringOtherApps: true)
                        if alert.runModal() == .alertFirstButtonReturn {
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                        }
                    case .failure(.noFolder):
                        let alert = NSAlert()
                        alert.alertStyle = .informational
                        alert.messageText = "No Finder window to add"
                        alert.informativeText = "Open the folder in Finder first, then use this item."
                        alert.addButton(withTitle: "OK")
                        NSApp.activate(ignoringOtherApps: true)
                        alert.runModal()
                    }
                }
            }
        }

        // Global switcher exclusion
        statusItem.globalSwitcherEnabled = {
            MainActor.assumeIsolated { settings.globalSwitcher }
        }
        statusItem.isAppExcluded = { bundleID in
            MainActor.assumeIsolated {
                settings.globalExcludedApps.contains { $0.bundleID == bundleID }
            }
        }
        statusItem.onToggleExcludeApp = { bundleID, name in
            MainActor.assumeIsolated {
                if settings.globalExcludedApps.contains(where: { $0.bundleID == bundleID }) {
                    settings.globalExcludedApps.removeAll { $0.bundleID == bundleID }
                    Toast.show("\(name) no longer excluded")
                } else {
                    settings.globalExcludedApps.append(ExcludedApp(bundleID: bundleID, name: name))
                    Toast.show("\(name) excluded")
                }
            }
        }

        // Pinned tab favorites
        statusItem.favoriteState = {
            MainActor.assumeIsolated { controller.currentTabFavorited }
        }
        statusItem.onToggleFavorite = {
            MainActor.assumeIsolated { controller.toggleFavoriteCurrentTab() }
        }

        statusItem.pinHotkeyProvider = {
            MainActor.assumeIsolated {
                guard let hotkey = settings.pinHotkey else { return nil }
                return (hotkey.character, hotkey.modifierFlags)
            }
        }
        let applyHotkeys = {
            MainActor.assumeIsolated {
                if let hotkey = settings.pinHotkey {
                    configurePinHotkey(keyCode: Int64(hotkey.keyCode), flags: hotkey.cgFlags) {
                        MainActor.assumeIsolated { controller.toggleFavoriteCurrentTab() }
                    }
                } else {
                    configurePinHotkey(keyCode: nil, flags: [], handler: nil)
                }
                if let hotkey = settings.switcherHotkey {
                    configureSwitcherHotkey(keyCode: Int64(hotkey.keyCode), flags: hotkey.cgFlags)
                } else {
                    configureSwitcherHotkey(keyCode: nil, flags: [])
                }
                configureGlobalHotkey(keyCode: settings.globalHotkey.map { Int64($0.keyCode) },
                                      flags: settings.globalHotkey?.cgFlags ?? [],
                                      enabled: settings.globalSwitcher)
            }
        }
        settings.onHotkeyChange = applyHotkeys
        applyHotkeys()

        let applyExclusions = {
            MainActor.assumeIsolated {
                configureExcludedApps(Set(settings.globalExcludedApps.map(\.bundleID)))
            }
        }
        applyExclusions()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated { refreshFrontmostAppState() }
        }

        settings.onInterceptScopeChange = { [weak controller] in
            MainActor.assumeIsolated {
                applyHotkeys()
                applyExclusions()
                controller?.refreshReadiness()
            }
        }

        controller.onExtensionOutdated = { extVersion, requiredVersion in
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Extension update required"
                alert.informativeText = "Extension v\(extVersion) is installed, but this app version needs extension v\(requiredVersion) or newer (the protocol changed; older extensions lose features).\n\nDownload the new extension package, replace your folder, then reload it in chrome://extensions."
                alert.addButton(withTitle: "Open Upgrade Guide")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "https://www.sniperravan.com/TabCircle/install-extension.html")!)
                }
            }
        }

        server.onText = { data, clientID in
            MainActor.assumeIsolated { controller.handleMessage(data, from: clientID) }
        }
        server.onClientConnected = { clientID in
            MainActor.assumeIsolated { controller.handleClientConnected(clientID) }
        }
        server.onClientDisconnected = { clientID in
            MainActor.assumeIsolated { controller.handleClientDisconnected(clientID) }
        }
        server.onClientIdentified = { clientID, browser in
            MainActor.assumeIsolated { controller.handleClientIdentified(clientID, browser: browser) }
        }
        setActiveBrowserChangeHandler {
            MainActor.assumeIsolated { controller.activeBrowserChanged() }
        }

        do {
            try server.start()
            log("WebSocket server listening → ws://127.0.0.1:\(kPort)/")
        } catch {
            log("❌ Failed to start WebSocket server: \(error)")
            fatalAlert(
                "TabCircle could not start",
                "Port \(kPort) is already in use. Another copy of TabCircle may already be running — check the menu bar."
            )
        }

        let tap = EventTap()
        do {
            try tap.start(
                onStep: { backward in
                    MainActor.assumeIsolated { controller.step(backward: backward) }
                },
                onArrow: { direction in
                    MainActor.assumeIsolated { controller.arrow(direction) }
                },
                onCommit: {
                    MainActor.assumeIsolated { controller.commit() }
                },
                onGaveUp: {
                    MainActor.assumeIsolated {
                        log("⚠️  Keyboard hook gave up after repeated timeouts — ⌃⇥ now passes through")
                        statusItem.render(connected: false, tabCount: 0, browserName: nil)
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = "TabCircle stopped intercepting the shortcut"
                        alert.informativeText = "The keyboard hook was repeatedly disabled by the system, so TabCircle turned it off rather than risk interfering with your typing. ⌃⇥ now falls back to Chrome's built-in switching.\n\nRestarting TabCircle restores it. If this keeps happening, please report it on GitHub."
                        alert.addButton(withTitle: "OK")
                        NSApp.activate(ignoringOtherApps: true)
                        alert.runModal()
                    }
                },
                onPermissionLost: {
                    MainActor.assumeIsolated {
                        log("⚠️  Accessibility permission revoked — keyboard hook disabled")
                        statusItem.render(connected: false, tabCount: 0, browserName: nil)
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = "Accessibility permission was removed"
                        alert.informativeText = "TabCircle disabled its keyboard hook immediately, so your typing is unaffected. ⌃⇥ falls back to Chrome's built-in switching.\n\nAfter granting the permission again, quit and reopen TabCircle — macOS only reads this permission when a process starts."
                        alert.addButton(withTitle: "OK")
                        NSApp.activate(ignoringOtherApps: true)
                        alert.runModal()
                    }
                }
            )
            log("Keyboard hook installed — waiting for ⌃⇥ in Chrome")
        } catch {
            log("❌ \(error)")
            fatalAlert(
                "TabCircle could not install its keyboard hook",
                String(describing: error)
            )
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            stopEventTap()
            log("Keyboard hook disabled — quitting")
        }
    }
}

NSApplication.shared.run()
