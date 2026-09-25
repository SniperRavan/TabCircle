import Foundation

/// SwiftPM's generated `Bundle.module` accessor for packages statically
/// linked into an executable only checks two locations: the host `.app`
/// bundle root and the absolute build-machine path baked in at compile
/// time. Signed/notarized apps must keep resource bundles under
/// `Contents/Resources` — anything at the `.app` root breaks the signature
/// seal ("unsealed contents") — so the generated accessor misses them and
/// traps at startup. This resolver covers every layout the host app ships.
extension Bundle {
    nonisolated static let permissionFlowResources: Bundle = {
        let name = "PermissionFlow_PermissionFlow.bundle"
        let candidates: [URL?] = [
            // Signed .app layout: Contents/Resources/
            Bundle.main.resourceURL,
            // Legacy ad-hoc .app layout: bundle root
            Bundle.main.bundleURL,
            // CLI / `swift run` / test runners: next to the executable
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ]
        for candidate in candidates {
            if let url = candidate?.appendingPathComponent(name),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        // Dev fallback: the generated accessor knows the local build dir.
        return .module
    }()
}
