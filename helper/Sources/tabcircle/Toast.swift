import AppKit

/// Slide-in toast notification at the bottom of the screen.
///
/// Provides visual feedback for actions such as copying paths or favoriting folders.
/// Panels never take key status and ignore mouse events to ensure non-intrusive presentation.
@MainActor
enum Toast {

    /// Visual feedback type: success, informational, or failure.
    enum Kind {
        case success, info, failure

        var symbol: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .info:    return "info.circle.fill"
            case .failure: return "exclamationmark.triangle.fill"
            }
        }

        var tint: NSColor {
            switch self {
            case .success: return .systemGreen
            case .info:    return .systemBlue
            case .failure: return .systemOrange
            }
        }
    }

    private static var panel: NSPanel?
    private static var hideTimer: Timer?

    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let detailFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private static let iconPointSize: CGFloat = 15
    private static let leadInset: CGFloat = 16
    private static let trailInset: CGFloat = 18
    private static let iconGap: CGFloat = 6
    private static let vInset: CGFloat = 11
    private static let lineGap: CGFloat = 3
    /// Maximum text column width before truncation occurs.
    static let maxTextWidth: CGFloat = 360
    private static let boxRadius: CGFloat = 16

    private static let bottomInset: CGFloat = 64
    private static let slideDistance: CGFloat = 22

    static func show(_ text: String, detail: String? = nil, kind: Kind = .success) {
        dismissNow()   // Dismiss existing toast immediately on rapid triggers

        let content = makeContent(title: text, detail: detail, kind: kind)
        let size = content.frame.size
        let radius = (detail ?? "").isEmpty ? size.height / 2 : boxRadius

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: radius)

        let skin = SkinView(frame: NSRect(origin: .zero, size: size))
        skin.radius = radius
        effect.addSubview(skin)
        effect.addSubview(content)

        guard let screen = screenUnderMouse() else { return }
        let finalOrigin = NSPoint(x: (screen.visibleFrame.midX - size.width / 2).rounded(),
                                  y: screen.visibleFrame.minY + bottomInset)

        let p = NSPanel(contentRect: NSRect(x: finalOrigin.x,
                                            y: finalOrigin.y - slideDistance,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.contentView = effect
        p.alphaValue = 0
        panel = p
        p.orderFrontRegardless()
        WindowShadow.applyCompactShadow(to: p)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.9, 0.2, 1)
            p.animator().alphaValue = 1
            p.animator().setFrame(NSRect(origin: finalOrigin, size: p.frame.size), display: true)
        }

        let timer = Timer(timeInterval: visibleDuration(text, detail), repeats: false) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { dismiss() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    /// Display duration scales with text length.
    private static func visibleDuration(_ title: String, _ detail: String?) -> TimeInterval {
        let chars = title.count + (detail?.count ?? 0)
        return min(5.0, max(2.0, 1.4 + Double(chars) * 0.045))
    }

    // MARK: - Content Construction

    /// Builds the layout content view.
    static func makeContent(title: String, detail: String?, kind: Kind) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: iconPointSize, weight: .semibold))
        icon.contentTintColor = kind.tint
        icon.imageScaling = .scaleNone
        let iconSize = icon.image?.size ?? NSSize(width: iconPointSize, height: iconPointSize)

        let titleLabel = makeLabel(title, font: titleFont, color: .labelColor, lines: 1)
        let titleSize = fit(titleLabel)

        var detailLabel: NSTextField?
        var detailSize = NSSize.zero
        if let detail, !detail.isEmpty {
            let l = makeLabel(detail, font: detailFont, color: .secondaryLabelColor, lines: 2)
            detailSize = fit(l)
            detailLabel = l
        }

        let textWidth = max(titleSize.width, detailSize.width)
        let textHeight = detailLabel == nil
            ? titleSize.height
            : titleSize.height + lineGap + detailSize.height
        let width = (leadInset + iconSize.width + iconGap + textWidth + trailInset).rounded(.up)
        let height = (max(textHeight, iconSize.height) + vInset * 2).rounded(.up)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let textX = leadInset + iconSize.width + iconGap
        let textTop = height - (height - textHeight) / 2

        titleLabel.frame = NSRect(x: textX, y: textTop - titleSize.height,
                                  width: titleSize.width, height: titleSize.height)
        content.addSubview(titleLabel)

        if let detailLabel {
            detailLabel.frame = NSRect(x: textX,
                                       y: titleLabel.frame.minY - lineGap - detailSize.height,
                                       width: detailSize.width, height: detailSize.height)
            content.addSubview(detailLabel)
        }

        let iconCenterY = detailLabel == nil ? height / 2 : titleLabel.frame.midY
        icon.frame = NSRect(x: leadInset, y: (iconCenterY - iconSize.height / 2).rounded(),
                            width: iconSize.width, height: iconSize.height)
        content.addSubview(icon)
        return content
    }

    private static func makeLabel(_ text: String, font: NSFont,
                                  color: NSColor, lines: Int) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.alignment = .left
        label.maximumNumberOfLines = lines
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.wraps = lines > 1
        label.cell?.usesSingleLineMode = lines == 1
        return label
    }

    @discardableResult
    private static func fit(_ label: NSTextField) -> NSSize {
        guard let cell = label.cell else { return .zero }
        let bounds = NSRect(x: 0, y: 0, width: maxTextWidth, height: 10_000)
        var size = cell.cellSize(forBounds: bounds)
        size.width = min(size.width.rounded(.up), maxTextWidth)
        size.height = size.height.rounded(.up)
        label.frame = NSRect(origin: .zero, size: size)
        return size
    }

    // MARK: - Dismissal

    private static func dismiss() {
        guard let p = panel else { return }
        hideTimer?.invalidate()
        hideTimer = nil
        panel = nil
        let target = NSRect(x: p.frame.origin.x, y: p.frame.origin.y - slideDistance,
                            width: p.frame.width, height: p.frame.height)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
            p.animator().setFrame(target, display: true)
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    private static func dismissNow() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
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

    private final class SkinView: NSView {
        var radius: CGFloat = 0

        override func draw(_ dirtyRect: NSRect) {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let fill = dark ? NSColor.black.withAlphaComponent(0.26)
                            : NSColor.white.withAlphaComponent(0.88)
            let stroke = dark ? NSColor.white.withAlphaComponent(0.16)
                              : NSColor.black.withAlphaComponent(0.10)
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()
            fill.setFill()
            bounds.fill()

            let line = 1 / (window?.backingScaleFactor ?? 2)
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: line / 2, dy: line / 2),
                                    xRadius: radius, yRadius: radius)
            path.lineWidth = line
            stroke.setStroke()
            path.stroke()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override var allowsVibrancy: Bool { false }
    }
}
