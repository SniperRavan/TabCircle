// Rule validation for ClosedTabStore.merging.
//
// Running (under helper/):
//   swiftc -parse-as-library Sources/tabcircle/ClosedTabStore.swift \
//          Sources/tabcircle/L10n.swift Sources/tabcircle/Log.swift \
//          checks/closed-tab-store-check.swift -o ./closedcheck && ./closedcheck
//
// Rationale: Merging must simultaneously satisfy four intertwined rules: descending order,
// deduplication per (browser + URL) keeping the freshest, pruning expired entries, and capping limits.
// Any logic error fails silently: items are omitted from lists or old items overwrite new ones without errors.
//
// Tests only the pure static function `merging`, never instantiating ClosedTabStore to avoid
// touching actual user storage.

import Foundation

let NOW: Double = 1_700_000_000_000     // Fixed reference time, independent of system clock
let DAY: Double = 86_400 * 1000
let MAX_AGE: TimeInterval = 30 * 86_400
let MAX_ENTRIES = 1000

func tab(_ url: String, _ browser: String = "chrome",
         daysAgo: Double = 0, title: String = "") -> ClosedTab {
    ClosedTab(url: url, title: title.isEmpty ? url : title, favIconUrl: "",
              browser: browser, reason: .manual, closedAt: NOW - daysAgo * DAY)
}

func merge(_ existing: [ClosedTab], _ incoming: [ClosedTab],
           maxEntries: Int = MAX_ENTRIES) -> [ClosedTab] {
    ClosedTabStore.merging(existing: existing, incoming: incoming,
                           now: NOW, maxAge: MAX_AGE, maxEntries: maxEntries)
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

// ── Descending Order ───────────────────────────────────────────────────
print("Results sorted in descending order by closed time")
do {
    let out = merge([], [tab("https://old/", daysAgo: 5),
                         tab("https://new/", daysAgo: 1),
                         tab("https://mid/", daysAgo: 3)])
    check("Newest at the front", out.first?.url == "https://new/", "got \(out.map(\.url))")
    check("Oldest at the end", out.last?.url == "https://old/")
    check("No items lost", out.count == 3)
}

// ── Deduplication ───────────────────────────────────────────────────────
print("Same URL under same browser keeps only the freshest entry")
do {
    let out = merge([tab("https://a/", daysAgo: 5, title: "Old")],
                    [tab("https://a/", daysAgo: 1, title: "New")])
    check("Only one left", out.count == 1, "got \(out.count) entries")
    check("Newer one kept", out.first?.title == "New", "retained \(out.first?.title ?? "?")")
}

print("Incoming entry older than existing entry: keep existing (clock skew must not overwrite)")
do {
    let out = merge([tab("https://a/", daysAgo: 1, title: "New")],
                    [tab("https://a/", daysAgo: 5, title: "Old")])
    check("Newer one still kept", out.first?.title == "New", "retained \(out.first?.title ?? "?")")
}

print("Duplicates within the same batch keep only newest (order-independent)")
do {
    let forward = merge([], [tab("https://a/", daysAgo: 5, title: "Old"),
                             tab("https://a/", daysAgo: 1, title: "New")])
    let reverse = merge([], [tab("https://a/", daysAgo: 1, title: "New"),
                             tab("https://a/", daysAgo: 5, title: "Old")])
    check("Ascending: keep newest", forward.first?.title == "New")
    check("Descending: also keep newest", reverse.first?.title == "New",
          "reversed retained \(reverse.first?.title ?? "?")")
}

print("Same URL across different browsers keeps both (browser isolation)")
do {
    let out = merge([], [tab("https://a/", "chrome", daysAgo: 1),
                         tab("https://a/", "quark", daysAgo: 2)])
    check("Both present", out.count == 2, "got \(out.count) entries")
}

// ── Expiration ─────────────────────────────────────────────────────────
print("Discard entries older than 30 days")
do {
    let out = merge([tab("https://ancient/", daysAgo: 31)],
                    [tab("https://fresh/", daysAgo: 29)])
    check("31 days ago discarded", !out.contains { $0.url == "https://ancient/" }, "got \(out.map(\.url))")
    check("29 days ago preserved", out.contains { $0.url == "https://fresh/" })
}

print("Expired entry in middle does not prune newer entries after it")
do {
    let out = merge([], [tab("https://ancient/", daysAgo: 40),
                         tab("https://fresh/", daysAgo: 1)])
    check("New entry survived", out.contains { $0.url == "https://fresh/" }, "got \(out.map(\.url))")
    check("Old entry discarded", out.count == 1, "got \(out.count) entries")
}

// ── Limit ──────────────────────────────────────────────────────────────
print("Prune oldest entries when exceeding max entries")
do {
    let many = (0..<50).map { tab("https://s\($0)/", daysAgo: Double($0) * 0.1) }
    let out = merge([], many, maxEntries: 10)
    check("Exactly 10 entries", out.count == 10, "got \(out.count) entries")
    check("Freshest 10 retained", out.allSatisfy { url in
        (0..<10).map { "https://s\($0)/" }.contains(url.url)
    }, "got \(out.map(\.url))")
    check("Oldest pruned", !out.contains { $0.url == "https://s49/" })
}

print("New incoming entry evicts oldest (not 'reject when full')")
do {
    let full = (0..<10).map { tab("https://s\($0)/", daysAgo: Double($0 + 1)) }
    let out = merge(full, [tab("https://brand-new/", daysAgo: 0)], maxEntries: 10)
    check("Still 10 entries", out.count == 10, "got \(out.count) entries")
    check("Newest at front", out.first?.url == "https://brand-new/", "first is \(out.first?.url ?? "?")")
    check("Oldest evicted", !out.contains { $0.url == "https://s9/" }, "got \(out.map(\.url))")
}

// ── Field Normalization ────────────────────────────────────────────────
print("Ultra-long title truncated at instantiation (title is web-controlled)")
do {
    let long = String(repeating: "T", count: 5000)
    let t = ClosedTab(url: "https://a/", title: long, favIconUrl: "",
                      browser: "chrome", reason: .manual, closedAt: NOW)
    check("Truncated to max limit", t.title.count == ClosedTab.maxTitleLength, "length \(t.title.count)")
}

print("Unrecognized reason decoded as manual to preserve entire archive")
do {
    let json = """
    [{"id":"x","url":"https://a/","title":"t","favIconUrl":"","browser":"chrome",\
    "reason":"from-the-future","closedAt":\(NOW)}]
    """
    let decoded = try? JSONDecoder().decode([ClosedTab].self, from: Data(json.utf8))
    check("Entire archive decoded successfully", decoded?.count == 1, "got \(decoded?.count ?? -1) entries")
    check("Reason fell back to manual", decoded?.first?.reason == .manual)
}

print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
}
}
