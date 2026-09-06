import AppKit

/// 屏幕底部滑出的轻提示（toast）。
///
/// 拷贝路径、收藏、取消收藏这类菜单动作做完菜单就收起了，没有任何回响 ——
/// toast 是唯一的「做成了」信号。
///
/// 面板绝不拿 key（红线同切换器浮层），也不收鼠标事件 —— 纯展示，出现两三秒
/// 自己退场。内容用 AppKit 直排，不碰 NSHostingView 的 fittingSize
/// （macOS 15/26 上不可信，见 CLAUDE.md）。
///
/// **文字宽度只认 NSTextField 自己的 `cellSize`**：`NSString.size(withAttributes:)`
/// 比 cell 真正需要的窄 8pt（cell 左右各 4pt 内边距，实测），照它裁 frame 会让
/// 「已拷贝路径」渲染成「已…路径」—— 差的那点正好够 byTruncatingMiddle 砍掉
/// 两个字，而且**不报错**。量什么就用什么画，中间不换算。
@MainActor
enum Toast {

    /// 图标和色调只表达「成没成」，不表达做了什么 —— 三档够用，再细分只会
    /// 逼用户去认图标而不是读字。
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
    /// 图标到文字。SF Symbol 自己的画布左右还带一圈留白，视觉间距比这个数大
    /// 两三 pt —— 按纸面数值调会显得图标飘在外面（用户看实物提的）。
    private static let iconGap: CGFloat = 6
    private static let vInset: CGFloat = 11
    /// 标题和副标题之间。要比副标题自己的行距明显大一点，否则副标题换行后
    /// 三行等距，读起来像一整段而不是「一条标题 + 一段说明」。
    private static let lineGap: CGFloat = 3
    /// 文本列的上限。超了才截断 —— 路径/错误信息走 detail，middle 截断保头尾。
    /// 不是 private：校验脚本要拿它区分「该截断」和「算错了才截断」。
    static let maxTextWidth: CGFloat = 360
    /// 两行时的圆角。单行是胶囊（半高），两行再用半高就成了怪异的椭圆。
    private static let boxRadius: CGFloat = 16

    /// 距屏幕可见区底边的高度。
    private static let bottomInset: CGFloat = 64
    private static let slideDistance: CGFloat = 22

    static func show(_ text: String, detail: String? = nil, kind: Kind = .success) {
        dismissNow()   // 连续动作时新 toast 顶掉旧的，不排队

        let content = makeContent(title: text, detail: detail, kind: kind)
        let size = content.frame.size
        let radius = (detail ?? "").isEmpty ? size.height / 2 : boxRadius

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        // 圆角必须走 maskImage —— layer.cornerRadius 裁不住 vibrancy 材质，
        // 窗口阴影也只认 maskImage 的形状（同切换器浮层那条）。
        effect.maskImage = roundedMask(radius: radius)

        let skin = SkinView(frame: NSRect(origin: .zero, size: size))
        skin.radius = radius
        effect.addSubview(skin)
        effect.addSubview(content)

        // toast 跟着用户在哪块屏操作走（菜单刚点完，鼠标就在那块屏上）
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
        p.ignoresMouseEvents = true   // 纯展示，点击穿透
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.contentView = effect
        p.alphaValue = 0
        panel = p
        p.orderFrontRegardless()
        // 系统只给 borderless 面板最薄那档阴影，小胶囊会显得贴在墙上。
        // 私有 SPI 查不到就什么都不做，退回系统默认（见 WindowShadow）。
        WindowShadow.applyCompactShadow(to: p)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            // 起步快、收尾软，比 easeOut 更像「弹上来停住」
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.9, 0.2, 1)
            p.animator().alphaValue = 1
            p.animator().setFrame(NSRect(origin: finalOrigin, size: p.frame.size), display: true)
        }

        // 必须挂 .common —— 「添加文件夹…」收藏成功后会立刻把状态栏菜单再弹出来，
        // 菜单跟踪跑的是 eventTracking mode，default mode 的定时器在那期间**一次都
        // 不会触发**：toast 就一直挂在屏幕上，直到用户把菜单关掉。
        let timer = Timer(timeInterval: visibleDuration(text, detail), repeats: false) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { dismiss() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    /// 停留时长跟着要读的字数走 —— 带路径/错误信息的两行 toast 用 2 秒读不完。
    private static func visibleDuration(_ title: String, _ detail: String?) -> TimeInterval {
        let chars = title.count + (detail?.count ?? 0)
        return min(5.0, max(2.0, 1.4 + Double(chars) * 0.045))
    }

    // MARK: 内容

    /// 排好版的内容视图（frame 即所需尺寸）。
    ///
    /// 抽成独立函数是为了能脱离 app 验证：文字被截断这类问题不报错也不崩，
    /// 只有把尺寸真的算出来断言一遍才发现得了（`checks/toast-layout-check.swift`）。
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

        // 单行时图标居中于整块；两行时跟标题那一行对齐 —— 居中于整块会让它
        // 悬在两行之间，看着像谁都不属于。
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
        // 路径和错误信息的信息量在两头（盘符/文件名、错误类型/对象），
        // 掐中间比掐尾巴留下的线索多。
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.wraps = lines > 1
        label.cell?.usesSingleLineMode = lines == 1
        return label
    }

    /// 量 label 需要多大。**唯一的测量口径**（见类型注释那条）。
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

    // MARK: 退场

    /// 滑回底部并淡出。
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

    /// 圆角 maskImage（九宫格拉伸），同时决定材质形状和窗口阴影形状。
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

    /// 材质之上的叠色和那道 hairline。
    ///
    /// 两者都必须按深浅色分开给，方向还相反 —— 浅色要提亮压边，深色要压深提边，
    /// 语义色表达不了（同切换器浮层那条）。
    ///
    /// **浅色叠得很厚（近白）是明知的取舍**：半透明面板的最终亮度由背后内容
    /// 主导，而 toast 跟着状态栏菜单走，可能浮在任何 App 上。薄了往深色终端上
    /// 一贴就是一块中灰，近黑的文字压在中灰上糊成一团（屏上实测过）。判据是
    /// 「浮层可能出现在哪些背景上」：贴浏览器窗口可以薄，浮在任何 App 上必须厚。
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

        /// 要的是自己这几个颜色，不是被材质吸过去的那层。
        override var allowsVibrancy: Bool { false }
    }
}
