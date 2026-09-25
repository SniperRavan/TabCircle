import Foundation

/// Release notes parser.
///
/// Isolated in a standalone file with Foundation-only dependencies so it can be compiled
/// and verified independently (`helper/checks/release-notes-check.swift`). Input is handwritten
/// markdown rather than structured data, requiring robust tests against realistic samples.
enum ReleaseNotesParser {

    enum Block: Equatable {
        case bullet(String)
        case callout(String)
        case paragraph(String)
    }

    /// Extracts a specific section from release notes matching the given heading.
    ///
    /// General structure: `## Section Heading ... ### Download table`.
    /// Download tables are excluded from UI display. When a heading is not matched,
    /// falls back to the full text minus download tables.
    static func section(from body: String, heading: String) -> String {
        var collected: [String] = []
        var capturing = false
        var sawAnyHeading = false

        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                sawAnyHeading = true
                let title = normalized(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                if title.contains(normalized("Download")) { break }   // Exclude download table and everything following it
                capturing = (title == normalized(heading))
                continue
            }
            if capturing { collected.append(raw) }
        }

        if collected.isEmpty {
            // Unrecognized heading: use full body, but still strip the download table
            let all = body.components(separatedBy: .newlines)
            if let cut = all.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                    && normalized($0).contains(normalized("Download"))
            }) {
                collected = Array(all[..<cut])
            } else {
                collected = all
            }
            // During fallback, preserve headings as visual separators
            if sawAnyHeading { collected = collected.filter { !$0.hasPrefix("#") } }
        }
        return collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalize curly quotes and case sensitivity in handwritten markdown headings.
    private static func normalized(_ s: any StringProtocol) -> String {
        s.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
    }

    /// Chunks section into renderable blocks: bullets, callouts, and paragraphs.
    static func blocks(from section: String) -> [Block] {
        var result: [Block] = []
        for raw in section.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(.bullet(String(line.dropFirst(2))))
            } else if line.hasPrefix(">") {
                let text = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { result.append(.callout(text)) }
            } else if line.hasPrefix("|") || line.hasPrefix("---") {
                continue   // Markdown table remnants, do not render
            } else {
                result.append(.paragraph(line))
            }
        }
        return result
    }
}
