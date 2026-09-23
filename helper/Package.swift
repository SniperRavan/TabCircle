// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tabcircle",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 授权引导浮层：把 app 图标拖进「辅助功能」列表即可授权。
        // 按 SemVer tag 固定，不用 branch/revision。
        .package(url: "https://github.com/sniperravan/PermissionFlow.git", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "tabcircle",
            dependencies: [
                .product(name: "PermissionFlow", package: "PermissionFlow"),
            ],
            path: "Sources/tabcircle",
            // 语言模式停在 v5：event tap 的 C 回调需要文件级可变全局状态，
            // v6 的严格并发检查在这里只会逼出一堆 nonisolated(unsafe) 噪音。
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
