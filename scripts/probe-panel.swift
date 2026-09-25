#!/usr/bin/env swift
//
// Overlay lifecycle probe.
//
// Scans window server every 200ms to inspect position, opacity, and layer of TabCircle windows.
//

import Cocoa

let logPath = "/tmp/tabcircle-panel-probe.log"
FileManager.default.createFile(atPath: logPath, contents: nil)
let handle = FileHandle(forWritingAtPath: logPath)!

let formatter = DateFormatter()
formatter.dateFormat = "HH:mm:ss.SSS"

func emit(_ line: String) {
    let stamped = "[\(formatter.string(from: Date()))] \(line)"
    print(stamped)
    handle.write(Data((stamped + "\n").utf8))
}

let screen = NSScreen.main?.frame ?? .zero
let visible = NSScreen.main?.visibleFrame ?? .zero
emit("screen frame=\(screen)  visibleFrame=\(visible)")
emit("Starting scan...")

var lastSignature = ""
var ticks = 0

let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
    ticks += 1

    let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"

    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return
    }

    var rows: [String] = []
    for entry in list {
        guard let owner = entry[kCGWindowOwnerName as String] as? String, owner == "TabCircle" else { continue }
        let name = (entry[kCGWindowName as String] as? String) ?? ""
        let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -999
        let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1
        guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
        rows.append(String(
            format: "    win name=%@ layer=%d alpha=%.2f bounds=(%.0f,%.0f %.0fx%.0f)",
            name.isEmpty ? "<untitled>" : name, layer, alpha,
            bounds.minX, bounds.minY, bounds.width, bounds.height
        ))
    }

    let signature = frontmost + "|" + rows.joined()
    if signature != lastSignature {
        emit("frontmost=\(frontmost)  TabCircle window count=\(rows.count)")
        rows.forEach { emit($0) }
        lastSignature = signature
    }

    if ticks >= 75 {   // 15 seconds
        emit("Scan complete")
        timer.invalidate()
        handle.closeFile()
        exit(0)
    }
}

RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
