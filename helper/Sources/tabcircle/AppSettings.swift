import AppKit
import Foundation
import ServiceManagement

/// Interface appearance preference.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// Returns NSAppearance instance (nil yields system default).
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

/// Switcher panel layout style.
enum SwitcherLayout: String, CaseIterable, Identifiable {
    case strip
    case grid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .strip: return "Horizontal strip"
        case .grid:  return "Grid"
        }
    }
}

/// Presentation style for the global switcher.
enum GlobalSwitcherStyle: String, CaseIterable, Identifiable {
    case list
    case cards

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list:  return "List"
        case .cards: return "Cards"
        }
    }
}

/// Global switcher exclusion item: when this app is frontmost, shortcuts pass through.
struct ExcludedApp: Codable, Identifiable, Equatable {
    let bundleID: String
    let name: String

    var id: String { bundleID }
}

/// Pinned favorite tab record.
struct FavoriteTab: Codable, Identifiable, Equatable {
    let id: String
    let url: String
    let title: String
    let favIconUrl: String?
    let browser: String

    init(url: String, title: String, favIconUrl: String? = nil, browser: String) {
        self.id = UUID().uuidString
        self.url = url
        self.title = title
        self.favIconUrl = favIconUrl
        self.browser = browser
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? url
        favIconUrl = try c.decodeIfPresent(String.self, forKey: .favIconUrl)
        browser = try c.decodeIfPresent(String.self, forKey: .browser) ?? "com.google.Chrome"
    }
}

/// User-recorded shortcut configuration.
struct HotkeyConfig: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: UInt
    let character: String

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
            .intersection([.command, .control, .option, .shift])
    }

    var display: String {
        var s = ""
        let mods = modifierFlags
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        switch character {
        case "\t":     return s + "⇥"
        case " ":      return s + "Space"
        case "\r":     return s + "↩"
        default:       return s + character.uppercased()
        }
    }

    var displaySpaced: String {
        let d = display
        let mods = d.prefix { "⌃⌥⇧⌘".contains($0) }
        let key = d.dropFirst(mods.count)
        return mods.isEmpty ? String(key) : "\(mods) \(key)"
    }

    var cgFlags: CGEventFlags {
        var f = CGEventFlags()
        let mods = modifierFlags
        if mods.contains(.control) { f.insert(.maskControl) }
        if mods.contains(.option) { f.insert(.maskAlternate) }
        if mods.contains(.shift) { f.insert(.maskShift) }
        if mods.contains(.command) { f.insert(.maskCommand) }
        return f
    }
}

/// Pending unpin operation queued while target browser is offline.
struct PendingUnpin: Codable, Equatable {
    let browser: String
    let host: String
}

/// Tab lifetime options for automatic cleanup.
enum TabLifetime: String, CaseIterable, Identifiable {
    case forever
    case h12
    case h24
    case d7
    case m1
    case m3
    case m6
    case y1

    var id: String { rawValue }

    var label: String {
        switch self {
        case .forever: return "Forever"
        case .h12:     return "12 hours"
        case .h24:     return "24 hours"
        case .d7:      return "7 days"
        case .m1:      return "1 month"
        case .m3:      return "3 months"
        case .m6:      return "6 months"
        case .y1:      return "1 year"
        }
    }

    var hours: Int {
        switch self {
        case .forever: return 0
        case .h12:     return 12
        case .h24:     return 24
        case .d7:      return 24 * 7
        case .m1:      return 24 * 30
        case .m3:      return 24 * 90
        case .m6:      return 24 * 180
        case .y1:      return 24 * 365
        }
    }
}

/// Frequency schedule for automatic update checks.
enum UpdateCheckFrequency: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily:  return "Daily"
        case .weekly: return "Weekly"
        case .never:  return "Never"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .daily:  return 86_400
        case .weekly: return 604_800
        case .never:  return nil
        }
    }
}

/// Application settings store.
@MainActor
final class AppSettings: ObservableObject {

    private enum Key {
        static let scopeToWindow = "scopeToWindow"
        static let appearance = "appearance"
        static let switcherLayout = "switcherLayout"
        static let updateCheckFrequency = "updateCheckFrequency"
        static let allowTabClose = "allowTabClose"
        static let tabLifetime = "tabLifetime"
        static let favorites = "favoriteTabs"
        static let favoriteCurrentUrls = "favoriteCurrentUrls"
        static let pinHotkey = "pinHotkey"
        static let switcherHotkey = "switcherHotkey"
        static let globalHotkey = "globalHotkey"
        static let globalSwitcher = "globalSwitcher"
        static let globalSwitcherStyle = "globalSwitcherStyle"
        static let globalExcludedApps = "globalExcludedApps"
        static let knownBrowsers = "knownBrowsers"
        static let pendingUnpins = "pendingUnpins"
        static let inlineFolderLimit = "inlineFolderLimit"
    }

    static let inlineFolderLimitRange = 1...20
    static let defaultInlineFolderLimit = 5

    static func inlineFolderLimitChoices(including current: Int) -> [Int] {
        var choices = [3, 5, 8, 10, 15, 20]
        if !choices.contains(current) { choices.append(current); choices.sort() }
        return choices
    }

    var onChange: (() -> Void)?
    var onLanguageChange: (() -> Void)?

    @Published var language: L10n.Language = L10n.language {
        didSet {
            guard oldValue != language else { return }
            L10n.language = language
            onLanguageChange?()
        }
    }

    @Published var appearance: AppAppearance {
        didSet {
            guard oldValue != appearance else { return }
            UserDefaults.standard.set(appearance.rawValue, forKey: Key.appearance)
            NSApp.appearance = appearance.nsAppearance
        }
    }

    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    @Published var scopeToWindow: Bool {
        didSet {
            guard oldValue != scopeToWindow else { return }
            UserDefaults.standard.set(scopeToWindow, forKey: Key.scopeToWindow)
            onChange?()
        }
    }

    @Published var switcherLayout: SwitcherLayout {
        didSet {
            guard oldValue != switcherLayout else { return }
            UserDefaults.standard.set(switcherLayout.rawValue, forKey: Key.switcherLayout)
        }
    }

    @Published var allowTabClose: Bool {
        didSet {
            guard oldValue != allowTabClose else { return }
            UserDefaults.standard.set(allowTabClose, forKey: Key.allowTabClose)
        }
    }

    @Published var globalSwitcher: Bool {
        didSet {
            guard oldValue != globalSwitcher else { return }
            UserDefaults.standard.set(globalSwitcher, forKey: Key.globalSwitcher)
            onInterceptScopeChange?()
        }
    }

    @Published var globalSwitcherStyle: GlobalSwitcherStyle {
        didSet {
            guard oldValue != globalSwitcherStyle else { return }
            UserDefaults.standard.set(globalSwitcherStyle.rawValue, forKey: Key.globalSwitcherStyle)
        }
    }

    @Published var globalExcludedApps: [ExcludedApp] {
        didSet {
            guard oldValue != globalExcludedApps else { return }
            if let data = try? JSONEncoder().encode(globalExcludedApps) {
                UserDefaults.standard.set(data, forKey: Key.globalExcludedApps)
            }
            onInterceptScopeChange?()
        }
    }

    var onInterceptScopeChange: (() -> Void)?
    var onFavoritesRemoved: (([FavoriteTab]) -> Void)?
    var onHotkeyChange: (() -> Void)?

    @Published var pinHotkey: HotkeyConfig? {
        didSet {
            guard oldValue != pinHotkey else { return }
            if let hk = pinHotkey, let data = try? JSONEncoder().encode(hk) {
                UserDefaults.standard.set(data, forKey: Key.pinHotkey)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.pinHotkey)
            }
            onHotkeyChange?()
        }
    }

    @Published var switcherHotkey: HotkeyConfig? {
        didSet {
            guard oldValue != switcherHotkey else { return }
            if let hk = switcherHotkey, let data = try? JSONEncoder().encode(hk) {
                UserDefaults.standard.set(data, forKey: Key.switcherHotkey)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.switcherHotkey)
            }
            onHotkeyChange?()
        }
    }

    @Published var globalHotkey: HotkeyConfig? {
        didSet {
            guard oldValue != globalHotkey else { return }
            if let hk = globalHotkey, let data = try? JSONEncoder().encode(hk) {
                UserDefaults.standard.set(data, forKey: Key.globalHotkey)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.globalHotkey)
            }
            onHotkeyChange?()
        }
    }

    @Published var pendingUnpins: [PendingUnpin] {
        didSet {
            guard oldValue != pendingUnpins else { return }
            if let data = try? JSONEncoder().encode(pendingUnpins) {
                UserDefaults.standard.set(data, forKey: Key.pendingUnpins)
            }
        }
    }

    @Published var knownBrowsers: [String] {
        didSet {
            guard oldValue != knownBrowsers else { return }
            UserDefaults.standard.set(knownBrowsers, forKey: Key.knownBrowsers)
        }
    }

    @Published var favorites: [FavoriteTab] {
        didSet {
            guard oldValue != favorites else { return }
            if let data = try? JSONEncoder().encode(favorites) {
                UserDefaults.standard.set(data, forKey: Key.favorites)
            }
            let removed = oldValue.filter { old in !favorites.contains(where: { $0.id == old.id }) }
            if !removed.isEmpty { onFavoritesRemoved?(removed) }
            onChange?()
            for fav in removed { favoriteCurrentUrls.removeValue(forKey: fav.id) }
        }
    }

    @Published var favoriteCurrentUrls: [String: String] {
        didSet {
            guard oldValue != favoriteCurrentUrls else { return }
            UserDefaults.standard.set(favoriteCurrentUrls, forKey: Key.favoriteCurrentUrls)
        }
    }

    @Published var tabLifetime: TabLifetime {
        didSet {
            guard oldValue != tabLifetime else { return }
            UserDefaults.standard.set(tabLifetime.rawValue, forKey: Key.tabLifetime)
            onChange?()
        }
    }

    @Published var inlineFolderLimit: Int {
        didSet {
            guard oldValue != inlineFolderLimit else { return }
            UserDefaults.standard.set(inlineFolderLimit, forKey: Key.inlineFolderLimit)
        }
    }

    @Published var updateCheckFrequency: UpdateCheckFrequency {
        didSet {
            guard oldValue != updateCheckFrequency else { return }
            UserDefaults.standard.set(updateCheckFrequency.rawValue, forKey: Key.updateCheckFrequency)
        }
    }

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchNeedsApproval: Bool

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Key.scopeToWindow: true])
        scopeToWindow = defaults.bool(forKey: Key.scopeToWindow)
        appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        switcherLayout = SwitcherLayout(rawValue: defaults.string(forKey: Key.switcherLayout) ?? "") ?? .strip
        allowTabClose = defaults.bool(forKey: Key.allowTabClose)
        tabLifetime = TabLifetime(rawValue: defaults.string(forKey: Key.tabLifetime) ?? "") ?? .forever
        favorites = defaults.data(forKey: Key.favorites)
            .flatMap { try? JSONDecoder().decode([FavoriteTab].self, from: $0) } ?? []
        pinHotkey = defaults.data(forKey: Key.pinHotkey)
            .flatMap { try? JSONDecoder().decode(HotkeyConfig.self, from: $0) }
        switcherHotkey = defaults.data(forKey: Key.switcherHotkey)
            .flatMap { try? JSONDecoder().decode(HotkeyConfig.self, from: $0) }
        globalHotkey = defaults.data(forKey: Key.globalHotkey)
            .flatMap { try? JSONDecoder().decode(HotkeyConfig.self, from: $0) }
        globalSwitcher = defaults.bool(forKey: Key.globalSwitcher)
        globalSwitcherStyle = GlobalSwitcherStyle(rawValue: defaults.string(forKey: Key.globalSwitcherStyle) ?? "") ?? .list
        globalExcludedApps = defaults.data(forKey: Key.globalExcludedApps)
            .flatMap { try? JSONDecoder().decode([ExcludedApp].self, from: $0) } ?? []
        knownBrowsers = defaults.stringArray(forKey: Key.knownBrowsers) ?? []
        pendingUnpins = defaults.data(forKey: Key.pendingUnpins)
            .flatMap { try? JSONDecoder().decode([PendingUnpin].self, from: $0) } ?? []
        favoriteCurrentUrls = defaults.dictionary(forKey: Key.favoriteCurrentUrls) as? [String: String] ?? [:]
        updateCheckFrequency = UpdateCheckFrequency(rawValue: defaults.string(forKey: Key.updateCheckFrequency) ?? "") ?? .daily
        let storedLimit = defaults.integer(forKey: Key.inlineFolderLimit)
        inlineFolderLimit = Self.inlineFolderLimitRange.contains(storedLimit)
            ? storedLimit : Self.defaultInlineFolderLimit

        let state = LoginItem.state
        launchAtLogin = state == .enabled
        launchNeedsApproval = state == .requiresApproval
    }

    func refreshLaunchAtLogin() {
        let state = LoginItem.state
        launchAtLogin = state == .enabled
        launchNeedsApproval = state == .requiresApproval
    }

    func toggleLaunchAtLogin() {
        let result = LoginItem.toggle()
        launchAtLogin = result == .enabled
        launchNeedsApproval = result == .requiresApproval
        if launchNeedsApproval {
            LoginItem.openSystemSettings()
        }
    }

    func payload(favoritesFor browser: String?) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "settings",
            "scopeToWindow": scopeToWindow,
            "tabLifetimeHours": tabLifetime.hours,
        ]
        if let browser {
            payload["pendingUnpinHosts"] = pendingUnpins.filter { $0.browser == browser }.map(\.host)
            payload["favorites"] = favorites.filter { $0.browser == browser }.map {
                ["id": $0.id,
                 "url": $0.url,
                 "title": $0.title,
                 "currentUrl": favoriteCurrentUrls[$0.id] ?? $0.url]
            }
        }
        return payload
    }
}
