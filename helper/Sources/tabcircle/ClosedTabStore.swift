import Foundation

/// Reason why a tab was closed. Reported by the extension alongside closure records.
enum CloseReason: String, Codable {
    /// Lifetime expired, automatically cleaned up by extension
    case lifetime
    /// Closed via ✕ on switcher card
    case switcher
    /// Closed as part of undoing a pinned tab after unfavoriting
    case unpin
    /// Closed when the entire browser window closed
    case window
    /// Closed manually by user (⌘W / ✕ button / middle click)
    case manual

    /// Unrecognized values fall back to manual.
    ///
    /// Preserves entire archive decoding so future versions do not invalidate historical records.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CloseReason(rawValue: raw) ?? .manual
    }

    /// Short label displayed in menu badge.
    var label: String {
        switch self {
        case .lifetime: return "auto"
        case .switcher: return "switcher"
        case .unpin:    return "unpinned"
        case .window:   return "window"
        case .manual:   return "manual"
        }
    }
}

/// Archive record for a closed tab.
struct ClosedTab: Identifiable, Codable, Equatable {
    let id: String
    let url: String
    let title: String
    let favIconUrl: String
    /// Bundle ID of the owning browser. Grouped by browser like favorites.
    let browser: String
    let reason: CloseReason
    /// Closed timestamp in ms epoch (extension `Date.now()`). Aligned with `TabInfo.lastAccessed`.
    let closedAt: Double

    /// Maximum title length retained. Title is web-controlled and capped to prevent archive bloat.
    static let maxTitleLength = 300

    /// URLs exceeding this length are rejected to avoid corrupted or bloated storage.
    static let maxURLLength = 8192

    init(url: String, title: String, favIconUrl: String,
         browser: String, reason: CloseReason, closedAt: Double) {
        self.id = UUID().uuidString
        self.url = url
        self.title = title.count > Self.maxTitleLength
            ? String(title.prefix(Self.maxTitleLength)) : title
        self.favIconUrl = favIconUrl.count > Self.maxURLLength ? "" : favIconUrl
        self.browser = browser
        self.reason = reason
        self.closedAt = closedAt
    }

    /// Relative timestamp representation (e.g. "23m ago").
    var relativeClosedAt: String? { relativeTime(msEpoch: closedAt) }

    /// Title for menu display, falling back to URL if title is empty.
    var displayTitle: String { title.isEmpty ? url : title }
}

/// Persistent store for closed tabs history.
///
/// Stored in **Application Support** rather than Caches since history data should not be arbitrarily purged.
/// The store is atomic JSON rewrites, ensuring integrity without append-log compaction complexity.
@MainActor
final class ClosedTabStore {

    /// Entries sorted with most recently closed first.
    private(set) var entries: [ClosedTab] = []

    private let file: URL

    /// Maximum entries retained.
    private let maxEntries = 1000
    /// Maximum age: entries older than 30 days are discarded.
    private let maxAge: TimeInterval = 30 * 86_400

    init() {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TabCircle", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("closed-tabs.json")
        load()
    }

    // MARK: - Queries

    /// Returns most recently closed tabs for a specific browser.
    func recent(browser: String, limit: Int) -> [ClosedTab] {
        Array(entries.lazy.filter { $0.browser == browser }.prefix(limit))
    }

    /// Total count of closed tab records for a browser.
    func count(browser: String) -> Int {
        entries.reduce(0) { $1.browser == browser ? $0 + 1 : $0 }
    }

    // MARK: - Mutations

    func record(_ incoming: [ClosedTab]) {
        guard !incoming.isEmpty else { return }
        entries = Self.merging(existing: entries, incoming: incoming,
                                now: Date().timeIntervalSince1970 * 1000,
                                maxAge: maxAge, maxEntries: maxEntries)
        persist()
    }

    /// Merge rules: descending sort -> deduplicate by (browser + URL) keeping newest -> prune expired -> cap limit.
    ///
    /// Extracted as a pure static function without filesystem dependencies for isolated testing.
    nonisolated static func merging(existing: [ClosedTab], incoming: [ClosedTab],
                                    now: Double, maxAge: TimeInterval,
                                    maxEntries: Int) -> [ClosedTab] {
        var seen = Set<String>()
        var merged: [ClosedTab] = []
        merged.reserveCapacity(min(existing.count + incoming.count, maxEntries))

        let cutoff = now - maxAge * 1000
        for tab in (existing + incoming).sorted(by: { $0.closedAt > $1.closedAt }) {
            guard tab.closedAt >= cutoff else { break }
            guard seen.insert("\(tab.browser)\n\(tab.url)").inserted else { continue }
            merged.append(tab)
            if merged.count >= maxEntries { break }
        }
        return merged
    }

    /// Remove a tab from archive once reopened.
    func remove(id: String) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        persist()
    }

    /// Clear all closed tab history for a specific browser.
    func clear(browser: String) {
        guard entries.contains(where: { $0.browser == browser }) else { return }
        entries.removeAll { $0.browser == browser }
        persist()
        log("🗑  cleared closed-tab history [\(browser)]")
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let decoded = try? JSONDecoder().decode([ClosedTab].self, from: data) else {
            let salvage = file.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: salvage)
            try? FileManager.default.moveItem(at: file, to: salvage)
            log("⚠️  closed-tabs.json failed to parse, backed up to \(salvage.lastPathComponent), starting with empty store")
            return
        }
        entries = decoded.sorted { $0.closedAt > $1.closedAt }
        if !entries.isEmpty {
            log("🗂  loaded \(entries.count) closed-tab record(s)")
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
