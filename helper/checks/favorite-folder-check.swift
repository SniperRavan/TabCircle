// Pure function rule validation for FavoriteFolderStore.
//
// Running (under helper/):
//   swiftc -parse-as-library Sources/tabcircle/FavoriteFolders.swift \
//          Sources/tabcircle/L10n.swift Sources/tabcircle/Log.swift \
//          checks/favorite-folder-check.swift -o ./foldercheck && ./foldercheck
//
// Rationale: Path normalization and deduplication errors fail silently: duplicate entries
// for the same folder or clicking "Unfavorite" having no effect without errors.
// Ambiguity disambiguation errors cause same-named folders in menus to be indistinguishable.
//
// Tests only pure static functions without instantiating FavoriteFolderStore to avoid
// touching actual user storage.

import Foundation

let NOW: Double = 1_700_000_000_000

func folders(_ paths: [String]) -> [FavoriteFolder] {
    paths.map { FavoriteFolder(path: $0, addedAt: NOW) }
}

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("  ✓ \(name)")
    } else {
        failures += 1
        let d = detail()
        print("  ✗ \(name)\(d.isEmpty ? "" : " — \(d)")")
    }
}

@main
struct Check {
static func main() {

// ── Normalization ───────────────────────────────────────────────────────
print("Path normalization")
do {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    check("~ expansion", FavoriteFolderStore.normalized("~/Documents") == home + "/Documents",
          "got \(FavoriteFolderStore.normalized("~/Documents"))")
    check(".. resolution", FavoriteFolderStore.normalized("/mock/x/dev/../proj") == "/mock/x/proj",
          "got \(FavoriteFolderStore.normalized("/mock/x/dev/../proj"))")
    check("trailing slash removal", FavoriteFolderStore.normalized("/mock/x/proj/") == "/mock/x/proj",
          "got \(FavoriteFolderStore.normalized("/mock/x/proj/"))")
    check("empty string stays empty", FavoriteFolderStore.normalized("") == "")
}

// ── Append and Deduplication ───────────────────────────────────────────
print("Append preserves order, deduplicates by normalized path")
do {
    var list = FavoriteFolderStore.adding([], path: "/a/one", addedAt: NOW)
    list = FavoriteFolderStore.adding(list, path: "/a/two", addedAt: NOW + 1)
    check("Ordered by favorite addition time", list.map(\.path) == ["/a/one", "/a/two"], "got \(list.map(\.path))")

    let dup = FavoriteFolderStore.adding(list, path: "/a/one", addedAt: NOW + 2)
    check("Identical repeat is no-op", dup.map(\.path) == list.map(\.path), "got \(dup.map(\.path))")

    let spelled = FavoriteFolderStore.adding(list, path: "/a/two/", addedAt: NOW + 2)
    check("Trailing slash treated as duplicate", spelled.count == list.count, "got \(spelled.map(\.path))")

    let dotted = FavoriteFolderStore.adding(list, path: "/a/x/../one", addedAt: NOW + 2)
    check("Path with .. treated as duplicate", dotted.count == list.count, "got \(dotted.map(\.path))")

    let empty = FavoriteFolderStore.adding(list, path: "", addedAt: NOW + 2)
    check("Empty path rejected", empty.count == list.count, "got \(empty.map(\.path))")
}

// ── Display Ordering ───────────────────────────────────────────────────
print("byRecency: recently opened first, unopened ordered by added time")
do {
    let a = FavoriteFolder(path: "/a", addedAt: NOW - 3_000)               // Earliest added, never opened
    let b = FavoriteFolder(path: "/b", addedAt: NOW - 2_000, openedAt: NOW) // Just opened
    let c = FavoriteFolder(path: "/c", addedAt: NOW - 1_000)               // Recently added, never opened
    let out = FavoriteFolderStore.byRecency([a, b, c]).map(\.path)
    check("Just opened is first", out.first == "/b", "got \(out)")
    check("Unopened sorted by added time", out == ["/b", "/c", "/a"], "got \(out)")
}

print("touching: repeatedly favorited / opened floats to top of display")
do {
    let a = FavoriteFolder(path: "/a", addedAt: NOW - 3_000)
    let b = FavoriteFolder(path: "/b", addedAt: NOW - 2_000)
    let touched = FavoriteFolderStore.touching([a, b], path: "/a", openedAt: NOW)
    check("openedAt updated", touched.first?.openedAt == NOW,
          "got \(String(describing: touched.first?.openedAt))")
    check("Storage order preserved (only field modified)", touched.map(\.path) == ["/a", "/b"],
          "got \(touched.map(\.path))")
    check("Floats to front on display", FavoriteFolderStore.byRecency(touched).first?.path == "/a",
          "got \(FavoriteFolderStore.byRecency(touched).map(\.path))")
    check("Unknown path is no-op",
          FavoriteFolderStore.touching([a, b], path: "/x", openedAt: NOW) == [a, b])
}

print("Initial archive without openedAt field decodes cleanly (upgrade compatibility)")
do {
    let json = #"[{"path":"/old","addedAt":1}]"#
    let decoded = try? JSONDecoder().decode([FavoriteFolder].self, from: Data(json.utf8))
    check("Entire archive decoded successfully", decoded?.count == 1, "got \(decoded?.count ?? -1) entries")
    check("openedAt falls back to nil", decoded?.first?.openedAt == nil)
}

// ── Opener Ordering ────────────────────────────────────────────────────
print("openerOrder: clicked items sorted by recency first, unclicked retain original order")
do {
    let paths = ["/Finder", "/Terminal", "/VSCode", "/Books"]
    let order = FavoriteFolderStore.openerOrder(
        paths, lastUsed: ["/VSCode": NOW, "/Terminal": NOW - 1_000])
    check("Most recently used first", order == ["/VSCode", "/Terminal", "/Finder", "/Books"],
          "got \(order)")
    let untouched = FavoriteFolderStore.openerOrder(paths, lastUsed: [:])
    check("Unused retain original order", untouched == paths, "got \(untouched)")
    check("All items preserved", order.count == paths.count)
}

// ── Claude Code deep link ───────────────────────────────────────────────
print("claudeCodeURL: path encoded following encodeURIComponent rules")
do {
    let plain = OpenerCatalog.claudeCodeURL(folder: "/mock/me/dev")?.absoluteString
    check("Slashes encoded", plain == "claude://code/new?folder=%2Fmock%2Fme%2Fdev", "got \(plain ?? "nil")")
    let tricky = OpenerCatalog.claudeCodeURL(folder: "/a b/C++ &x=1#y/@test")?.absoluteString
    check("Spaces, +, &, =, #, @ all encoded for URLSearchParams safety",
          tricky == "claude://code/new?folder=%2Fa%20b%2FC%2B%2B%20%26x%3D1%23y%2F%40test",
          "got \(tricky ?? "nil")")
    let keep = OpenerCatalog.claudeCodeURL(folder: "/x-y_z.w~")?.absoluteString
    check("unreserved characters preserved verbatim", keep == "claude://code/new?folder=%2Fx-y_z.w~", "got \(keep ?? "nil")")
}

// ── Disambiguation for Matching Names ──────────────────────────────────
print("Menu title: directory name, disambiguated with parent directory on collision")
do {
    let unique = FavoriteFolderStore.displayTitles(folders(["/dev/alpha", "/dev/beta"]))
    check("Display only directory name when unique", unique == ["alpha", "beta"], "got \(unique)")

    let clash = FavoriteFolderStore.displayTitles(
        folders(["/dev/myspace/web", "/dev/client/web", "/dev/alpha"]))
    check("Append parent directory when names collide", clash == ["web — myspace", "web — client", "alpha"],
          "got \(clash)")
    check("Non-colliding items unaffected", clash.last == "alpha")
}

print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
}
}
