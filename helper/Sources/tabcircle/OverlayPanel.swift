import AppKit
import ApplicationServices
import SwiftUI

// MARK: - View Model

enum CursorSource {
    case keyboard
    case mouse
}

/// Item in switcher.
///
/// Identity is `id` instead of `tab.id`: the global switcher combines tabs from multiple browsers
/// into one list, whereas tabId is unique only within a single browser. Using tabId as identity
/// could result in clicking one browser's card and switching to another browser's tab with the same id.
/// `clientID` ensures every item knows which connection commands should be sent to.
struct SwitcherItem: Identifiable {
    let id: String
    let tab: TabInfo
    /// Associated browser bundle id. nil = current browser switcher (single browser, no group header).
    let browser: String?
    /// Target connection client ID for commands.
    let clientID: UUID

    init(tab: TabInfo, browser: String?, clientID: UUID) {
        // Prepend clientID to prevent collision across multiple browser profiles.
        self.id = "\(clientID.uuidString)#\(tab.id)"
        self.tab = tab
        self.browser = browser
        self.clientID = clientID
    }
}

/// Overlay presentation configuration.
struct SwitcherPresentation: Equatable {
    enum Layout: Equatable {
        /// Current browser: horizontal strip.
        case strip
        /// Current browser: grid with columns parameter.
        case grid(columns: Int)
        /// Global: Raycast-style vertical list with browser group headers.
        case globalList
        /// Global: thumbnail card grid per browser.
        case globalCards(columns: Int)
    }

    let layout: Layout

    /// Compact card size flag.
    var compact = false

    /// Show group headers. Only when more than one browser is present.
    var grouped = false

    /// Description for logging.
    func describe(count: Int) -> String {
        let card = compact ? "compact" : "standard"
        switch layout {
        case .strip:                    return "Strip \(count) tabs"
        case .grid(let c):              return "Grid \(c) cols · \(card) · \(count) tabs"
        case .globalList:               return "Global List\(grouped ? " · grouped" : "") · \(count) items"
        case .globalCards(let c):       return "Global Cards \(c) cols · \(card)\(grouped ? " · grouped" : "") · \(count) tabs"
        }
    }
}

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var items: [SwitcherItem] = []
    @Published private(set) var cursor: Int = 0
    @Published var icons: [String: IconInfo] = [:]
    @Published var thumbs: [String: NSImage] = [:]

    /// Background webpage image cropped to overlay position for refraction.
    ///
    /// Refraction requires `.glassEffect()` to refract content drawn behind it in the same SwiftUI tree.
    /// nil = unavailable (e.g. global switcher over other apps, missing thumbnail, chrome:// pages).
    @Published var backdrop: NSImage?

    /// Uncropped full-viewport source image.
    var backdropSource: NSImage?

    /// Trigger source of current cursor move.
    private(set) var cursorSource: CursorSource = .keyboard

    /// Item pick callback.
    var onPick: ((String) -> Void)?

    /// Item hover callback.
    var onHover: ((String) -> Void)?

    /// Item close callback.
    var onClose: ((String) -> Void)?

    /// Whether tab closing is allowed.
    @Published var allowClose = false

    /// Updates cursor and source in correct order.
    func setCursor(_ index: Int, source: CursorSource) {
        cursorSource = source
        cursor = index
    }
}

// MARK: - Dimensions

/// Card metrics (standard and compact).
private struct CardMetrics {
    let thumbWidth: CGFloat
    let thumbHeight: CGFloat
    let titleRowHeight: CGFloat
    let padding: CGFloat
    let titleFont: CGFloat
    let faviconSize: CGFloat
    let thumbCorner: CGFloat
    let cardCorner: CGFloat
    /// Badge diameter for close and pin icons.
    let badgeSize: CGFloat

    var width: CGFloat { thumbWidth + padding * 2 }
    var height: CGFloat { thumbHeight + titleRowHeight + padding * 2 + 4 }

    static let standard = CardMetrics(thumbWidth: 140, thumbHeight: 88, titleRowHeight: 20,
                                      padding: 7, titleFont: 11, faviconSize: 13,
                                      thumbCorner: 7, cardCorner: 10, badgeSize: 20)

    /// Compact card metrics.
    static let compact = CardMetrics(thumbWidth: 120, thumbHeight: 75, titleRowHeight: 18,
                                     padding: 6, titleFont: 10.5, faviconSize: 12,
                                     thumbCorner: 6, cardCorner: 9, badgeSize: 18)
}

private let kCardSpacing: CGFloat = 8
private let kOuterPadding: CGFloat = 12
private let kPanelCornerRadius: CGFloat = 14

/// Whether the background uses Liquid Glass (macOS 26+).
private let kGlassBackdrop: Bool = false

// Global list layout metrics.
private let kListWidth: CGFloat = 520
/// Target panel width for global cards layout.
private let kGlobalCardsTargetWidth: CGFloat = 1440
/// Max height for global list layout.
private let kGlobalListMaxHeight: CGFloat = 520
/// Two-row layout: title + domain.
private let kRowHeight: CGFloat = 42
private let kRowSpacing: CGFloat = 1
private let kGroupHeaderHeight: CGFloat = 22
/// Space between group header and rule.
private let kGroupRuleSpace: CGFloat = 7
private let kGroupSpacing: CGFloat = 14

/// Row horizontal inset.
private let kRowInset: CGFloat = 10
/// Gap between icon and text.
private let kRowIconGap: CGFloat = 9
private let kRowIconSize: CGFloat = 17

// MARK: - SwiftUI Content

/// Fallback hand-drawn glass modifier for standard macOS versions.
private struct HandDrawnGlass: ViewModifier {
    let scheme: ColorScheme
    /// Refracting content modifier.
    let refracting: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if kGlassBackdrop {
            content
        } else {
            content
                .background {
                    scheme == .dark ? Color(red: 64/255, green: 64/255, blue: 72/255).opacity(0.35)
                                    : Color(red: 253/255, green: 252/255, blue: 251/255).opacity(0.88)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: kPanelCornerRadius, style: .continuous)
                        .strokeBorder(scheme == .dark ? Color.white.opacity(0.16)
                                                      : Color.black.opacity(0.08),
                                      lineWidth: 1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: kPanelCornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.12 : 0.42),
                                                    .clear],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1)
                }
        }
    }
}

private struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    let presentation: SwitcherPresentation
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if let backdrop = model.backdrop {
                Image(nsImage: backdrop)
                    .resizable()
                    .interpolation(.high)
                    .allowsHitTesting(false)
            }
            switcherBody
        }
    }

    private var switcherBody: some View {
        ScrollViewReader { proxy in
            content
            // Scroll only when cursor moved by keyboard.
            .onChange(of: model.cursor) { _, newValue in
                guard model.cursorSource == .keyboard,
                      model.items.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(model.items[newValue].id, anchor: .center)
                }
            }
        }
        .modifier(HandDrawnGlass(scheme: scheme, refracting: model.backdrop != nil))
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.layout {
        case .strip:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: kCardSpacing) { cards(model.items) }
                    .padding(kOuterPadding)
            }

        case .grid(let columns):
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: gridItems(columns), spacing: kCardSpacing) {
                    cards(model.items)
                }
                .padding(kOuterPadding)
            }

        case .globalCards(let columns):
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: kGroupSpacing) {
                    ForEach(groups, id: \.browser) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            if presentation.grouped {
                                groupHeader(group, inset: metrics.padding)
                            }
                            LazyVGrid(columns: gridItems(columns),
                                      alignment: .leading,
                                      spacing: kCardSpacing) {
                                cards(group.items)
                            }
                        }
                    }
                }
                .padding(kOuterPadding)
            }

        case .globalList:
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: kGroupSpacing) {
                    ForEach(groups, id: \.browser) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            if presentation.grouped {
                                groupHeader(group, inset: kRowInset)
                            }
                            VStack(alignment: .leading, spacing: kRowSpacing) {
                                ForEach(group.items) { item in
                                    TabRow(item: item,
                                           icon: model.icons[item.id],
                                           selected: item.id == selectedID,
                                           onHover: { model.onHover?(item.id) },
                                           onPick: { model.onPick?(item.id) })
                                        .id(item.id)
                                }
                            }
                        }
                    }
                }
                .padding(kOuterPadding)
            }
        }
    }

    private var metrics: CardMetrics {
        presentation.compact ? .compact : .standard
    }

    private var closable: Bool {
        switch presentation.layout {
        case .globalList, .globalCards: return false
        case .strip, .grid:             return model.allowClose && model.items.count > 2
        }
    }

    private var selectedID: String? {
        model.items.indices.contains(model.cursor) ? model.items[model.cursor].id : nil
    }

    private func gridItems(_ columns: Int) -> [GridItem] {
        Array(repeating: GridItem(.fixed(metrics.width), spacing: kCardSpacing), count: max(1, columns))
    }

    private var groups: [(browser: String, items: [SwitcherItem])] {
        var result: [(browser: String, items: [SwitcherItem])] = []
        for item in model.items {
            let key = item.browser ?? ""
            if result.last?.browser == key {
                result[result.count - 1].items.append(item)
            } else {
                result.append((key, [item]))
            }
        }
        return result
    }

    private func groupHeader(_ group: (browser: String, items: [SwitcherItem]),
                             inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: kRowIconGap) {
                Group {
                    if let icon = BrowserSupport.icon(group.browser) {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary)
                    }
                }
                .frame(width: kRowIconSize - 3, height: kRowIconSize - 3)
                .frame(width: kRowIconSize, height: kRowIconSize)
                .opacity(0.85)

                Text(BrowserSupport.displayName(group.browser))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.primary.opacity(0.45))

                Spacer(minLength: 8)

                countBadge(group.items.count)
            }
            .frame(height: kGroupHeaderHeight)
            .padding(.horizontal, inset)

            Rectangle()
                .fill(scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08))
                .frame(height: 1)
                .padding(.bottom, kGroupRuleSpace - 1)
        }
    }

    private func countBadge(_ count: Int) -> some View {
        Text(L10n.t("\(count) tab\(count == 1 ? "" : "s")"))
            .font(.system(size: 9.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Color.primary.opacity(0.45))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(scheme == .dark ? Color.white.opacity(0.11)
                                               : Color.black.opacity(0.06))
            }
    }

    private func cards(_ items: [SwitcherItem]) -> some View {
        ForEach(items) { item in
            TabCard(tab: item.tab,
                    metrics: metrics,
                    icon: model.icons[item.id],
                    thumb: model.thumbs[item.id],
                    selected: item.id == selectedID,
                    closable: closable,
                    onHover: { model.onHover?(item.id) },
                    onPick: { model.onPick?(item.id) },
                    onClose: { model.onClose?(item.id) })
                .id(item.id)
        }
    }
}

private struct TabCard: View {
    let tab: TabInfo
    let metrics: CardMetrics
    let icon: IconInfo?
    let thumb: NSImage?
    let selected: Bool
    let closable: Bool
    let onHover: () -> Void
    let onPick: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var scheme

    @State private var hovering = false
    @State private var closeHovering = false
    @State private var lastMouseScreenPoint: CGPoint?

    var body: some View {
        VStack(spacing: metrics.padding - 1) {
            thumbnail
                .frame(width: metrics.thumbWidth, height: metrics.thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: metrics.thumbCorner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.thumbCorner, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor
                                               : (scheme == .dark ? Color.white.opacity(0.14)
                                                                  : Color.black.opacity(0.12)),
                                      lineWidth: selected ? 2 : 1)
                }
                .shadow(color: selected && scheme == .dark ? Color.accentColor.opacity(0.45) : .clear,
                        radius: 7)
                .shadow(color: .black.opacity(scheme == .dark ? 0.40 : (selected ? 0.22 : 0.18)),
                        radius: scheme == .dark ? 5 : (selected ? 4 : 2),
                        y: scheme == .dark ? 2 : (selected ? 2 : 1))
                .shadow(color: .black.opacity(scheme == .dark ? 0.30 : (selected ? 0.16 : 0.12)),
                        radius: scheme == .dark ? 20 : (selected ? 20 : 16),
                        y: scheme == .dark ? 8 : (selected ? 8 : 6))
                .overlay(alignment: .topTrailing) {
                    if closable && hovering {
                        closeButton
                    }
                }
                .overlay(alignment: .topLeading) {
                    if tab.pinned == true {
                        pinBadge
                    }
                }

            HStack(spacing: metrics.padding - 2) {
                Group {
                    if let icon {
                        Image(nsImage: icon.image).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "globe").resizable().foregroundStyle(.secondary)
                    }
                }
                .scaledToFit()
                .frame(width: metrics.faviconSize, height: metrics.faviconSize)
                .padding(icon == nil ? 0 : metrics.faviconSize * 0.115)
                .background {
                    if let icon { faviconBacking(isLight: icon.isLight, radius: metrics.thumbCorner - 4) }
                }

                Text(tab.title.isEmpty ? tab.url : tab.title)
                    .font(.system(size: metrics.titleFont, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.72))

                Spacer(minLength: 0)
            }
            .frame(width: metrics.thumbWidth, height: metrics.titleRowHeight)
        }
        .padding(metrics.padding)
        .frame(width: metrics.width, height: metrics.height)
        .background {
            RoundedRectangle(cornerRadius: metrics.cardCorner, style: .continuous)
                .fill(selected ? (scheme == .dark ? Color.white.opacity(0.28)
                                                  : Color.black.opacity(0.15))
                               : Color.clear)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPick)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                let point = NSEvent.mouseLocation
                if let last = lastMouseScreenPoint,
                   abs(point.x - last.x) > 1 || abs(point.y - last.y) > 1 {
                    onHover()
                }
                lastMouseScreenPoint = point
            case .ended:
                lastMouseScreenPoint = nil
            @unknown default:
                break
            }
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.1)) { hovering = inside }
        }
    }

    private var pinBadge: some View {
        Image(systemName: "star.fill")
            .font(.system(size: metrics.badgeSize * 0.44, weight: .bold))
            .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.20))
            .frame(width: metrics.badgeSize - 2, height: metrics.badgeSize - 2)
            .background {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(Color.black.opacity(0.35))
                }
            }
            .overlay(Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
            .shadow(color: .black.opacity(0.30), radius: 2.5, y: 1)
            .padding(5)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: metrics.badgeSize * 0.45, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: metrics.badgeSize, height: metrics.badgeSize)
                .background {
                    ZStack {
                        Circle().fill(.ultraThinMaterial)
                        Circle().fill(closeHovering ? Color.red.opacity(0.85)
                                                    : Color.black.opacity(0.38))
                    }
                }
                .overlay(Circle().strokeBorder(Color.white.opacity(closeHovering ? 0.55 : 0.30),
                                               lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .scaleEffect(closeHovering ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: closeHovering)
        .onHover { inside in
            closeHovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if closeHovering {
                NSCursor.pop()
                closeHovering = false
            }
        }
        .padding(5)
        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .topTrailing)))
    }

    @ViewBuilder
    private func faviconBacking(isLight: Bool, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(isLight ? Color(white: 0.16) : Color(white: 0.99))
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(scheme == .dark ? Color.white.opacity(0.14)
                                             : Color(red: 250/255, green: 249/255, blue: 247/255))

            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let icon {
                Image(nsImage: icon.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: metrics.thumbHeight * 0.36, height: metrics.thumbHeight * 0.36)
                    .padding(metrics.thumbHeight * 0.125)
                    .background {
                        faviconBacking(isLight: icon.isLight, radius: metrics.thumbHeight * 0.125)
                            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.14),
                                    radius: 5, y: 2)
                    }
            } else {
                Image(systemName: "globe")
                    .font(.system(size: metrics.thumbHeight * 0.3))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct FaviconChip: View {
    let icon: IconInfo?
    var size: CGFloat = 13
    var radius: CGFloat = 3
    var plate: Bool = true

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon.image).resizable().interpolation(.high)
            } else {
                Image(systemName: "globe").resizable().foregroundStyle(.secondary)
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .padding(icon == nil || !plate ? 0 : size * 0.115)
        .background {
            if let icon, plate {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(icon.isLight ? Color(white: 0.16) : Color(white: 0.99))
            }
        }
    }
}

private struct TabRow: View {
    let item: SwitcherItem
    let icon: IconInfo?
    let selected: Bool
    let onHover: () -> Void
    let onPick: () -> Void

    @Environment(\.colorScheme) private var scheme

    @State private var lastMouseScreenPoint: CGPoint?

    private var host: String {
        guard var host = URL(string: item.tab.url)?.host else { return "" }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host.count > 28 ? "…" + host.suffix(26) : host
    }

    var body: some View {
        HStack(spacing: kRowIconGap) {
            FaviconChip(icon: icon, size: kRowIconSize, radius: 4, plate: false)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.tab.title.isEmpty ? item.tab.url : item.tab.title)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.82))

                    if item.tab.pinned == true {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.20))
                    }
                }

                if !host.isEmpty {
                    Text(host)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let ago = item.tab.relativeLastAccessed {
                Text(ago)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.primary.opacity(0.30))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }

        }
        .padding(.horizontal, kRowInset)
        .frame(height: kRowHeight)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? (scheme == .dark ? Color.white.opacity(0.20)
                                                  : Color.black.opacity(0.10))
                               : Color.clear)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPick)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                let point = NSEvent.mouseLocation
                if let last = lastMouseScreenPoint,
                   abs(point.x - last.x) > 1 || abs(point.y - last.y) > 1 {
                    onHover()
                }
                lastMouseScreenPoint = point
            case .ended:
                lastMouseScreenPoint = nil
            @unknown default:
                break
            }
        }
    }
}

// MARK: - Hosting Panel

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayPanel {

    let model = SwitcherModel()

    private let settings: AppSettings

    /// Whether current cycle is global switcher.
    var isGlobal = false

    /// Currently displayed presentation.
    private(set) var presentation = SwitcherPresentation(layout: .strip)

    private var panel: NSPanel?
    private var hostingView: NSHostingView<SwitcherView>?
    private var hideWorkItem: DispatchWorkItem?
    private var shownAt: Date?

    /// Maximum panel dimensions calculated in presentNow.
    private var panelMaxSize = NSSize.zero

    /// Layout anchor and visible screen frame.
    private var panelAnchor = NSRect.zero
    private var panelVisibleFrame = NSRect.zero

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Minimum overlay visible duration.
    private let minVisibleDuration: TimeInterval = 0.18

    /// Fade-in duration.
    private let fadeInDuration: TimeInterval = 0.07

    // MARK: - Show / Hide

    func beginCycle(isGlobal: Bool, items: [SwitcherItem]) {
        self.isGlobal = isGlobal
        guard let panel, !items.isEmpty else { return }
        let (size, layout) = contentLayout(items: items,
                                           maxWidth: panelMaxSize.width,
                                           maxHeight: panelMaxSize.height)
        if layout != presentation || size != panel.frame.size { closeNow() }
    }

    func requestShow() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard panel == nil else { return }
        presentNow()
    }

    func hide() {
        guard panel != nil else { return }

        let elapsed = shownAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let remaining = minVisibleDuration - elapsed
        guard remaining > 0 else {
            closeNow()
            return
        }

        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.hideWorkItem = nil
            self?.closeNow()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: item)
    }

    private func closeNow() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        shownAt = nil
    }

    func applyRemoval(items: [SwitcherItem], cursor: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            model.items = items
            model.setCursor(cursor, source: .mouse)
        }

        guard let panel, !items.isEmpty else { return }

        let (size, layout) = contentLayout(items: items,
                                           maxWidth: panelMaxSize.width,
                                           maxHeight: panelMaxSize.height)
        if layout != presentation {
            presentation = layout
            hostingView?.rootView = SwitcherView(model: model, presentation: layout)
        }
        guard size != panel.frame.size else { return }

        let frame: NSRect
        if size.height == panel.frame.height {
            frame = clampedToVisible(NSRect(origin: panel.frame.origin, size: size))
        } else {
            frame = centeredFrame(size: size)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func presentNow() {
        guard !model.items.isEmpty else { return }
        model.allowClose = settings.allowTabClose

        let defaultScreen = NSScreen.main ?? NSScreen.screens[0]
        let anchor = isGlobal ? defaultScreen.visibleFrame
                              : (ChromeWindowLocator.frontmostWindowFrame() ?? defaultScreen.visibleFrame)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? defaultScreen

        let maxPanelWidth = min(anchor.width, screen.visibleFrame.width) * 0.94
        let maxPanelHeight = min(anchor.height, screen.visibleFrame.height) * 0.94
        panelMaxSize = NSSize(width: maxPanelWidth, height: maxPanelHeight)
        panelAnchor = anchor
        panelVisibleFrame = screen.visibleFrame

        let (contentSize, layout) = contentLayout(items: model.items,
                                                  maxWidth: maxPanelWidth,
                                                  maxHeight: maxPanelHeight)
        presentation = layout
        let width = contentSize.width
        let height = contentSize.height

        let panelFrame = centeredFrame(size: NSSize(width: width, height: height))
        model.backdrop = isGlobal ? nil : model.backdropSource
            .flatMap { Self.cropBackdrop($0, panel: panelFrame, window: anchor) }

        let hosting = NSHostingView(rootView: SwitcherView(model: model, presentation: layout))

        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        let panelSize = NSSize(width: width, height: height)
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        hosting.layer?.cornerRadius = kPanelCornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        panel.contentView = model.backdrop == nil
            ? Self.makeBackdrop(size: panelSize, content: hosting)
            : hosting

        panel.setContentSize(NSSize(width: width, height: height))
        panel.setFrameOrigin(centeredFrame(size: panel.frame.size).origin)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if !kGlassBackdrop { WindowShadow.applyStandardWindowShadow(to: panel) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeInDuration
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        self.hostingView = hosting
        self.shownAt = Date()

        let glassDesc = !kGlassBackdrop ? "material" : (model.backdrop != nil ? "refraction" : "glass")
        log("Overlay \(layout.describe(count: model.items.count)) \(Int(width))×\(Int(height)) max \(Int(maxPanelWidth))×\(Int(maxPanelHeight)) backdrop \(glassDesc)")
    }

    private func centeredFrame(size: NSSize) -> NSRect {
        clampedToVisible(NSRect(x: panelAnchor.midX - size.width / 2,
                                y: panelAnchor.midY - size.height / 2,
                                width: size.width, height: size.height))
    }

    private func clampedToVisible(_ frame: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = min(max(frame.origin.x, panelVisibleFrame.minX + 8),
                             panelVisibleFrame.maxX - frame.width - 8)
        frame.origin.y = min(max(frame.origin.y, panelVisibleFrame.minY + 8),
                             panelVisibleFrame.maxY - frame.height - 8)
        return frame
    }

    private func contentLayout(items: [SwitcherItem],
                               maxWidth: CGFloat,
                               maxHeight: CGFloat) -> (size: NSSize, presentation: SwitcherPresentation) {
        let count = items.count
        guard !isGlobal else {
            return globalLayout(items: items, maxWidth: maxWidth, screenMaxHeight: maxHeight)
        }

        switch settings.switcherLayout {
        case .strip:
            let card = CardMetrics.standard
            let n = CGFloat(count)
            let naturalWidth = n * card.width + max(0, n - 1) * kCardSpacing + kOuterPadding * 2
            return (NSSize(width: min(naturalWidth, maxWidth),
                           height: card.height + kOuterPadding * 2),
                    SwitcherPresentation(layout: .strip))

        case .grid:
            let (fit, compact) = fittedGrid(count: count, maxWidth: maxWidth, maxHeight: maxHeight)
            return (fit.size, SwitcherPresentation(layout: .grid(columns: fit.columns), compact: compact))
        }
    }

    private struct GridFit {
        let columns: Int
        let rows: Int
        let fits: Bool
        let size: NSSize
    }

    private func gridFit(count: Int, card: CardMetrics,
                         maxWidth: CGFloat, maxHeight: CGFloat) -> GridFit {
        let maxCols = max(1, Int((maxWidth - kOuterPadding * 2 + kCardSpacing)
                                 / (card.width + kCardSpacing)))
        let maxRows = max(1, Int((maxHeight - kOuterPadding * 2 + kCardSpacing)
                                 / (card.height + kCardSpacing)))
        let neededRows = (max(1, count) + maxCols - 1) / maxCols
        let fits = neededRows <= maxRows
        let cols = fits ? (max(1, count) + neededRows - 1) / neededRows : maxCols
        let rows = min(neededRows, maxRows)
        return GridFit(
            columns: cols,
            rows: rows,
            fits: fits,
            size: NSSize(width: CGFloat(cols) * card.width + CGFloat(cols - 1) * kCardSpacing + kOuterPadding * 2,
                         height: CGFloat(rows) * card.height + CGFloat(rows - 1) * kCardSpacing + kOuterPadding * 2))
    }

    private func fittedGrid(count: Int, maxWidth: CGFloat, maxHeight: CGFloat)
        -> (fit: GridFit, compact: Bool) {
        let standard = gridFit(count: count, card: .standard, maxWidth: maxWidth, maxHeight: maxHeight)
        guard !standard.fits else { return (standard, false) }
        return (gridFit(count: count, card: .compact, maxWidth: maxWidth, maxHeight: maxHeight), true)
    }

    private func globalLayout(items: [SwitcherItem],
                              maxWidth: CGFloat,
                              screenMaxHeight: CGFloat) -> (size: NSSize, presentation: SwitcherPresentation) {
        var groupSizes: [Int] = []
        var lastBrowser: String?
        for item in items {
            if item.browser == lastBrowser, !groupSizes.isEmpty {
                groupSizes[groupSizes.count - 1] += 1
            } else {
                groupSizes.append(1)
                lastBrowser = item.browser
            }
        }
        let groupCount = max(1, groupSizes.count)
        let gaps = CGFloat(groupCount - 1) * kGroupSpacing
        let grouped = groupCount > 1
        let headerHeight = grouped ? kGroupHeaderHeight + kGroupRuleSpace : 0

        switch settings.globalSwitcherStyle {
        case .list:
            let maxHeight = min(screenMaxHeight, kGlobalListMaxHeight)
            let rowsHeight = groupSizes.reduce(CGFloat.zero) { total, n in
                total + headerHeight + CGFloat(n) * kRowHeight + CGFloat(n - 1) * kRowSpacing
            }
            let height = min(rowsHeight + gaps + kOuterPadding * 2, maxHeight)
            return (NSSize(width: min(kListWidth, maxWidth), height: height),
                    SwitcherPresentation(layout: .globalList, grouped: grouped))

        case .cards:
            let targetWidth = min(maxWidth, kGlobalCardsTargetWidth)

            guard grouped else {
                let (fit, compact) = fittedGrid(count: items.count,
                                                maxWidth: targetWidth,
                                                maxHeight: screenMaxHeight)
                return (fit.size, SwitcherPresentation(layout: .globalCards(columns: fit.columns),
                                                       compact: compact))
            }

            func fit(_ card: CardMetrics) -> (cols: Int, size: NSSize, fits: Bool) {
                let maxCols = max(1, Int((targetWidth - kOuterPadding * 2 + kCardSpacing)
                                         / (card.width + kCardSpacing)))
                let cols = max(1, min(maxCols, groupSizes.max() ?? 1))
                let sectionsHeight = groupSizes.reduce(CGFloat.zero) { total, n in
                    let rows = CGFloat((n + cols - 1) / cols)
                    return total + headerHeight + rows * card.height + (rows - 1) * kCardSpacing
                }
                let natural = sectionsHeight + gaps + kOuterPadding * 2
                let width = CGFloat(cols) * card.width + CGFloat(cols - 1) * kCardSpacing + kOuterPadding * 2
                return (cols,
                        NSSize(width: min(width, maxWidth), height: min(natural, screenMaxHeight)),
                        natural <= screenMaxHeight)
            }

            let standard = fit(.standard)
            let chosen = standard.fits ? standard : fit(.compact)
            return (chosen.size,
                    SwitcherPresentation(layout: .globalCards(columns: chosen.cols),
                                         compact: !standard.fits,
                                         grouped: true))
        }
    }

    private static func cropBackdrop(_ thumb: NSImage, panel: NSRect, window: NSRect) -> NSImage? {
        let ts = thumb.size
        guard ts.width > 1, ts.height > 1, window.width > 1, window.height > 1 else { return nil }

        let viewportHeight = window.width * ts.height / ts.width
        guard viewportHeight > 1, viewportHeight <= window.height else { return nil }
        let viewport = NSRect(x: window.minX, y: window.minY,
                              width: window.width, height: viewportHeight)

        let u = (panel.minX - viewport.minX) / viewport.width
        let v = (panel.minY - viewport.minY) / viewport.height
        let w = panel.width / viewport.width
        let h = panel.height / viewport.height
        guard u >= 0, v >= 0, w > 0, h > 0, u + w <= 1, v + h <= 1 else { return nil }

        let src = NSRect(x: u * ts.width, y: v * ts.height,
                         width: w * ts.width, height: h * ts.height)
        let out = NSImage(size: panel.size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        thumb.draw(in: NSRect(origin: .zero, size: panel.size),
                   from: src, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    private static func makeBackdrop(size: NSSize, content: NSView) -> NSView {
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: kPanelCornerRadius)
        effect.addSubview(content)
        return effect
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Browser Identification

@MainActor
enum BrowserSupport {
    static var connected: Set<String> = []

    static let builtin: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev",
        "com.microsoft.edgemac",        // Edge
        "com.brave.Browser",            // Brave
        "company.thebrowser.Browser",   // Arc
        "com.vivaldi.Vivaldi",          // Vivaldi
        "com.operasoftware.Opera",      // Opera
        "net.imput.helium",             // Helium
    ]

    static var all: Set<String> {
        builtin.union(UserDefaults.standard.stringArray(forKey: "extraBrowsers") ?? [])
    }

    static func isSupported(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return connected.contains(bundleID) || all.contains(bundleID)
    }

    static func displayName(_ bundleID: String) -> String {
        if let hit = nameCache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        nameCache[bundleID] = name
        return name
    }

    static func icon(_ bundleID: String) -> NSImage? {
        if let hit = iconCache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = image
        return image
    }

    private static var nameCache: [String: String] = [:]
    private static var iconCache: [String: NSImage] = [:]

    private static var installedCache: (at: Date, ids: [String])?

    static func installedBrowsers() -> [String] {
        if let cache = installedCache, Date().timeIntervalSince(cache.at) < 60 {
            return cache.ids
        }
        var result: [String] = []
        if let probe = URL(string: "https://example.com") {
            for appURL in NSWorkspace.shared.urlsForApplications(toOpen: probe) {
                guard let id = Bundle(url: appURL)?.bundleIdentifier,
                      !result.contains(id) else { continue }
                if all.contains(id) || connected.contains(id) || looksChromium(appURL) {
                    result.append(id)
                }
            }
        }
        installedCache = (Date(), result)
        return result
    }

    private static func looksChromium(_ appURL: URL) -> Bool {
        let frameworks = appURL.appendingPathComponent("Contents/Frameworks")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else {
            return false
        }
        return items.contains { $0.hasSuffix(" Framework.framework") }
    }
}

// MARK: - Browser Window Positioning

@MainActor
enum ChromeWindowLocator {

    static var activeBundleID = "com.google.Chrome"

    static func frontmostWindowFrame() -> NSRect? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: activeBundleID)
        guard let pid = running.first?.processIdentifier else { return nil }

        guard let bounds = axFocusedWindowBounds(pid: pid) ?? cgFrontmostWindowBounds(pid: pid) else {
            return nil
        }

        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        return NSRect(x: bounds.minX,
                      y: primaryHeight - bounds.maxY,
                      width: bounds.width,
                      height: bounds.height)
    }

    private static func axFocusedWindowBounds(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)

        guard let window = axElement(app, kAXFocusedWindowAttribute)
                        ?? axElement(app, kAXMainWindowAttribute),
              let origin = axPoint(window, kAXPositionAttribute),
              let size = axSize(window, kAXSizeAttribute),
              size.width > 1, size.height > 1
        else { return nil }

        return CGRect(origin: origin, size: size)
    }

    private static func cgFrontmostWindowBounds(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        var candidates: [CGRect] = []
        for entry in list {
            guard let owner = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner == pid,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 200, bounds.height > 200
            else { continue }
            candidates.append(bounds)
        }

        return candidates.first { candidate in
            !candidates.contains { $0 != candidate && $0.contains(candidate) }
        }
    }

    // MARK: - AX Helpers

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = axValue(element, attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = axValue(element, attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }
}
