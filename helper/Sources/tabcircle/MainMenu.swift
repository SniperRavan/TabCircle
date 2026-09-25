import AppKit

/// Main application menu.
///
/// TabCircle is an accessory application and does not typically show a full menu bar,
/// but standard shortcuts like ⌘W / ⌘Q / ⌘, rely on `NSApp.mainMenu` key equivalent routing.
/// When the settings window is open, the app temporarily transitions to `.regular` presentation.
@MainActor
enum MainMenu {

    /// Callback for ⌘,. Stored to reuse when rebuilding menus upon language updates.
    private static var openSettings: (() -> Void)?
    private static let target = ActionTarget()

    /// Install the main menu. Pass nil during unauthorized state to omit "Settings…".
    static func install(openSettings action: (() -> Void)?) {
        openSettings = action
        build()
    }

    /// Rebuild menu on preference changes.
    static func rebuild() {
        build()
    }

    private static func build() {
        let main = NSMenu()

        // App Menu
        let appMenu = NSMenu()
        if openSettings != nil {
            let settings = NSMenuItem(title: "Settings…",
                                      action: #selector(ActionTarget.openSettings(_:)),
                                      keyEquivalent: ",")
            settings.target = target
            appMenu.addItem(settings)
            appMenu.addItem(.separator())
        }
        appMenu.addItem(NSMenuItem(title: "Quit TabCircle",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Edit Menu
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo",
                                action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo",
                                action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut",
                                action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy",
                                action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste",
                                action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All",
                                action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        // Window Menu
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close Window",
                                  action: #selector(NSWindow.performClose(_:)),
                                  keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize",
                                  action: #selector(NSWindow.performMiniaturize(_:)),
                                  keyEquivalent: "m"))
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    @MainActor
    private final class ActionTarget: NSObject {
        @objc func openSettings(_ sender: Any?) {
            MainMenu.openSettings?()
        }
    }
}
