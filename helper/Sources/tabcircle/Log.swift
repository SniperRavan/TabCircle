import Foundation

/// Logs simultaneously to stdout and file. The log file is truncated on startup so it always reflects the current run.
///
/// Placed in the standard macOS logs directory rather than the repository directory.
let kLogPath: String = {
    let directory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TabCircle", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("tabcircle.log").path
}()

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

private let logHandle: FileHandle? = {
    FileManager.default.createFile(atPath: kLogPath, contents: nil)
    return FileHandle(forWritingAtPath: kLogPath)
}()

private let logQueue = DispatchQueue(label: "com.tabcircle.log")

/// Timestamp when the running binary was compiled.
///
/// Useful for confirming that binary updates have taken effect.
func binaryBuildTime() -> String {
    let path = CommandLine.arguments.first ?? ""
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let date = attrs[.modificationDate] as? Date else { return "unknown" }
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    return f.string(from: date)
}

func log(_ message: String) {
    let line = "[\(logFormatter.string(from: Date()))] \(message)"
    print(line)
    fflush(stdout)
    // File writing is dispatched to its own queue: event tap callback path must not have synchronous disk I/O
    logQueue.async {
        if let data = (line + "\n").data(using: .utf8) {
            logHandle?.write(data)
        }
    }
}
