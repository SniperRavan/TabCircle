# 版本化与发布策略

> 本文档适用于 [`lifedever/PermissionFlow`](https://github.com/lifedever/PermissionFlow) fork。上游（`jaywcjlove/PermissionFlow`）的发版策略可能不同，请参考其自身 README。

本 fork 遵循 [Semantic Versioning](https://semver.org/)，仅通过 git tag 发版。

## 推荐的依赖声明

```swift
dependencies: [
    .package(url: "https://github.com/lifedever/PermissionFlow.git", from: "0.1.0")
]
```

**不要**用 commit revision 或分支来 pin 依赖：

- `revision:` 把你的构建绑在一个没有 changelog 线索的 SHA 上。
- `branch:` 会让构建随上游 branch 前进而"静默漂移"，破坏可复现的 CI。

只有在确实需要上游尚未发布的 commit（例如要提前拿一个紧急修复）时，才临时 `revision:` pin，并在上游打出新 tag 后立刻换回 `from:`。

## 版本号规则

- **Patch** (`0.1.0 → 0.1.1`)：只修 bug，不改公开 API。
- **Minor** (`0.1.0 → 0.2.0`)：新增 API。**处于 0.x 阶段时，minor 升级可能包含 breaking change** —— 升级前务必看 release notes。
- **Major** (`0.x → 1.0.0`)：1.0 之后才进入严格 SemVer，breaking change 仅在 major bump 中出现。

## 消费方升级流程

```bash
swift package update
```

然后把 `Package.swift` 和 `Package.resolved` **一起 commit**，保证 CI、本地、正式发版三端解析到同一个 commit。

## 发版流程（维护者）

1. 在 feature 分支开发 → merge / fast-forward 到 `main`。
2. 在 `main` 上打 SemVer tag（不加 `v` 前缀）：`git tag 0.2.0`。
3. `git push origin main && git push origin 0.2.0`。

第一个版本化发布是 `0.1.0`。
