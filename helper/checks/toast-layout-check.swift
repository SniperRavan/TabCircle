// Toast 排版的验证。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/Toast.swift \
//          Sources/tabflick/WindowShadow.swift \
//          checks/toast-layout-check.swift -o /tmp/toastcheck && /tmp/toastcheck
//
// 为什么要有这个：文字被截断**不报错也不崩**，只是少几个字。上一版把 label 的
// frame 按 `NSString.size(withAttributes:)` 裁，比 NSTextField 的 cell 真正需要
// 的窄 8pt（左右各 4pt 内边距），于是「已拷贝路径」上屏成了「已…路径」—— 差的
// 那点正好够 byTruncatingMiddle 砍掉两个字。这类问题只能靠把尺寸算出来断言。
//
// 判据是「label 拿到的宽度够不够它自己说的那么宽」，而不是跟某个魔数比：
// 文本真超过 maxTextWidth 时截断是设计意图，那种情况单独放行。

import AppKit

@MainActor
func checkLayout() {
    var cases = 0
    var failures = 0

    func fail(_ message: String) {
        failures += 1
        print("✗ \(message)")
    }

    /// 一条 toast 的完整体检。
    func inspect(_ title: String, detail: String?, kind: Toast.Kind, label name: String) {
        cases += 1
        let content = Toast.makeContent(title: title, detail: detail, kind: kind)
        let bounds = content.bounds

        guard bounds.width > 0, bounds.height > 0 else {
            return fail("\(name)：尺寸为零 \(bounds.size)")
        }

        var fields: [NSTextField] = []
        for sub in content.subviews {
            // 子视图不能超出内容区 —— 越界的部分会被面板的 maskImage 直接切掉
            if !bounds.insetBy(dx: -0.5, dy: -0.5).contains(sub.frame) {
                fail("\(name)：子视图越界 \(sub.frame) 不在 \(bounds) 内")
            }
            if let field = sub as? NSTextField { fields.append(field) }
            if sub is NSImageView, sub.frame.width < 8 {
                fail("\(name)：图标没画出来（\(sub.frame.size)）")
            }
        }

        let wantFields = (detail ?? "").isEmpty ? 1 : 2
        if fields.count != wantFields {
            fail("\(name)：期望 \(wantFields) 个文本，实际 \(fields.count)")
        }

        for field in fields {
            guard let cell = field.cell else { continue }
            let text = field.stringValue
            // 在**它拿到的宽度**下重新排版，看还需不需要更高/更宽
            let needed = cell.cellSize(forBounds:
                NSRect(x: 0, y: 0, width: field.frame.width, height: 10_000))

            if needed.height > field.frame.height + 0.5 {
                fail("\(name)：「\(text)」高度不够，需要 \(needed.height) 只给了 \(field.frame.height)")
            }
            // 单行 label：cellSize 就是它完整摊开需要的宽度。装得下上限却没给够 =
            // 算错了；本来就超过上限那是设计意图（截断保头尾）。
            if field.maximumNumberOfLines == 1 {
                let full = cell.cellSize.width
                if full <= Toast.maxTextWidth, full > field.frame.width + 0.5 {
                    fail("\(name)：「\(text)」会被截断 —— 需要 \(full)，只给了 \(field.frame.width)")
                }
            }
            if field.frame.width > Toast.maxTextWidth + 0.5 {
                fail("\(name)：「\(text)」宽度 \(field.frame.width) 超过上限 \(Toast.maxTextWidth)")
            }
        }

        // 两行的排版关系：副标题在标题正下方、左对齐、不重叠
        if fields.count == 2 {
            let (title, detail) = (fields[0], fields[1])
            if detail.frame.maxY > title.frame.minY + 0.5 {
                fail("\(name)：标题和副标题重叠（\(title.frame) / \(detail.frame)）")
            }
            if abs(detail.frame.minX - title.frame.minX) > 0.5 {
                fail("\(name)：两行没左对齐（\(title.frame.minX) / \(detail.frame.minX)）")
            }
        }

        // 图标和文字不能压到一起
        if let icon = content.subviews.compactMap({ $0 as? NSImageView }).first,
           let first = fields.first, icon.frame.maxX > first.frame.minX + 0.5 {
            fail("\(name)：图标压到文字上（\(icon.frame) / \(first.frame)）")
        }
    }

    // 用例取自真正会上屏的那几条文案（含中英两版），不是自编的等长假数据 ——
    // 「已拷贝路径」正是踩坑的那条，中文全角字符也只有真文案里才有。
    let longPath = "/Users/someone/Documents/Dev/myspace/TabFlick/helper/Sources/tabflick"
    inspect("已拷贝路径", detail: nil, kind: .success, label: "拷贝路径·无副标题")
    inspect("已拷贝路径", detail: "~/Documents/Dev", kind: .success, label: "拷贝路径·短副标题")
    inspect("已拷贝路径", detail: longPath, kind: .success, label: "拷贝路径·长路径")
    inspect("Path copied", detail: longPath, kind: .success, label: "英文·长路径")
    inspect("已收藏「TabFlick」", detail: longPath, kind: .success, label: "收藏")
    inspect("「TabFlick」已在收藏里，移到最前", detail: longPath, kind: .info, label: "已在收藏里")
    inspect("已取消收藏「TabFlick」", detail: longPath, kind: .success, label: "取消收藏")
    inspect("已在 Visual Studio Code 打开「my-project」", detail: longPath,
            kind: .success, label: "打开文件夹")
    inspect("打开失败",
            detail: "The application “Visual Studio Code” could not be launched because "
                  + "it is not installed on this Mac.",
            kind: .failure, label: "打开失败·长错误")

    // 极端输入不能崩、不能算出负尺寸
    inspect("", detail: nil, kind: .success, label: "空标题")
    inspect(String(repeating: "字", count: 400), detail: String(repeating: "x", count: 2000),
            kind: .failure, label: "超长文本")
    inspect("换\n行", detail: "带\t制表符", kind: .info, label: "控制字符")
    inspect("🎉 表情", detail: "/tmp/🗂️/файл", kind: .success, label: "表情与非拉丁字符")

    print(failures == 0
          ? "全部通过（\(cases) 条）"
          : "\(failures) 项失败（共 \(cases) 条）")
    if failures > 0 { fatalError("Toast 排版校验未通过") }
}

@main
enum ToastLayoutCheck {
    static func main() {
        // 失败走 fatalError → abort()，**不 flush stdio**；管道模式是全缓冲，
        // 不关掉缓冲的话失败详情会全丢，只剩一个退出码（踩过）。
        setvbuf(stdout, nil, _IONBF, 0)
        // NSTextField 的 cell 要 AppKit 起来了才量得准
        _ = NSApplication.shared
        MainActor.assumeIsolated { checkLayout() }
    }
}
