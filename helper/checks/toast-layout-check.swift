// Validation of Toast layout and typography.
//
// Running (under helper/):
//   swiftc -parse-as-library Sources/tabcircle/Toast.swift \
//          Sources/tabcircle/WindowShadow.swift \
//          checks/toast-layout-check.swift -o ./toastcheck && ./toastcheck
//
// Rationale: Truncated text does not throw errors or crash — characters simply go missing.
// A previous version sized the label frame using NSString.size(withAttributes:), which is
// 8pt narrower than what NSTextField's cell actually requires (4pt padding on each side).
// As a result, "Path copied" was clipped to "Pa...ed" by byTruncatingMiddle.
// Such issues can only be caught by computing and asserting on rendered dimensions.
//
// The criterion is "whether the width given to the label is sufficient for its declared size",
// rather than matching a magic number. If the text genuinely exceeds maxTextWidth, truncation
// is intentional and explicitly permitted.

import AppKit

@MainActor
func checkLayout() {
    var cases = 0
    var failures = 0

    func fail(_ message: String) {
        failures += 1
        print("✗ \(message)")
    }

    /// Comprehensive inspection of a single toast.
    func inspect(_ title: String, detail: String?, kind: Toast.Kind, label name: String) {
        cases += 1
        let content = Toast.makeContent(title: title, detail: detail, kind: kind)
        let bounds = content.bounds

        guard bounds.width > 0, bounds.height > 0 else {
            return fail("\(name): Zero bounds \(bounds.size)")
        }

        var fields: [NSTextField] = []
        for sub in content.subviews {
            // Subviews must not exceed content bounds — overflow would be masked out by the panel mask
            if !bounds.insetBy(dx: -0.5, dy: -0.5).contains(sub.frame) {
                fail("\(name): Subview out of bounds \(sub.frame) not in \(bounds)")
            }
            if let field = sub as? NSTextField { fields.append(field) }
            if sub is NSImageView, sub.frame.width < 8 {
                fail("\(name): Icon not drawn (\(sub.frame.size))")
            }
        }

        let wantFields = (detail ?? "").isEmpty ? 1 : 2
        if fields.count != wantFields {
            fail("\(name): Expected \(wantFields) text fields, got \(fields.count)")
        }

        for field in fields {
            guard let cell = field.cell else { continue }
            let text = field.stringValue
            // Recompute layout at the assigned width to see if it requires more height/width
            let needed = cell.cellSize(forBounds:
                NSRect(x: 0, y: 0, width: field.frame.width, height: 10_000))

            if needed.height > field.frame.height + 0.5 {
                fail("\(name): \"\(text)\" height insufficient, needed \(needed.height), got \(field.frame.height)")
            }
            // Single-line label: cellSize represents the exact width needed to display without clipping.
            // Fitting within limit but not given enough width = layout error.
            // Exceeding the maximum limit is intentional truncation.
            if field.maximumNumberOfLines == 1 {
                let full = cell.cellSize.width
                if full <= Toast.maxTextWidth, full > field.frame.width + 0.5 {
                    fail("\(name): \"\(text)\" would be truncated — needed \(full), got \(field.frame.width)")
                }
            }
            if field.frame.width > Toast.maxTextWidth + 0.5 {
                fail("\(name): \"\(text)\" width \(field.frame.width) exceeds maximum \(Toast.maxTextWidth)")
            }
        }

        // Two-line layout relationship: subtitle is positioned directly below title, left-aligned, non-overlapping
        if fields.count == 2 {
            let (title, detail) = (fields[0], fields[1])
            if detail.frame.maxY > title.frame.minY + 0.5 {
                fail("\(name): Title and subtitle overlap (\(title.frame) / \(detail.frame))")
            }
            if abs(detail.frame.minX - title.frame.minX) > 0.5 {
                fail("\(name): Lines not left-aligned (\(title.frame.minX) / \(detail.frame.minX))")
            }
        }

        // Icon and text must not collide
        if let icon = content.subviews.compactMap({ $0 as? NSImageView }).first,
           let first = fields.first, icon.frame.maxX > first.frame.minX + 0.5 {
            fail("\(name): Icon overlaps text (\(icon.frame) / \(first.frame))")
        }
    }

    let longPath = "Documents/Dev/myspace/TabCircle/helper/Sources/tabcircle"
    inspect("Path copied", detail: nil, kind: .success, label: "Path copied - no subtitle")
    inspect("Path copied", detail: "Documents/Dev", kind: .success, label: "Path copied - short subtitle")
    inspect("Path copied", detail: longPath, kind: .success, label: "Path copied - long path")
    inspect("Path copied", detail: longPath, kind: .success, label: "English - long path")
    inspect("Saved \"TabCircle\"", detail: longPath, kind: .success, label: "Saved folder")
    inspect("\"TabCircle\" already in favorites, moved to top", detail: longPath, kind: .info, label: "Already in favorites")
    inspect("Removed \"TabCircle\" from favorites", detail: longPath, kind: .success, label: "Remove favorite")
    inspect("Opened \"my-project\" in Visual Studio Code", detail: longPath,
            kind: .success, label: "Open folder")
    inspect("Failed to open",
            detail: "The application “Visual Studio Code” could not be launched because "
                  + "it is not installed on this Mac.",
            kind: .failure, label: "Failed to open - long error")

    // Extreme inputs must not crash or calculate negative bounds
    inspect("", detail: nil, kind: .success, label: "Empty title")
    inspect(String(repeating: "W", count: 400), detail: String(repeating: "x", count: 2000),
            kind: .failure, label: "Ultra long text")
    inspect("New\nLine", detail: "With\tTab", kind: .info, label: "Control characters")
    inspect("🎉 Emoji", detail: "relative/🗂️/файл", kind: .success, label: "Emoji and non-Latin characters")

    print(failures == 0
          ? "All passed (\(cases) cases)"
          : "\(failures) failed (out of \(cases) cases)")
    if failures > 0 { fatalError("Toast layout validation failed") }
}

@main
enum ToastLayoutCheck {
    static func main() {
        // On failure, fatalError -> abort() without flushing stdio; unbuffer stdout so failure details are preserved.
        setvbuf(stdout, nil, _IONBF, 0)
        // NSTextField cells measure accurately once AppKit is initialized
        _ = NSApplication.shared
        MainActor.assumeIsolated { checkLayout() }
    }
}
