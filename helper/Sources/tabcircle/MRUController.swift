import AppKit
import CoreImage
import Foundation

struct TabInfo: Decodable {
    let id: Int
    let windowId: Int
    let title: String
    let url: String
    let favIconUrl: String
    /// Most recent access timestamp (ms epoch, Chrome 121+ tab.lastAccessed).
    /// nil/0 on older extensions or older Chrome versions.
    let lastAccessed: Double?
    /// Whether the tab is pinned. Used by switcher card badges.
    let pinned: Bool?
}

extension TabInfo {
    var relativeLastAccessed: String? { relativeTime(msEpoch: lastAccessed) }
}

/// Favicon image and visual attributes.
struct IconInfo {
    let image: NSImage
    /// Whether the icon itself is predominantly light. Determines background contrast.
    let isLight: Bool
}

/// In-memory cache for favicons, keyed by favIconUrl.
@MainActor
final class IconCache {
    private var images: [String: IconInfo] = [:]
    private var inflight: Set<String> = []

    func image(for url: String) -> IconInfo? { images[url] }

    /// Determines whether the icon is predominantly light or dark.
    /// Favicons often have transparency, so de-premultiply alpha to examine visible pixels.
    private static func isLight(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let ciImage = CIImage(data: tiff) else { return false }

        let parameters: [String: Any] = [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: ciImage.extent),
        ]
        guard let average = CIFilter(name: "CIAreaAverage", parameters: parameters)?.outputImage
        else { return false }

        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            average,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        let alpha = CGFloat(pixel[3]) / 255
        guard alpha > 0.05 else { return false }   // Nearly completely transparent; fallback to dark

        // Weighted perceived luminance after de-premultiplication
        let r = CGFloat(pixel[0]) / 255 / alpha
        let g = CGFloat(pixel[1]) / 255 / alpha
        let b = CGFloat(pixel[2]) / 255 / alpha
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.62
    }

    func prefetch(_ urls: [String], onLoaded: @escaping () -> Void) {
        for url in urls where !url.isEmpty && images[url] == nil && !inflight.contains(url) {
            guard let parsed = URL(string: url) else { continue }
            inflight.insert(url)
            URLSession.shared.dataTask(with: parsed) { data, _, _ in
                let image = data.flatMap { NSImage(data: $0) }
                Task { @MainActor in
                    self.inflight.remove(url)
                    guard let image else { return }   // If download fails, let the view fallback to globe placeholder
                    self.images[url] = IconInfo(image: image,
                                                isLight: Self.isLight(image))
                    onLoaded()
                }
            }.resume()
        }
    }
}

/// MRU switching state machine.
/// Mimics macOS Application Switcher semantics:
///   - Captures a snapshot of current MRU order when cycling starts.
///   - Tab keystrokes move the cursor on the snapshot without mutating real MRU order.
///   - Releasing modifier commits the switch.
@MainActor
final class MRUController {

    private let server: WebSocketServer
    private let settings: AppSettings
    private let overlay: OverlayPanel
    private let icons = IconCache()

    /// Webpage thumbnail cache (memory + disk, indexed by URL).
    private let thumbnails = ThumbnailStore()

    /// URLs whose thumbnails are uncropped, full-viewport captures (extension reports full: true).
    private var fullViewportThumbs: Set<String> = []

    /// Closed tab history archive (shown in status bar submenu).
    private let closedTabs = ClosedTabStore()

    /// Maximum number of recently closed tabs listed in the status bar submenu.
    static let menuClosedTabLimit = 20

    /// Per-connected-client (browser) state.
    struct ClientState {
        /// Real-time MRU order for this browser. Index 0 is the current tab.
        var tabs: [TabInfo] = []
        /// Current window id reported with MRU push; -1 if unknown.
        var currentWindowId = -1
        /// Bundle identifier of the associated browser.
        var browser: String?
        /// Extension version reported during handshake.
        var extVersion: String?
    }

    private var clients: [UUID: ClientState] = [:]
    /// Client that pushed MRU most recently — fallback routing.
    private var lastPushClient: UUID?

    /// Currently active client: foreground browser's connection takes priority.
    private var activeClientID: UUID? {
        if let match = clients.first(where: { $0.value.browser == ChromeWindowLocator.activeBundleID })?.key {
            return match
        }
        if clients.count == 1 { return clients.keys.first }
        if let last = lastPushClient, clients[last] != nil { return last }
        return clients.keys.first
    }

    /// Tab list of active client.
    private var tabs: [TabInfo] {
        activeClientID.flatMap { clients[$0]?.tabs } ?? []
    }

    private var currentWindowId: Int {
        activeClientID.flatMap { clients[$0]?.currentWindowId } ?? -1
    }

    /// Effective browser identifier for a client.
    private func effectiveBrowser(of clientID: UUID) -> String {
        clients[clientID]?.browser ?? ChromeWindowLocator.activeBundleID
    }

    /// Favorite -> active tab binding (favorite.id -> tabId).
    private var favoriteTabBindings: [String: Int] = [:]

    /// Filtered tab list for switcher (filtered by window if scopeToWindow is true).
    private var switcherTabs: [TabInfo] {
        guard settings.scopeToWindow else { return tabs }
        let scoped = tabs.filter { $0.windowId == currentWindowId }
        return scoped.isEmpty ? tabs : scoped
    }

    /// Switcher items for current browser.
    private var switcherItems: [SwitcherItem] {
        guard let id = activeClientID else { return [] }
        return switcherTabs.map { SwitcherItem(tab: $0, browser: nil, clientID: id) }
    }

    /// Global switcher items across all browsers, grouped by browser.
    private var globalItems: [SwitcherItem] {
        var byBrowser: [String: [(tab: TabInfo, clientID: UUID)]] = [:]
        for (id, client) in clients where !client.tabs.isEmpty {
            let browser = effectiveBrowser(of: id)
            byBrowser[browser, default: []].append(contentsOf: client.tabs.map { ($0, id) })
        }
        return byBrowser
            .map { browser, entries -> (browser: String, recency: Double, entries: [(tab: TabInfo, clientID: UUID)]) in
                (browser, entries.compactMap(\.tab.lastAccessed).max() ?? 0, entries)
            }
            .sorted { a, b in
                a.recency != b.recency ? a.recency > b.recency : a.browser < b.browser
            }
            .flatMap { group in
                group.entries.map { SwitcherItem(tab: $0.tab, browser: group.browser, clientID: $0.clientID) }
            }
    }

    /// Total tab count across all connected browsers.
    private var globalTabCount: Int {
        clients.values.reduce(0) { $0 + $1.tabs.count }
    }

    /// Snapshot for the current cycling session.
    private var snapshot: [SwitcherItem] = []
    private var cursor = 0
    private var cycling = false

    /// Whether the current session is global switcher.
    private var cyclingGlobal = false

    /// Whether a tab was closed via close button during this cycling session.
    private var closedTabThisRound = false

    private var connected: Bool { !clients.isEmpty }
    private var pingTimer: Timer?

    /// Watchdog timer to prevent stuck cycling overlay.
    private var cyclingWatchdog: Timer?
    private let cyclingTimeout: TimeInterval = 10

    private func armWatchdog() {
        cyclingWatchdog?.invalidate()
        let timer = Timer(timeInterval: cyclingTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.forceEndCycling() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cyclingWatchdog = timer
    }

    private func disarmWatchdog() {
        cyclingWatchdog?.invalidate()
        cyclingWatchdog = nil
    }

    private func forceEndCycling() {
        guard cycling || eventTapIsCycling else { return }
        log("⚠️  Watchdog: cycling stuck for \(Int(cyclingTimeout))s — force reset")
        endCycling()
        resetEventTapCycling()
    }

    /// Ends cycling session and hides overlay.
    private func endCycling() {
        cycling = false
        cyclingGlobal = false
        cursor = 0
        snapshot = []
        closedTabThisRound = false
        overlay.hide()
    }

    /// Callback when connection status or tab count changes.
    var onStatusChange: ((Bool, Int) -> Void)?

    private func publishStatus() {
        onStatusChange?(connected, tabs.count)
    }

    /// Callback when extension requests opening settings.
    var onExtensionRequestedSettings: (() -> Void)?

    /// Callback when extension version is outdated.
    var onExtensionOutdated: ((String, String) -> Void)?
    private var reportedExtensionMismatch = false

    /// Minimum required extension version for compatibility.
    static let requiredExtensionVersion = "0.9"

    /// Segment-by-segment version comparison.
    private static func isOlder(_ v: String, than required: String) -> Bool {
        let a = v.split(separator: ".").compactMap { Int($0) }
        let b = required.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// Browser status list for settings and warnings.
    struct BrowserStatus: Identifiable, Equatable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let connected: Bool
        let extVersion: String?
        let needsUpdate: Bool
    }

    var browserStatuses: [BrowserStatus] {
        var connectedByBrowser: [String: ClientState] = [:]
        for (id, client) in clients {
            connectedByBrowser[effectiveBrowser(of: id)] = client
        }
        let pinned = Set(settings.favorites.map(\.browser))
        let gone = settings.knownBrowsers.filter {
            connectedByBrowser[$0] == nil && !pinned.contains($0)
                && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) == nil
        }
        if !gone.isEmpty {
            settings.knownBrowsers.removeAll(where: gone.contains)
        }
        let known = Set(BrowserSupport.installedBrowsers())
            .union(settings.knownBrowsers)
            .union(pinned)
            .union(connectedByBrowser.keys)
        return known.sorted().map { bundleID in
            let client = connectedByBrowser[bundleID]
            let needsUpdate: Bool = {
                guard let ext = client?.extVersion else { return false }
                return Self.isOlder(ext, than: Self.requiredExtensionVersion)
            }()
            return BrowserStatus(bundleID: bundleID,
                                 name: BrowserSupport.displayName(bundleID),
                                 connected: client != nil,
                                 extVersion: client?.extVersion,
                                 needsUpdate: needsUpdate)
        }
    }

    /// Records extension version and alerts if below minimum required.
    private func recordExtensionVersion(_ clientID: UUID, _ version: String) {
        clients[clientID]?.extVersion = version
        publishStatus()
        guard Self.isOlder(version, than: Self.requiredExtensionVersion) else { return }
        guard !reportedExtensionMismatch else { return }
        reportedExtensionMismatch = true
        log("⚠️  extension \(version) < required \(Self.requiredExtensionVersion) — prompting update")
        onExtensionOutdated?(version, Self.requiredExtensionVersion)
    }

    /// Broadcasts updated settings to all connected clients.
    func pushSettingsToAll() {
        for id in clients.keys { pushSettings(to: id) }
    }

    private func pushSettings(to id: UUID) {
        let browser = clients[id]?.browser
        if browser == nil {
            log("⏳ settings without favorites → client \(id.uuidString.prefix(8)) (unidentified, will push after identification)")
        }
        server.send(settings.payload(favoritesFor: browser), to: id)
    }

    /// Updates event tap readiness state.
    private func updateReadiness() {
        setEventTapReady(connected && switcherTabs.count > 1)

        let globalReady = settings.globalSwitcher && connected && globalTabCount > 1
        if globalReady != lastGlobalReady {
            lastGlobalReady = globalReady
            log("🌐 global switcher \(globalReady ? "armed" : "idle") "
                + "(enabled: \(settings.globalSwitcher ? "on" : "off"), \(clients.count) browser(s), \(globalTabCount) tab(s))")
        }
        setEventTapGlobalReady(globalReady)
    }

    private var lastGlobalReady = false

    /// Refreshes readiness when settings change.
    func refreshReadiness() {
        updateReadiness()
    }

    init(server: WebSocketServer, settings: AppSettings) {
        self.server = server
        self.settings = settings
        self.overlay = OverlayPanel(settings: settings)
        thumbnails.warmUp()   // Load cached thumbnails from disk
        // Prefetch favicons for closed tabs to avoid placeholders.
        icons.prefetch(closedTabs.entries.prefix(60).map(\.favIconUrl)) { }
        overlay.model.onPick = { [weak self] itemID in
            self?.pick(itemID: itemID)
        }
        overlay.model.onHover = { [weak self] itemID in
            self?.hover(itemID: itemID)
        }
        overlay.model.onClose = { [weak self] itemID in
            self?.closeTab(itemID: itemID)
        }
    }

    /// Mouse hover: Moves cursor and updates visual highlight.
    private func hover(itemID: String) {
        guard cycling,
              let index = snapshot.firstIndex(where: { $0.id == itemID }),
              index != cursor else { return }
        cursor = index
        overlay.model.setCursor(index, source: .mouse)
        armWatchdog()
    }

    /// Mouse click: Selects card and commits switch.
    private func pick(itemID: String) {
        guard cycling,
              let index = snapshot.firstIndex(where: { $0.id == itemID }) else { return }
        cursor = index
        resetEventTapCycling()
        log("🖱 clicked [\(index)] → \(snapshot[index].tab.title.prefix(50))")
        commit()
    }

    /// Close tab button clicked: Closes tab, removes card, continues cycling.
    private func closeTab(itemID: String) {
        guard !cyclingGlobal,
              settings.allowTabClose,
              cycling, snapshot.count > 2,
              let index = snapshot.firstIndex(where: { $0.id == itemID }) else { return }

        let target = snapshot[index]
        log("✕ close [\(index)] → \(target.tab.title.prefix(50)) (tabId \(target.tab.id))")
        server.send(["type": "close", "tabId": target.tab.id], to: target.clientID)
        closedTabThisRound = true

        snapshot.remove(at: index)
        clients[target.clientID]?.tabs.removeAll { $0.id == target.tab.id }
        publishStatus()

        if index < cursor {
            cursor -= 1
        } else if cursor >= snapshot.count {
            cursor = snapshot.count - 1
        }

        overlay.applyRemoval(items: snapshot, cursor: cursor)
        armWatchdog()
    }

    // MARK: - From WebSocket

    func handleMessage(_ data: Data, from clientID: UUID) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else { return }

        switch type {
        case "mru":
            guard clients[clientID] != nil,
                  let raw = root["tabs"],
                  let payload = try? JSONSerialization.data(withJSONObject: raw),
                  let decoded = try? JSONDecoder().decode([TabInfo].self, from: payload) else { return }
            clients[clientID]?.tabs = decoded
            clients[clientID]?.currentWindowId = (root["currentWindowId"] as? NSNumber)?.intValue ?? -1
            lastPushClient = clientID
            syncFavoriteBindings(for: clientID)
            icons.prefetch(decoded.map(\.favIconUrl)) { [weak self] in
                self?.refreshOverlayImages()
            }
            updateReadiness()
            publishStatus()
            if !cycling, clientID == activeClientID {
                log("MRU updated: \(decoded.count) tabs, current: \(decoded.first?.title.prefix(40) ?? "?")")
            }

        case "thumb":
            guard let url = root["url"] as? String, !url.isEmpty,
                  let base64 = root["data"] as? String,
                  let data = Data(base64Encoded: base64) else { return }
            thumbnails.store(data, for: url)
            if root["full"] as? Bool == true { fullViewportThumbs.insert(url) }
            refreshOverlayImages()

        case "tabsClosed":
            guard let raw = root["tabs"] as? [[String: Any]], !raw.isEmpty else { return }
            let browser = effectiveBrowser(of: clientID)
            let now = Date().timeIntervalSince1970 * 1000
            let records = raw.compactMap { entry -> ClosedTab? in
                guard let url = entry["url"] as? String, url.hasPrefix("http"),
                      url.count <= ClosedTab.maxURLLength else { return nil }
                return ClosedTab(
                    url: url,
                    title: entry["title"] as? String ?? "",
                    favIconUrl: entry["favIconUrl"] as? String ?? "",
                    browser: browser,
                    reason: CloseReason(rawValue: entry["reason"] as? String ?? "") ?? .manual,
                    closedAt: min((entry["closedAt"] as? NSNumber)?.doubleValue ?? now, now))
            }
            guard !records.isEmpty else { return }
            closedTabs.record(records)
            icons.prefetch(records.prefix(Self.menuClosedTabLimit).map(\.favIconUrl)) { }
            let summary = Dictionary(grouping: records, by: \.reason)
                .map { "\($0.key.rawValue)×\($0.value.count)" }
                .sorted()
                .joined(separator: " ")
            log("🗑  archived \(records.count) closed tab(s) [\(BrowserSupport.displayName(browser))]: \(summary)")

        case "pinnedTab":
            guard let tabId = (root["tabId"] as? NSNumber)?.intValue,
                  let url = root["url"] as? String, url.hasPrefix("http"),
                  let host = URL(string: url)?.host else { return }
            let browser = effectiveBrowser(of: clientID)
            let mine = settings.favorites.filter { $0.browser == browser }
            if mine.contains(where: { favoriteTabBindings[$0.id] == tabId }) {
                return
            }
            if let orphan = mine.first(where: { fav in
                favoriteTabBindings[fav.id] == nil
                    && (settings.favoriteCurrentUrls[fav.id] ?? fav.url) == url
            }) {
                favoriteTabBindings[orphan.id] = tabId
                return
            }
            let title = root["title"] as? String ?? ""
            log("★ browser pin → favorite: \(title.prefix(50)) (\(host)) [\(browser)]")
            let fav = FavoriteTab(url: url, title: title,
                                  favIconUrl: root["favIconUrl"] as? String,
                                  browser: browser)
            favoriteTabBindings[fav.id] = tabId
            settings.favorites.append(fav)

        case "unpinned":
            let tabId = (root["tabId"] as? NSNumber)?.intValue
            let host = root["host"] as? String
            let reporter = effectiveBrowser(of: clientID)
            let index = settings.favorites.firstIndex { fav in
                guard fav.browser == reporter else { return false }
                if let tabId, favoriteTabBindings[fav.id] == tabId { return true }
                guard let host, !host.isEmpty else { return false }
                return URL(string: settings.favoriteCurrentUrls[fav.id] ?? fav.url)?.host == host
                    || URL(string: fav.url)?.host == host
            }
            if let index {
                log("☆ browser unpin → unfavorite: \(settings.favorites[index].title.prefix(50))")
                settings.favorites.remove(at: index)
            }

        case "unpinsApplied":
            guard let hosts = root["hosts"] as? [String], !hosts.isEmpty else { return }
            let browser = effectiveBrowser(of: clientID)
            settings.pendingUnpins.removeAll { $0.browser == browser && hosts.contains($0.host) }
            log("☆ pending unpins applied [\(browser)]: \(hosts.joined(separator: ", "))")

        case "favoriteBound":
            guard let favId = root["id"] as? String,
                  let tabId = (root["tabId"] as? NSNumber)?.intValue else { return }
            favoriteTabBindings[favId] = tabId

        case "requestSettings":
            pushSettings(to: clientID)
            recordExtensionVersion(clientID, root["extVersion"] as? String ?? "0.1.0")

        case "openSettings":
            onExtensionRequestedSettings?()

        case "log":
            if let message = root["message"] as? String { log("🧩 ext: \(message)") }

        case "pong":
            break

        default:
            break
        }
    }

    func handleClientConnected(_ id: UUID) {
        clients[id] = ClientState()
        log("✅ Extension connected (\(clients.count) client(s))")
        startPinging()
        updateReadiness()
        publishStatus()
        scheduleIdentityFallback(for: id)
    }

    /// Fallback when process identification fails.
    private func scheduleIdentityFallback(for id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      let client = self.clients[id], client.browser == nil else { return }
                guard self.clients.count == 1 else {
                    log("⚠️  client \(id.uuidString.prefix(8)) could not be identified with multiple connections — favorites / auto-restore disabled")
                    return
                }
                let fallback = ChromeWindowLocator.activeBundleID
                log("🔎 client \(id.uuidString.prefix(8)) identification timed out → single client falling back to frontmost browser: \(fallback)")
                self.handleClientIdentified(id, browser: fallback)
            }
        }
    }

    /// Handles completed client browser identification.
    func handleClientIdentified(_ id: UUID, browser: String) {
        guard clients[id] != nil else { return }
        clients[id]?.browser = browser
        BrowserSupport.connected = Set(clients.values.compactMap(\.browser))
        if !settings.knownBrowsers.contains(browser) {
            settings.knownBrowsers.append(browser)
        }
        refreshFrontmostAppState()
        pushSettings(to: id)
        updateReadiness()
        publishStatus()
    }

    func handleClientDisconnected(_ id: UUID) {
        let wasActive = (id == activeClientID)
        clients.removeValue(forKey: id)
        BrowserSupport.connected = Set(clients.values.compactMap(\.browser))
        if clients.isEmpty {
            log("⚠️  Extension disconnected — shortcuts passed to native browser")
            stopPinging()
        } else {
            log("⚠️  Client disconnected (\(clients.count) left)")
        }
        if wasActive || cyclingGlobal {
            endCycling()
            resetEventTapCycling()
        }
        updateReadiness()
        publishStatus()
    }

    /// Frontmost browser changed.
    func activeBrowserChanged() {
        updateReadiness()
        publishStatus()
    }

    // MARK: - From EventTap

    func step(backward: Bool) {
        if !cycling {
            cycling = true
            cyclingGlobal = eventTapCyclingIsGlobal
            snapshot = cyclingGlobal ? globalItems : switcherItems
            cursor = 0
            closedTabThisRound = false
            overlay.beginCycle(isGlobal: cyclingGlobal, items: snapshot)
            overlay.model.items = snapshot
            refreshOverlayImages()
        }

        guard snapshot.count > 1 else {
            log("⌃⇥ only \(snapshot.count) tab(s) — nowhere to go")
            return
        }

        cursor = backward
            ? (cursor - 1 + snapshot.count) % snapshot.count
            : (cursor + 1) % snapshot.count

        overlay.model.setCursor(cursor, source: .keyboard)
        overlay.requestShow()
        armWatchdog()

        log("⌃\(backward ? "⇧" : "")⇥ \(cyclingGlobal ? "(global) " : "")[\(cursor)/\(snapshot.count - 1)] → \(snapshot[cursor].tab.title.prefix(50))")
    }

    /// Directional navigation during cycling.
    func arrow(_ direction: ArrowDirection) {
        guard cycling, snapshot.count > 1 else { return }

        switch overlay.presentation.layout {
        case .globalList:
            switch direction {
            case .up:    step(backward: true)
            case .down:  step(backward: false)
            case .left:  stepBrowser(up: true)
            case .right: stepBrowser(up: false)
            }

        case .globalCards(let columns):
            switch direction {
            case .left:  step(backward: true)
            case .right: step(backward: false)
            case .up:    stepCardRow(up: true, cols: columns)
            case .down:  stepCardRow(up: false, cols: columns)
            }

        case .grid(let columns):
            switch direction {
            case .left:  step(backward: true)
            case .right: step(backward: false)
            case .up:    stepRow(up: true, cols: columns)
            case .down:  stepRow(up: false, cols: columns)
            }

        case .strip:
            switch direction {
            case .left:  step(backward: true)
            case .right: step(backward: false)
            case .up, .down: break
            }
        }
    }

    /// Grid row navigation: clamps at boundaries without wrapping.
    private func stepRow(up: Bool, cols: Int) {
        guard cols > 0 else { return }

        let lastRowStart = (snapshot.count - 1) / cols * cols
        if up {
            guard cursor >= cols else { return }
            moveCursor(to: cursor - cols, arrow: up ? "↑" : "↓")
        } else {
            guard cursor < lastRowStart else { return }
            moveCursor(to: min(cursor + cols, snapshot.count - 1), arrow: "↓")
        }
    }

    /// Global card row navigation: respects separate rows per browser group.
    private func stepCardRow(up: Bool, cols: Int) {
        guard let target = GridGeometry.rowNeighbor(of: cursor,
                                                    groupStarts: groupStarts(),
                                                    total: snapshot.count,
                                                    cols: cols,
                                                    up: up) else { return }
        moveCursor(to: target, arrow: up ? "↑" : "↓")
    }

    /// Global list browser jumping: jumps to first item of previous/next group.
    private func stepBrowser(up: Bool) {
        let starts = groupStarts()
        guard starts.count > 1 else { return }

        let current = starts.lastIndex(where: { $0 <= cursor }) ?? 0
        let target = up ? current - 1 : current + 1
        guard starts.indices.contains(target) else { return }

        let name = snapshot[starts[target]].browser.map { BrowserSupport.displayName($0) } ?? "?"
        moveCursor(to: starts[target], arrow: up ? "←" : "→", note: name)
    }

    /// Start indices of each browser group in the snapshot.
    private func groupStarts() -> [Int] {
        var starts: [Int] = []
        var lastBrowser: String?
        for (index, item) in snapshot.enumerated() where item.browser != lastBrowser {
            starts.append(index)
            lastBrowser = item.browser
        }
        return starts
    }

    /// Moves cursor to index without wrapping.
    private func moveCursor(to index: Int, arrow: String, note: String? = nil) {
        guard snapshot.indices.contains(index), index != cursor else { return }
        cursor = index
        overlay.model.setCursor(cursor, source: .keyboard)
        overlay.requestShow()
        armWatchdog()
        let suffix = note.map { " → \($0)" } ?? " → \(snapshot[cursor].tab.title.prefix(50))"
        log("⌃\(arrow)  [\(cursor)/\(snapshot.count - 1)]\(suffix)")
    }

    func commit() {
        disarmWatchdog()
        guard cycling else { return }
        cycling = false
        overlay.hide()

        let wasGlobal = cyclingGlobal
        defer { cursor = 0; snapshot = []; closedTabThisRound = false; cyclingGlobal = false }

        guard snapshot.indices.contains(cursor),
              wasGlobal || cursor != 0 || closedTabThisRound else {
            log("⌃ released: cursor back at origin, no switch")
            return
        }

        let target = snapshot[cursor]
        log("⌃ released → switching to: \(target.tab.title.prefix(50)) (tabId \(target.tab.id))")
        if let browser = target.browser {
            _ = NSRunningApplication
                .runningApplications(withBundleIdentifier: browser)
                .first?
                .activate(options: [])
        }
        server.send(["type": "switch", "tabId": target.tab.id], to: target.clientID)
    }

    // MARK: - Favorite Tabs

    /// Current active tab (first in MRU).
    var currentTab: TabInfo? { tabs.first }

    /// Active browser bundle ID.
    private var activeBrowser: String {
        activeClientID.map { effectiveBrowser(of: $0) } ?? ChromeWindowLocator.activeBundleID
    }

    /// Active browser display name.
    var activeBrowserDisplayName: String? {
        guard connected else { return nil }
        return BrowserSupport.displayName(activeBrowser)
    }

    /// Whether the current tab is favorited.
    var currentTabFavorited: Bool? {
        guard let tab = tabs.first else { return nil }
        let browser = activeBrowser
        let mine = settings.favorites.filter { $0.browser == browser }
        if mine.contains(where: { favoriteTabBindings[$0.id] == tab.id }) { return true }
        guard let host = URL(string: tab.url)?.host else { return nil }
        return mine.contains { fav in
            URL(string: settings.favoriteCurrentUrls[fav.id] ?? fav.url)?.host == host
                || URL(string: fav.url)?.host == host
        }
    }

    /// Unpins removed favorites in the browser.
    func unpinRemovedFavorites(_ removed: [FavoriteTab]) {
        for fav in removed {
            favoriteTabBindings.removeValue(forKey: fav.id)
            guard let host = URL(string: settings.favoriteCurrentUrls[fav.id] ?? fav.url)?.host
                    ?? URL(string: fav.url)?.host else { continue }
            guard let clientID = clients.first(where: { effectiveBrowser(of: $0.key) == fav.browser })?.key else {
                let pending = PendingUnpin(browser: fav.browser, host: host)
                if !settings.pendingUnpins.contains(pending) {
                    settings.pendingUnpins.append(pending)
                }
                log("☆ unpin deferred (\(fav.browser) disconnected): \(host)")
                continue
            }
            log("☆ unpin \(host) [\(fav.browser)]")
            server.send(["type": "unpin", "hosts": [host]], to: clientID)
        }
    }

    /// Toggle favorite status of current tab.
    func toggleFavoriteCurrentTab() {
        guard let current = tabs.first else { return }
        let browser = activeBrowser
        let mine = settings.favorites.filter { $0.browser == browser }

        if let bound = mine.first(where: { favoriteTabBindings[$0.id] == current.id }),
           let index = settings.favorites.firstIndex(where: { $0.id == bound.id }) {
            log("☆ unfavorite: \(settings.favorites[index].title.prefix(50))")
            settings.favorites.remove(at: index)
            return
        }
        guard let host = URL(string: current.url)?.host else { return }
        if let match = mine.first(where: { URL(string: $0.url)?.host == host }),
           let index = settings.favorites.firstIndex(where: { $0.id == match.id }) {
            log("☆ unfavorite: \(settings.favorites[index].title.prefix(50))")
            settings.favorites.remove(at: index)
        } else {
            log("★ favorite: \(current.title.prefix(50)) (\(host)) [\(browser)]")
            let fav = FavoriteTab(url: current.url, title: current.title,
                                  favIconUrl: current.favIconUrl, browser: browser)
            favoriteTabBindings[fav.id] = current.id
            settings.favorites.append(fav)
        }
    }

    /// Updates favorite bindings when MRU list is received.
    private func syncFavoriteBindings(for clientID: UUID) {
        guard let client = clients[clientID] else { return }
        let browser = effectiveBrowser(of: clientID)
        for (favId, tabId) in favoriteTabBindings {
            guard let fav = settings.favorites.first(where: { $0.id == favId }),
                  fav.browser == browser else { continue }
            guard let tab = client.tabs.first(where: { $0.id == tabId }) else {
                favoriteTabBindings.removeValue(forKey: favId)
                continue
            }
            if tab.url.hasPrefix("http"), settings.favoriteCurrentUrls[favId] != tab.url {
                settings.favoriteCurrentUrls[favId] = tab.url
            }
        }
    }

    // MARK: - Status Bar Submenu

    /// Browser item in status bar menu.
    struct MenuBrowser {
        let bundleID: String
        let name: String
        let entries: [(tab: TabInfo, icon: NSImage?)]
        /// Recently closed tabs, newest first.
        let closed: [(tab: ClosedTab, icon: NSImage?)]
        /// Total closed tab count in archive.
        let closedTotal: Int
    }

    /// Submenu data for all connected browsers.
    var menuBrowsers: [MenuBrowser] {
        let activeID = activeClientID
        let ordered = clients.keys.sorted { a, b in
            if a == activeID { return true }
            if b == activeID { return false }
            return effectiveBrowser(of: a) < effectiveBrowser(of: b)
        }
        return ordered.compactMap { id in
            guard let client = clients[id], !client.tabs.isEmpty else { return nil }
            let bundleID = effectiveBrowser(of: id)
            return MenuBrowser(
                bundleID: bundleID,
                name: BrowserSupport.displayName(bundleID),
                entries: client.tabs.map { ($0, icons.image(for: $0.favIconUrl)?.image) },
                closed: closedTabs.recent(browser: bundleID, limit: Self.menuClosedTabLimit)
                    .map { ($0, icons.image(for: $0.favIconUrl)?.image) },
                closedTotal: closedTabs.count(browser: bundleID))
        }
    }

    /// Reopens a closed tab.
    func reopenClosedTab(id: String, browser bundleID: String) {
        guard let record = closedTabs.entries.first(where: { $0.id == id }) else { return }
        log("↩︎ reopen: \(record.displayTitle.prefix(50)) [\(bundleID)]")

        if let clientID = clients.first(where: { effectiveBrowser(of: $0.key) == bundleID })?.key {
            _ = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .first?
                .activate(options: [])
            server.send(["type": "reopen", "url": record.url], to: clientID)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  let url = URL(string: record.url) {
            NSWorkspace.shared.open([url], withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration())
        }

        closedTabs.remove(id: id)
    }

    /// Clears closed tab history for a browser.
    func clearClosedTabs(browser: String) {
        closedTabs.clear(browser: browser)
    }

    /// Activates browser and switches to selected tab from status bar menu.
    func activateFromMenu(tabId: Int, browser bundleID: String) {
        guard let clientID = clients.first(where: { effectiveBrowser(of: $0.key) == bundleID })?.key,
              let target = clients[clientID]?.tabs.first(where: { $0.id == tabId }) else { return }
        _ = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first?
            .activate(options: [])
        log("📎 menu pick → \(target.title.prefix(50)) [\(bundleID)]")
        server.send(["type": "switch", "tabId": tabId], to: clientID)
    }

    private func refreshOverlayImages() {
        var iconMap: [String: IconInfo] = [:]
        var thumbMap: [String: NSImage] = [:]
        for item in overlay.model.items {
            if let info = icons.image(for: item.tab.favIconUrl) { iconMap[item.id] = info }
            if let thumb = thumbnails.image(for: item.tab.url) { thumbMap[item.id] = thumb }
        }
        overlay.model.icons = iconMap
        overlay.model.thumbs = thumbMap

        // Full-viewport thumbnail for backdrop distortion.
        overlay.model.backdropSource = overlay.model.items.first.flatMap { item in
            fullViewportThumbs.contains(item.tab.url) ? thumbMap[item.id] : nil
        }
    }

    // MARK: - Keepalive
    // MV3 service worker terminates after 30s idle. Periodic pings keep it alive.

    private func startPinging() {
        guard pingTimer == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.server.broadcast(["type": "ping"])
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func stopPinging() {
        pingTimer?.invalidate()
        pingTimer = nil
    }
}
