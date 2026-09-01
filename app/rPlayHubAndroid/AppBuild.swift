//
//  AppBuild.swift
//  Build identity and a log that survives the app quitting.
//

import Foundation

enum AppBuild {
    static let version = "0.1.0"

    /// Feature gate for the 3D device twin (experimental). Off by default. Toggled from the
    /// View menu (persisted as the "TwinEnabled" default); `RPLAYHUB_TWIN=1`/`=0` overrides it
    /// for a launch. Gates the menu entry and, at session start, the sensor channel we ask the
    /// agent for — a session started with the gate off carries zero new code paths, and a
    /// freshly flipped gate needs the next session (Reconnect) before orientation flows.
    static var twinEnabled: Bool {
        get {
            if let env = ProcessInfo.processInfo.environment["RPLAYHUB_TWIN"] {
                return env == "1" || env.lowercased() == "true"
            }
            return UserDefaults.standard.bool(forKey: "TwinEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "TwinEnabled") }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Now, for a log line. (Was a `let`, so every line carried the launch time.)
    static var stamp: String { stampFormatter.string(from: Date()) }

    private static let handle: FileHandle? = {
        guard let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        else { return nil }
        let logs = dir.appendingPathComponent("Logs/rPlayHubAndroid", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let url = logs.appendingPathComponent("rplayhub-android.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    /// Log to both Console and the on-disk log. Cheap enough for session lifecycle events;
    /// do not call it per frame.
    static func log(_ message: String) {
        NSLog("rPlayHubAndroid: %@", message)
        guard let handle else { return }
        let line = "\(stamp) \(message)\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
