import CoreGraphics

/// 这一下按键该唤出哪个切换器。
enum SwitchMode: Equatable {
    /// 当前浏览器的标签（原有行为）。
    case browser
    /// 所有已连接浏览器的标签，按浏览器分组。
    case global
}

/// 两个切换器快捷键的当前配置。
///
/// 决策单独抽成**纯函数**（零依赖，只 import CoreGraphics）是因为判定表有
/// 16 格：两个键各命不命中 × 前台是不是浏览器 × 在不在排除名单。而每一格
/// 错了都**不报错** —— 表现只是「某个 App 里这个键的归属跟预期反过来」，
/// 要等用户自己撞上才发现。校验见 checks/switch-mode-check.swift。
struct SwitcherHotkeys: Equatable {
    var switchKeyCode: Int64
    var switchModifiers: CGEventFlags
    var globalKeyCode: Int64
    var globalModifiers: CGEventFlags
    /// 全局切换器是否开启（设置项，默认关）。关掉时全局键一概不参与匹配。
    var globalEnabled: Bool

    /// 把「按了哪个键 + 前台是谁」解析成切换器模式，nil = 与我们无关，放行。
    ///
    /// 三条规则：
    ///   - **不同键**：各归各的。全局键在浏览器前台也生效（想跨浏览器找标签时
    ///     不必先切出浏览器）；切换器键只在浏览器前台生效。
    ///   - **同一个键**（默认，两者都是 ⌃⇥）：浏览器在前台 → 当前浏览器切换器
    ///     优先；前台不是浏览器 → 全局切换器。
    ///   - **排除名单只否决全局切换器**：浏览器内的切换是核心功能，不归这份
    ///     名单管 —— 它要解决的是「终端/编辑器自己的 ⌃⇥ 被抢走」。
    ///
    /// 注意修饰键用 `contains` 而不是相等：⇧ 要能叠上去表示反向，所以 ⌃⇥ 和
    /// ⌃⇧⇥ 都算命中同一个键。这也意味着两个键的修饰键互为子集时会双命中
    /// （⌃⇥ 与 ⌃⌥⇥），此时按同键规则走 —— 让「浏览器优先」成为唯一的兜底
    /// 答案，比按定义顺序碰运气强。
    func mode(code: Int64,
              flags: CGEventFlags,
              frontIsBrowser: Bool,
              frontIsExcluded: Bool) -> SwitchMode? {
        let hitsSwitcher = code == switchKeyCode && flags.contains(switchModifiers)
        let hitsGlobal = globalEnabled && !frontIsExcluded
                         && code == globalKeyCode && flags.contains(globalModifiers)

        if hitsSwitcher && hitsGlobal { return frontIsBrowser ? .browser : .global }
        if hitsGlobal { return .global }
        // 切换器键在非浏览器前台不属于我们 —— 放行给终端/编辑器自己的 ⌃⇥
        if hitsSwitcher { return frontIsBrowser ? .browser : nil }
        return nil
    }
}
