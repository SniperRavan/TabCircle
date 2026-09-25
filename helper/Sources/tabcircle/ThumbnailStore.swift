import AppKit
import CryptoKit
import Foundation

/// Two-level cache for web page thumbnails: memory + disk.
///
/// Persistent caching is necessary because `captureVisibleTab` can only capture currently visible tabs.
/// Thumbnails accumulate gradually during active browsing; in-memory-only caching would wipe them out
/// upon app restarts.
///
/// Indexed by URL rather than tabId: tabIds change on browser restart, whereas URLs remain stable.
@MainActor
final class ThumbnailStore {

    private let directory: URL
    private var memory: [String: NSImage] = [:]

    /// Maximum thumbnails retained on disk. A 400x250 JPEG is ~20-40 KB; 500 items is ~15 MB.
    private let maxEntries = 500

    init() {
        directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/TabCircle/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Read / Write

    func image(for url: String) -> NSImage? {
        let key = Self.key(for: url)
        if let cached = memory[key] { return cached }

        let file = directory.appendingPathComponent(key).appendingPathExtension("jpg")
        guard let data = try? Data(contentsOf: file),
              let image = NSImage(data: data) else { return nil }
        memory[key] = image
        return image
    }

    func store(_ data: Data, for url: String) {
        guard let image = NSImage(data: data) else { return }
        let key = Self.key(for: url)
        memory[key] = image

        let file = directory.appendingPathComponent(key).appendingPathExtension("jpg")
        try? data.write(to: file, options: .atomic)
    }

    /// Pre-load existing thumbnails into memory on startup so first ⌃⇥ has previews immediately.
    func warmUp() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        for file in files where file.pathExtension == "jpg" {
            guard let data = try? Data(contentsOf: file),
                  let image = NSImage(data: data) else { continue }
            memory[file.deletingPathExtension().lastPathComponent] = image
        }
        if !memory.isEmpty {
            log("🖼  loaded \(memory.count) cached thumbnails from disk")
        }
        prune(files: files)
    }

    /// Prune oldest thumbnails when exceeding maximum cache entries.
    private func prune(files: [URL]) {
        guard files.count > maxEntries else { return }
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for file in sorted.dropFirst(maxEntries) {
            try? FileManager.default.removeItem(at: file)
            memory.removeValue(forKey: file.deletingPathExtension().lastPathComponent)
        }
    }

    // MARK: - Key Generation

    /// Hash URLs using SHA256 prefix to generate safe, cross-platform filenames.
    private static func key(for url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
