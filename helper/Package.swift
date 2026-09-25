// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tabcircle",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Permission guide overlay: vendored locally with Swift 6.0 compatibility
        .package(path: "Packages/PermissionFlow"),
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
