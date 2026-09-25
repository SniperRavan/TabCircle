import AppKit
import Combine
import Foundation

/// A favorited folder entry.
struct FavoriteFolder: Codable, Equatable {
    /// Normalized absolute path (see `FavoriteFolderStore.normalized`).
    let path: String
    /// Added timestamp in ms epoch (same reference as `ClosedTab.closedAt`).
    let addedAt: Double
    /// Most recent timestamp opened from menu (ms epoch). Decodes as nil in legacy archives.
    let openedAt: Double?

    init(path: String, addedAt: Double, openedAt: Double? = nil) {
        self.path = path
        self.addedAt = addedAt
        self.openedAt = openedAt
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    /// Display name in menu: the directory name itself.
    var name: String { url.lastPathComponent }
    /// Sorting key: uses opened timestamp if opened before, otherwise added timestamp.
    var lastUsedAt: Double { openedAt ?? addedAt }
}

/// Favorite folders persistent store (data source for the status bar favorites section).
///
/// Stored in Application Support via atomic JSON rewrites.
@MainActor
final class FavoriteFolderStore: ObservableObject {

    /// Storage order = addition order. Menu display order is sorted by `byRecency`.
    @Published private(set) var entries: [FavoriteFolder] = []

    /// Most recent click timestamps for "Open With" applications (key = normalized app path).
    private(set) var openerLastUsed: [String: Double]

    /// Manually added applications for "Open With" (normalized paths).
    @Published private(set) var openerExtras: [String]
    /// Hidden applications in "Open With" (normalized paths).
    @Published private(set) var openerHidden: Set<String>

    private static let openerKey = "openerLastUsed"
    private static let openerExtrasKey = "openerExtras"
    private static let openerHiddenKey = "openerHidden"

    private let file: URL

    init() {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TabCircle", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("favorite-folders.json")
        openerLastUsed = UserDefaults.standard
            .dictionary(forKey: Self.openerKey) as? [String: Double] ?? [:]
        openerExtras = UserDefaults.standard.stringArray(forKey: Self.openerExtrasKey) ?? []
        openerHidden = Set(UserDefaults.standard.stringArray(forKey: Self.openerHiddenKey) ?? [])
        load()
    }

    /// Record an "Open with this App" interaction for dynamic MRU sorting.
    func touchOpener(appPath: String) {
        openerLastUsed[appPath] = Date().timeIntervalSince1970 * 1000
        UserDefaults.standard.set(openerLastUsed, forKey: Self.openerKey)
    }

    /// Manually add an opener application in settings.
    func addOpenerExtra(appPath: String) {
        let unhidden = openerHidden.filter { $0 == appPath || $0.hasPrefix(appPath + "#") }
        if !unhidden.isEmpty {
            openerHidden.subtract(unhidden)
            UserDefaults.standard.set(Array(openerHidden), forKey: Self.openerHiddenKey)
        }
        guard !openerExtras.contains(appPath) else { return }
        openerExtras.append(appPath)
        UserDefaults.standard.set(openerExtras, forKey: Self.openerExtrasKey)
        log("📁 opener added: \(appPath)")
    }

    func removeOpenerExtra(appPath: String) {
        guard openerExtras.contains(appPath) else { return }
        openerExtras.removeAll { $0 == appPath }
        UserDefaults.standard.set(openerExtras, forKey: Self.openerExtrasKey)
        log("📁 opener extra removed: \(appPath)")
    }

    /// Toggle visibility for discovered opener applications.
    func setOpenerHidden(_ hidden: Bool, appPath: String) {
        if hidden {
            guard openerHidden.insert(appPath).inserted else { return }
        } else {
            guard openerHidden.remove(appPath) != nil else { return }
        }
        UserDefaults.standard.set(Array(openerHidden), forKey: Self.openerHiddenKey)
    }

    enum AddOutcome {
        case added
        /// Already favorited — deduplicated and bumped to front of MRU display.
        case movedToFront
        case invalid
    }

    /// Add a directory to favorites. Repeated additions update `openedAt` to bump to front.
    @discardableResult
    func add(path: String) -> AddOutcome {
        let norm = Self.normalized(path)
        guard !norm.isEmpty else { return .invalid }
        let now = Date().timeIntervalSince1970 * 1000
        if entries.contains(where: { $0.path == norm }) {
            entries = Self.touching(entries, path: norm, openedAt: now)
            persist()
            log("📁 re-favorited folder \(norm) — bumped to front")
            return .movedToFront
        }
        entries = Self.adding(entries, path: norm, addedAt: now)
        persist()
        log("📁 favorited folder \(norm)")
        return .added
    }

    func remove(path: String) {
        guard entries.contains(where: { $0.path == path }) else { return }
        entries.removeAll { $0.path == path }
        persist()
        log("📁 unfavorited folder \(path)")
    }

    /// Touch a folder when opened from menu to float it to the front of MRU display.
    func touch(path: String) {
        let next = Self.touching(entries, path: path,
                                 openedAt: Date().timeIntervalSince1970 * 1000)
        guard next != entries else { return }
        entries = next
        persist()
    }

    // MARK: - Pure Functions (validated in checks/favorite-folder-check.swift)

    /// Path normalization: expands ~, resolves .. and ., removes trailing slashes.
    nonisolated static func normalized(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return "" }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Append a path if not already present.
    nonisolated static func adding(_ entries: [FavoriteFolder], path: String,
                                   addedAt: Double) -> [FavoriteFolder] {
        let norm = normalized(path)
        guard !norm.isEmpty else { return entries }
        guard !entries.contains(where: { $0.path == norm }) else { return entries }
        return entries + [FavoriteFolder(path: norm, addedAt: addedAt)]
    }

    /// Updates `openedAt` for a specified path.
    nonisolated static func touching(_ entries: [FavoriteFolder], path: String,
                                     openedAt: Double) -> [FavoriteFolder] {
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return entries }
        var next = entries
        next[index] = FavoriteFolder(path: entries[index].path,
                                     addedAt: entries[index].addedAt,
                                     openedAt: openedAt)
        return next
    }

    /// Ordering for "Open With": items clicked before sorted descending by recency; unclicked retain original order.
    nonisolated static func openerOrder(_ paths: [String],
                                        lastUsed: [String: Double]) -> [String] {
        let used = paths.filter { lastUsed[$0] != nil }
            .sorted { (lastUsed[$0] ?? 0) > (lastUsed[$1] ?? 0) }
        return used + paths.filter { lastUsed[$0] == nil }
    }

    /// Menu display order: sorted by lastUsedAt (most recently opened or added first).
    nonisolated static func byRecency(_ entries: [FavoriteFolder]) -> [FavoriteFolder] {
        entries.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    /// Disambiguated titles for menu display, appending parent folder names when collisions occur.
    nonisolated static func displayTitles(_ entries: [FavoriteFolder]) -> [String] {
        var counts: [String: Int] = [:]
        for entry in entries { counts[entry.name, default: 0] += 1 }
        return entries.map { entry in
            guard counts[entry.name, default: 0] > 1 else { return entry.name }
            let parent = entry.url.deletingLastPathComponent().lastPathComponent
            return parent.isEmpty || parent == "/" ? entry.name : "\(entry.name) — \(parent)"
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let decoded = try? JSONDecoder().decode([FavoriteFolder].self, from: data) else {
            let salvage = file.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: salvage)
            try? FileManager.default.moveItem(at: file, to: salvage)
            log("⚠️  favorite-folders.json parse failed, backed up to \(salvage.lastPathComponent), starting with empty list")
            return
        }
        entries = decoded
        if !entries.isEmpty {
            log("📁 loaded \(entries.count) favorite folder(s)")
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

/// An application entry for "Open With".
struct OpenerApp: Identifiable, Equatable {
    enum Launch: Equatable {
        case document
        case claudeCode
    }

    let name: String
    let url: URL
    let launch: Launch

    init(name: String, url: URL, launch: Launch = .document) {
        self.name = name
        self.url = url
        self.launch = launch
    }

    var id: String {
        switch launch {
        case .document: return path
        case .claudeCode: return path + "#claude-code"
        }
    }
    var path: String { url.standardizedFileURL.path }
}

/// Discovery and assembly of candidate applications for "Open With".
@MainActor
enum OpenerCatalog {

    /// Known terminal application bundle IDs (terminals do not register public.folder with Launch Services).
    static let terminalBundleIDs = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "org.alacritty",
    ]

    /// Display name stripped of .app suffix.
    static func appDisplayName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// Deep link for Claude Code (encodes RFC 3986 unreserved characters).
    nonisolated static func claudeCodeURL(folder path: String) -> URL? {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: unreserved)
        else { return nil }
        return URL(string: "claude://code/new?folder=\(encoded)")
    }

    /// Full candidate list: Finder -> Installed Terminals -> Launch Services enumeration -> Custom extras.
    static func candidates(extras: [String]) -> [OpenerApp] {
        var seen = Set<URL>()
        var result: [OpenerApp] = []
        let claude = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: claudeBundleID)?.standardizedFileURL

        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized).inserted else { return }
            result.append(OpenerApp(name: appDisplayName(url), url: url))
            if standardized == claude {
                result.append(OpenerApp(name: "Claude Code", url: url, launch: .claudeCode))
            }
        }

        if let finder = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.apple.finder") {
            append(finder)
        }
        for id in terminalBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                append(url)
            }
        }

        let claimed = NSWorkspace.shared
            .urlsForApplications(toOpen: FileManager.default.homeDirectoryForCurrentUser)
            .map { (appDisplayName($0), $0) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        for (_, url) in claimed { append(url) }

        for path in extras where FileManager.default.fileExists(atPath: path) {
            append(URL(fileURLWithPath: path, isDirectory: true))
        }
        return result
    }

    /// Final list for menu presentation with MRU sorting applied.
    static func menuOpeners(store: FavoriteFolderStore) -> [OpenerApp] {
        let visible = candidates(extras: store.openerExtras)
            .filter { !store.openerHidden.contains($0.id) }
        guard !store.openerLastUsed.isEmpty else { return visible }
        let keys = visible.map(\.id)
        let byKey = Dictionary(uniqueKeysWithValues: zip(keys, visible))
        return FavoriteFolderStore.openerOrder(keys, lastUsed: store.openerLastUsed)
            .compactMap { byKey[$0] }
    }
}

/// Retrieves the directory currently focused in the frontmost Finder window.
enum FinderFront {

    enum FetchError: Error {
        case notAuthorized
        case noFolder
    }

    /// Fetches directory via osascript background process.
    static func fetchFolder(completion: @escaping (Result<String, FetchError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e",
                "tell application \"Finder\" to POSIX path of (target of front Finder window as alias)"]
            let out = Pipe(), err = Pipe()
            proc.standardOutput = out
            proc.standardError = err

            let result: Result<String, FetchError>
            do {
                try proc.run()
                proc.waitUntilExit()
                let path = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                                  encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if proc.terminationStatus == 0, !path.isEmpty {
                    result = .success(path)
                } else {
                    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                                        encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    log("⚠️  Finder front-folder fetch failed: \(stderr)")
                    result = .failure(stderr.contains("-1743") ? .notAuthorized : .noFolder)
                }
            } catch {
                log("⚠️  osascript launch failed: \(error)")
                result = .failure(.noFolder)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
