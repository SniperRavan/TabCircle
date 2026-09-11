// SwitcherHotkeys.mode 的判定表验证。
//
// 跑法（在 helper/ 下）：
//   swiftc -parse-as-library Sources/tabflick/SwitchMode.swift \
//          checks/switch-mode-check.swift -o /tmp/switchmodecheck && /tmp/switchmodecheck
//
// 判定表 16 格（切换器键命不命中 × 全局键命不命中 × 前台是不是浏览器 ×
// 在不在排除名单），每一格错了都不报错 —— 表现只是「某个 App 里这个键的
// 归属跟预期反过来」，得等用户撞上。所以期望值一律**手写**，不照着实现
// 再推一遍：同构的推导只会把同一个错误抄两遍。

import CoreGraphics

private let kTab: Int64 = 48   // kVK_Tab
private let kA: Int64 = 0      // kVK_ANSI_A

/// 默认：两者同键（全局键跟随切换器键，configureGlobalHotkey 的 nil 分支）。
private func sameKey(enabled: Bool) -> SwitcherHotkeys {
    SwitcherHotkeys(switchKeyCode: kTab, switchModifiers: .maskControl,
                    globalKeyCode: kTab, globalModifiers: .maskControl,
                    globalEnabled: enabled)
}

/// 各用各的键：切换器 ⌃⇥、全局 ⌥⇥。
private func diffKey(enabled: Bool) -> SwitcherHotkeys {
    SwitcherHotkeys(switchKeyCode: kTab, switchModifiers: .maskControl,
                    globalKeyCode: kTab, globalModifiers: .maskAlternate,
                    globalEnabled: enabled)
}

/// 修饰键互为子集：⌃⇥ 与 ⌃⌥⇥ —— 按 ⌃⌥⇥ 时两个键同时命中。
private func subsetKey(enabled: Bool) -> SwitcherHotkeys {
    SwitcherHotkeys(switchKeyCode: kTab, switchModifiers: .maskControl,
                    globalKeyCode: kTab, globalModifiers: [.maskControl, .maskAlternate],
                    globalEnabled: enabled)
}

private struct Case {
    let name: String
    let keys: SwitcherHotkeys
    let code: Int64
    let flags: CGEventFlags
    let browser: Bool
    let excluded: Bool
    let want: SwitchMode?
}

private let ctrlTab: CGEventFlags = .maskControl
private let ctrlShiftTab: CGEventFlags = [.maskControl, .maskShift]
private let optTab: CGEventFlags = .maskAlternate
private let ctrlOptTab: CGEventFlags = [.maskControl, .maskAlternate]
private let cmdTab: CGEventFlags = .maskCommand

private let cases: [Case] = [
    // ── 同键 + 全局切换器关着：排除名单不该有任何影响 ──────────────
    Case(name: "同键/关/浏览器/未排除", keys: sameKey(enabled: false),
         code: kTab, flags: ctrlTab, browser: true, excluded: false, want: .browser),
    Case(name: "同键/关/浏览器/已排除", keys: sameKey(enabled: false),
         code: kTab, flags: ctrlTab, browser: true, excluded: true, want: .browser),
    Case(name: "同键/关/非浏览器/未排除", keys: sameKey(enabled: false),
         code: kTab, flags: ctrlTab, browser: false, excluded: false, want: nil),
    Case(name: "同键/关/非浏览器/已排除", keys: sameKey(enabled: false),
         code: kTab, flags: ctrlTab, browser: false, excluded: true, want: nil),

    // ── 同键 + 全局切换器开着（默认配置下的主战场）──────────────
    Case(name: "同键/开/浏览器/未排除", keys: sameKey(enabled: true),
         code: kTab, flags: ctrlTab, browser: true, excluded: false, want: .browser),
    // 排除名单只管全局切换器：浏览器内的切换是核心功能，不归它管
    Case(name: "同键/开/浏览器/已排除", keys: sameKey(enabled: true),
         code: kTab, flags: ctrlTab, browser: true, excluded: true, want: .browser),
    Case(name: "同键/开/非浏览器/未排除", keys: sameKey(enabled: true),
         code: kTab, flags: ctrlTab, browser: false, excluded: false, want: .global),
    // 这一格就是排除功能本身：放行给终端 / 编辑器自己的 ⌃⇥
    Case(name: "同键/开/非浏览器/已排除", keys: sameKey(enabled: true),
         code: kTab, flags: ctrlTab, browser: false, excluded: true, want: nil),
    // 反向（叠 ⇧）走的是同一套匹配，排除照样要挡住
    Case(name: "同键/开/非浏览器/未排除/⌃⇧⇥", keys: sameKey(enabled: true),
         code: kTab, flags: ctrlShiftTab, browser: false, excluded: false, want: .global),
    Case(name: "同键/开/非浏览器/已排除/⌃⇧⇥", keys: sameKey(enabled: true),
         code: kTab, flags: ctrlShiftTab, browser: false, excluded: true, want: nil),
    // 不相干的按键在任何组合下都不该被我们认领
    Case(name: "同键/开/浏览器/⌘⇥", keys: sameKey(enabled: true),
         code: kTab, flags: cmdTab, browser: true, excluded: false, want: nil),
    Case(name: "同键/开/非浏览器/⌃A", keys: sameKey(enabled: true),
         code: kA, flags: ctrlTab, browser: false, excluded: false, want: nil),

    // ── 异键：切换器 ⌃⇥、全局 ⌥⇥ ──────────────────────────────
    Case(name: "异键/开/浏览器/未排除/⌥⇥", keys: diffKey(enabled: true),
         code: kTab, flags: optTab, browser: true, excluded: false, want: .global),
    // 浏览器自己进了排除名单：全局键在它前台放行，不再跨浏览器唤出
    Case(name: "异键/开/浏览器/已排除/⌥⇥", keys: diffKey(enabled: true),
         code: kTab, flags: optTab, browser: true, excluded: true, want: nil),
    // 切换器键不受排除影响
    Case(name: "异键/开/浏览器/已排除/⌃⇥", keys: diffKey(enabled: true),
         code: kTab, flags: ctrlTab, browser: true, excluded: true, want: .browser),
    Case(name: "异键/开/非浏览器/未排除/⌃⇥", keys: diffKey(enabled: true),
         code: kTab, flags: ctrlTab, browser: false, excluded: false, want: nil),
    Case(name: "异键/开/非浏览器/未排除/⌥⇥", keys: diffKey(enabled: true),
         code: kTab, flags: optTab, browser: false, excluded: false, want: .global),
    Case(name: "异键/开/非浏览器/已排除/⌥⇥", keys: diffKey(enabled: true),
         code: kTab, flags: optTab, browser: false, excluded: true, want: nil),
    Case(name: "异键/关/非浏览器/未排除/⌥⇥", keys: diffKey(enabled: false),
         code: kTab, flags: optTab, browser: false, excluded: false, want: nil),

    // ── 修饰键互为子集（⌃⇥ 与 ⌃⌥⇥）：双命中一律按同键规则 ────────
    Case(name: "子集/开/非浏览器/未排除/⌃⌥⇥", keys: subsetKey(enabled: true),
         code: kTab, flags: ctrlOptTab, browser: false, excluded: false, want: .global),
    Case(name: "子集/开/浏览器/未排除/⌃⌥⇥", keys: subsetKey(enabled: true),
         code: kTab, flags: ctrlOptTab, browser: true, excluded: false, want: .browser),
    // 双命中里全局那半被排除否决后，剩下的切换器键仍按自己的规则走
    Case(name: "子集/开/非浏览器/已排除/⌃⌥⇥", keys: subsetKey(enabled: true),
         code: kTab, flags: ctrlOptTab, browser: false, excluded: true, want: nil),
    Case(name: "子集/开/浏览器/已排除/⌃⌥⇥", keys: subsetKey(enabled: true),
         code: kTab, flags: ctrlOptTab, browser: true, excluded: true, want: .browser),
]

private func describe(_ mode: SwitchMode?) -> String {
    switch mode {
    case .browser: return "browser"
    case .global:  return "global"
    case nil:      return "放行"
    }
}

@main
struct SwitchModeCheck {
    static func main() {
        var failures = 0
        for c in cases {
            let got = c.keys.mode(code: c.code, flags: c.flags,
                                  frontIsBrowser: c.browser, frontIsExcluded: c.excluded)
            if got != c.want {
                failures += 1
                print("✗ \(c.name)：期望 \(describe(c.want))，实际 \(describe(got))")
            }
        }

        print(failures == 0
              ? "全部通过（\(cases.count) 组）"
              : "\(failures) 项失败（共 \(cases.count) 组）")
        if failures > 0 { fatalError("SwitcherHotkeys 判定表校验未通过") }
    }
}
