// Validation of ReleaseNotes parser.
//
// Running (under helper/):
//   swiftc -parse-as-library Sources/tabcircle/ReleaseNotesParser.swift \
//          checks/release-notes-check.swift -o ./notescheck && ./notescheck
//
// Rationale: Parser input is markdown text rather than structured data. Picking the wrong section
// could show the wrong section, while parsing failures could result in empty windows — neither
// produces runtime crashes. Real release notes are used as samples to guarantee correctness.

func check(_ name: String, _ ok: Bool, _ detail: String = "") -> Int {
    print(ok ? "  ✓ \(name)" : "  ✗ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    return ok ? 0 : 1
}

/// Realistic release notes sample preserving headings, bold text, blockquotes, links, and download table.
let realBody = """
## Highlights

- **Global switcher (new)** — press the shortcut from any app outside your browsers to list all tabs
- **Longer tab lifetimes** — you can now pick **1 month / 3 months / 6 months / 1 year**
- **Fixed** deleting a pinned entry while its browser was closed

> The extension changed in this release: download TabCircle-Extension.zip below and reload it.

## What's New

- **Global switcher (new)** — press the shortcut from any app outside your browsers
- **Longer tab lifetimes** — you can now pick **1 month / 3 months / 6 months / 1 year**
- **Fixed** deleting a pinned entry while its browser was closed

> The extension changed in this release: download TabCircle-Extension.zip below and reload it.

Requires macOS 14+ and a Chromium-based browser 116+.

### Download
| File | For |
|------|-----|
| TabCircle-0.6.0-arm64.dmg | Apple Silicon (M1/M2/M3/M4) |
| TabCircle-Extension.zip | Browser extension |
"""

@main
struct Check {
    static func main() {
        var failures = 0

        // —— Highlights section ——
        let highlights = ReleaseNotesParser.section(from: realBody, heading: "Highlights")
        failures += check("Highlights section contains expected item", highlights.contains("press the shortcut from any app"))
        failures += check("Highlights section does not contain download table", !highlights.contains("arm64.dmg"))

        // —— English section ——
        let en = ReleaseNotesParser.section(from: realBody, heading: "What's New")
        failures += check("English section contains English item", en.contains("Global switcher (new)"))
        failures += check("English section does not contain download table", !en.contains("| File |"))

        // —— Curly quotes handling ——
        let curly = realBody.replacingOccurrences(of: "What's New", with: "What\u{2019}s New")
        let curlySection = ReleaseNotesParser.section(from: curly, heading: "What's New")
        failures += check("Curly quote heading still matches", curlySection.contains("Global switcher"))
        failures += check("Curly quote matches section itself rather than fallback",
                          !curlySection.contains("Highlights"),
                          "Fell into fallback")

        // Case insensitivity
        let upper = realBody.replacingOccurrences(of: "## What's New", with: "## WHAT'S NEW")
        let upperSection = ReleaseNotesParser.section(from: upper, heading: "What's New")
        failures += check("Heading case variation matches English section",
                          upperSection.contains("Global switcher") && !upperSection.contains("Highlights"))

        // Fallback when structure is unrecognized
        let weird = "Just a plain changelog line.\n- some bullet\n\n### Download\n| a | b |"
        let fallback = ReleaseNotesParser.section(from: weird, heading: "Highlights")
        failures += check("Fallback to whole text when no heading matches", fallback.contains("some bullet"))
        failures += check("Fallback strips download table", !fallback.contains("| a | b |"))
        failures += check("Empty input returns empty", ReleaseNotesParser.section(from: "", heading: "Highlights").isEmpty)

        // Block chunking
        let blocks = ReleaseNotesParser.blocks(from: highlights)
        let bullets = blocks.filter { if case .bullet = $0 { return true }; return false }
        let callouts = blocks.filter { if case .callout = $0 { return true }; return false }
        failures += check("Three items parsed as bullets", bullets.count == 3, "actual \(bullets.count)")
        failures += check("Quote block parsed as callout", callouts.count == 1, "actual \(callouts.count)")
        failures += check("Bullet stripped leading dash",
                          bullets.contains { if case .bullet(let t) = $0 { return t.hasPrefix("**Global switcher") }; return false })
        failures += check("No empty blocks generated", !blocks.contains { block in
            switch block {
            case .bullet(let t), .callout(let t), .paragraph(let t):
                return t.trimmingCharacters(in: .whitespaces).isEmpty
            }
        })

        // Table rows are skipped even if encountered
        let tableLeak = ReleaseNotesParser.blocks(from: "| File | For |\n|---|---|\n- real bullet")
        failures += check("Table rows not rendered", tableLeak.count == 1, "actual \(tableLeak.count)")

        print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
        if failures > 0 { fatalError("ReleaseNotes parsing validation failed") }
    }
}
