import AppKit
import SwiftUI

/// Checks for updates via GitHub Releases and automatically installs new versions.
///
/// Downloads the appropriate DMG for the current architecture, verifies byte size, mounts the volume,
/// replaces the `.app` contents in-place (preserving bundle path and accessibility permissions), and relaunches.
@MainActor
final class UpdateChecker: ObservableObject {

    private static let repo = "sniperravan/TabCircle"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedKey = "skippedUpdateVersion"

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var pendingVersion = ""

    /// Automatic update check frequency.
    var frequency: () -> UpdateCheckFrequency = { .daily }

    private var downloadTask: URLSessionDownloadTask?
    private var downloadDelegate: DownloadDelegate?
    private var downloadCancelled = false
    private var progressWindow: NSWindow?
    private var periodicTimer: Timer?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Check

    func check(userInitiated: Bool) {
        guard status != .checking, !isDownloading else { return }
        status = .checking

        Task {
            let result = await fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

            switch result {
            case .failure(let message):
                status = .failed(message)
                if userInitiated { presentFailure(message) }

            case .success(let release):
                if isNewer(release.version, than: currentVersion) {
                    status = .available(version: release.version)
                    let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
                    if userInitiated || release.version != skipped {
                        presentAvailable(release)
                    }
                } else {
                    status = .upToDate
                    if userInitiated { presentUpToDate() }
                }
            }
        }
    }

    /// Periodic checks: evaluates schedule hourly.
    func startPeriodicChecks() {
        periodicTimer?.invalidate()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard let interval = frequency().interval else { return }   // .never
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= interval else { return }
        check(userInitiated: false)
    }

    // MARK: - Networking

    private struct Latest {
        let version: String
        let assetURL: URL?
        let assetSize: Int64
    }

    private enum FetchResult {
        case success(Latest)
        case failure(String)
    }

    private func fetchLatest() async -> FetchResult {
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0

            if code == 404 {
                return .success(Latest(version: "0.0.0", assetURL: nil, assetSize: 0))
            }
            guard code == 200 else {
                return .failure("GitHub returned \(code)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                return .failure("Could not parse the release info")
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            var assetURL: URL?
            var assetSize: Int64 = 0
            if let assets = json["assets"] as? [[String: Any]],
               let asset = assets.first(where: {
                   let name = $0["name"] as? String ?? ""
                   return name.contains(arch) && name.hasSuffix(".dmg")
               }) {
                assetURL = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
                assetSize = (asset["size"] as? NSNumber)?.int64Value ?? 0
            }
            return .success(Latest(version: version, assetURL: assetURL, assetSize: assetSize))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Compares dot-separated numerical version strings.
    private func isNewer(_ remote: String, than current: String) -> Bool {
        let a = remote.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Download

    private func startDownload(_ latest: Latest) {
        guard let url = latest.assetURL, !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        downloadCancelled = false
        pendingVersion = latest.version
        showProgressWindow()

        let delegate = DownloadDelegate(
            expectedSize: latest.assetSize,
            onProgress: { [weak self] progress in
                Task { @MainActor in self?.downloadProgress = progress }
            },
            onFinish: { [weak self] result in
                Task { @MainActor in self?.downloadFinished(result) }
            }
        )
        downloadDelegate = delegate
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadCancelled = true
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        closeProgressWindow()
    }

    private func downloadFinished(_ result: DownloadResult) {
        isDownloading = false
        downloadTask = nil
        closeProgressWindow()

        switch result {
        case .success(let fileURL):
            installAndRestart(from: fileURL)
        case .failure(let message):
            guard !downloadCancelled else { return }
            presentInstallFailure(message)
        }
    }

    // MARK: - Installation

    private func installAndRestart(from dmg: URL) {
        let destApp = Bundle.main.bundlePath
        guard destApp.hasSuffix(".app") else {
            NSWorkspace.shared.open(dmg)
            return
        }

        guard let mountPoint = Self.mountDMG(at: dmg.path) else {
            presentInstallFailure("The update image could not be opened")
            return
        }
        let sourceApp = "\(mountPoint)/TabCircle.app"
        guard FileManager.default.fileExists(atPath: sourceApp) else {
            Self.detachDMG(mountPoint)
            presentInstallFailure("The update image is missing the app")
            return
        }

        let script = """
        #!/bin/bash
        sleep 2
        rm -rf "\(destApp)/Contents/MacOS" "\(destApp)/Contents/Resources" "\(destApp)/Contents/_CodeSignature"
        rm -rf "\(destApp)"/*.bundle
        cp -R "\(sourceApp)/Contents/MacOS" "\(destApp)/Contents/MacOS"
        cp -R "\(sourceApp)/Contents/Resources" "\(destApp)/Contents/Resources"
        cp "\(sourceApp)/Contents/Info.plist" "\(destApp)/Contents/Info.plist"
        if [ -d "\(sourceApp)/Contents/_CodeSignature" ]; then
            cp -R "\(sourceApp)/Contents/_CodeSignature" "\(destApp)/Contents/_CodeSignature"
        fi
        for b in "\(sourceApp)"/*.bundle; do
            [ -d "$b" ] && cp -R "$b" "\(destApp)/"
        done
        hdiutil detach "\(mountPoint)" -quiet 2>/dev/null
        xattr -dr com.apple.quarantine "\(destApp)" 2>/dev/null
        open "\(destApp)"
        rm -f "$0"
        """

        do {
            let scriptPath = NSTemporaryDirectory() + "tabcircle_update.sh"
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
            try process.run()
            log("Updater launched — replacing app contents and relaunching")
            NSApp.terminate(nil)
        } catch {
            Self.detachDMG(mountPoint)
            NSWorkspace.shared.open(dmg)
        }
    }

    private static func mountDMG(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", path, "-nobrowse", "-noverify"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = output.components(separatedBy: "\n").first(where: { $0.contains("/Volumes/") }),
              let range = line.range(of: "/Volumes/") else { return nil }
        return String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
    }

    private static func detachDMG(_ mountPoint: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-quiet"]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Progress Window

    private func showProgressWindow() {
        if progressWindow == nil {
            let host = NSHostingController(rootView: DownloadProgressView(updates: self))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled]
            w.title = "Software Update"
            w.isReleasedWhenClosed = false
            host.view.layoutSubtreeIfNeeded()
            w.setContentSize(host.view.fittingSize)
            w.center()
            progressWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        progressWindow?.makeKeyAndOrderFront(nil)
    }

    private func closeProgressWindow() {
        progressWindow?.orderOut(nil)
        progressWindow = nil
    }

    // MARK: - Presentation Dialogs

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentAvailable(_ latest: Latest) {
        activate()
        let alert = NSAlert()
        alert.messageText = "Version \(latest.version) is available"

        if latest.assetURL != nil {
            alert.informativeText = "You have \(currentVersion). Download and install — it restarts on its own."
            alert.addButton(withTitle: "Download & Install")
            alert.addButton(withTitle: "Later")
            alert.addButton(withTitle: "Skip This Version")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                startDownload(latest)
            case .alertThirdButtonReturn:
                UserDefaults.standard.set(latest.version, forKey: Self.skippedKey)
            default:
                break
            }
        } else {
            alert.informativeText = "You have \(currentVersion). This release has no package for this Mac — grab one from the releases page."
            alert.addButton(withTitle: "Open Download Page")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(Self.releasesPage)
            }
        }
    }

    private func presentUpToDate() {
        activate()
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "TabCircle \(currentVersion) is the latest version."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentFailure(_ message: String) {
        activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not check for updates"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentInstallFailure(_ message: String) {
        activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Automatic update failed"
        alert.informativeText = message + "\n\nYou can download it manually from the releases page."
        alert.addButton(withTitle: "Open Download Page")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.releasesPage)
        }
    }
}

// MARK: - Download Progress View

private struct DownloadProgressView: View {
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Downloading TabCircle \(updates.pendingVersion)…")
                .font(.system(size: 13, weight: .medium))
            ProgressView(value: updates.downloadProgress)
                .frame(width: 280)
            HStack {
                Text("\(Int(updates.downloadProgress * 100))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel") {
                    updates.cancelDownload()
                }
            }
            .frame(width: 280)
        }
        .padding(20)
    }
}

// MARK: - Download Delegate

private enum DownloadResult {
    case success(URL)
    case failure(String)
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {

    private let expectedSize: Int64
    private let onProgress: (Double) -> Void
    private let onFinish: (DownloadResult) -> Void
    private var finished = false

    init(expectedSize: Int64,
         onProgress: @escaping (Double) -> Void,
         onFinish: @escaping (DownloadResult) -> Void) {
        self.expectedSize = expectedSize
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("TabCircle-update.dmg")
        try? FileManager.default.removeItem(at: dest)

        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            finished = true
            onFinish(.failure(error.localizedDescription))
            return
        }

        if expectedSize > 0,
           let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let fileSize = attrs[.size] as? Int64,
           fileSize != expectedSize {
            try? FileManager.default.removeItem(at: dest)
            finished = true
            onFinish(.failure("Incomplete download (\(fileSize)/\(expectedSize) bytes)"))
            return
        }

        finished = true
        onFinish(.success(dest))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : max(expectedSize, 1)
        onProgress(Double(totalBytesWritten) / Double(total))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        guard let error, !finished else { return }
        finished = true
        onFinish(.failure(error.localizedDescription))
    }
}
