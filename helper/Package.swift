// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tabcircle",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Permission guide overlay: drag the app icon into the Accessibility list to authorize.
        // Pinned by SemVer tag, not branch/revision.
        .package(url: "https://github.com/sniperravan/PermissionFlow.git", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "tabcircle",
            dependencies: [
                .product(name: "PermissionFlow", package: "PermissionFlow"),
            ],
            path: "Sources/tabcircle",
            // Language mode pinned to v5: event tap C callbacks require file-level mutable global state.
            // Strict concurrency checks in v6 would introduce unnecessary nonisolated(unsafe) boilerplate here.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
