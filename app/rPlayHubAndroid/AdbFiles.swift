//
//  AdbFiles.swift
//  Pulling files, listing directories, and installing APKs.
//
//  Split from Adb.swift, which owns the host protocol itself. Everything here is built on top of
//  that: `sync:` for file transfer, `exec:` for the rest.
//

import Foundation

extension Adb {
    // MARK: - directory listing

    struct DirEntry {
        let name: String
        let size: Int
        let isDirectory: Bool
        let isLink: Bool
        let modified: String
        let permissions: String

        var displaySize: String {
            if isDirectory { return "--" }
            if size < 1024 { return "\(size) B" }
            if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
            if size < 1024 * 1024 * 1024 {
                return String(format: "%.1f MB", Double(size) / (1024 * 1024))
            }
            return String(format: "%.2f GB", Double(size) / (1024 * 1024 * 1024))
        }
    }

    /// `ls -la`, parsed. Toybox's output is stable enough to split on, and the alternative — the
    /// sync protocol's LIST — gives no symlink flag and truncates names on old devices.
    static func list(_ serial: String, path: String) throws -> [DirEntry] {
        // Trailing slash, so a symlinked directory lists its CONTENTS rather than the link
        // itself — `ls -la /sdcard` returns one line describing the symlink, which looked like
        // an almost-empty device.
        let quoted = shellQuote(path.hasSuffix("/") ? path : path + "/")
        let out = try shell(serial, "ls -la \(quoted) 2>/dev/null")
        var entries: [DirEntry] = []
        for line in out.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("total ") else { continue }
            // -rw-r--r-- 1 root root 1234 2026-08-29 11:16 name with spaces
            let fields = trimmed.split(separator: " ", maxSplits: 7,
                                       omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 8 else { continue }
            let perms = fields[0]
            guard perms.count >= 10 else { continue }
            // toybox escapes spaces and other specials in names, so "a b.txt" arrives as
            // "a\\ b.txt". Undo that, or every such file gets the wrong name and cannot be pulled.
            var name = unescape(fields[7])
            let isLink = perms.hasPrefix("l")
            // A symlink prints as "name -> target"; keep the name.
            if isLink, let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            guard name != ".", name != ".." else { continue }
            entries.append(DirEntry(name: name,
                                    size: Int(fields[4]) ?? 0,
                                    isDirectory: perms.hasPrefix("d"),
                                    isLink: isLink,
                                    modified: "\(fields[5]) \(fields[6])",
                                    permissions: perms))
        }
        // Directories first, then case-insensitive by name — how every file browser does it.
        return entries.sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory
                                             : $0.name.lowercased() < $1.name.lowercased()
        }
    }

    // MARK: - sync: pull

    /// Fetch a remote file to a local path. The mirror image of `push`: RECV, then DATA chunks
    /// until DONE.
    static func pull(_ serial: String, remotePath: String, localPath: String) throws {
        let s = try openTransport(serial)
        defer { s.shutdownAndClose() }
        try send(s, "sync:")

        let spec = Data(remotePath.utf8)
        try s.writeAll(Data("RECV".utf8) + le32(UInt32(spec.count)) + spec)

        var out = Data()
        while true {
            let header = try s.readFully(8)
            let tag = String(decoding: header.prefix(4), as: UTF8.self)
            let length = Int(le32Value(header.suffix(4)))
            switch tag {
            case "DATA":
                guard length >= 0, length <= 256 * 1024 else {
                    throw AdbError.protocolError("implausible sync chunk \(length)")
                }
                out.append(try s.readFully(length))
            case "DONE":
                try out.write(to: URL(fileURLWithPath: localPath))
                return
            case "FAIL":
                let msg = length > 0
                    ? String(decoding: try s.readFully(length), as: UTF8.self) : "unknown"
                throw AdbError.failed("pull \(remotePath): \(msg)")
            default:
                throw AdbError.protocolError("unexpected sync tag '\(tag)'")
            }
        }
    }

    // MARK: - packages

    struct Package {
        let id: String
        var label: String?
        var versionName: String?
        let isSystem: Bool
    }

    /// `pm list packages`. Labels are deliberately not fetched here — that needs one `dumpsys
    /// package` per app and would make opening the tab take seconds on a device with 300 of them.
    static func packages(_ serial: String, includeSystem: Bool) throws -> [Package] {
        var out: [Package] = []
        var seen = Set<String>()
        // Third-party first so that, if a package somehow appears in both lists, it is not
        // mislabelled as a system app.
        let queries = includeSystem ? [("-3", false), ("-s", true)] : [("-3", false)]
        for (flag, isSystem) in queries {
            let text = try shell(serial, "pm list packages \(flag)")
            for line in text.components(separatedBy: "\n") {
                let id = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "package:", with: "")
                guard !id.isEmpty, seen.insert(id).inserted else { continue }
                out.append(Package(id: id, isSystem: isSystem))
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    static func versionName(_ serial: String, package: String) -> String? {
        // No `grep -m1`: closing the pipe early makes dumpsys log "Failed to write while dumping
        // service package: Broken pipe" onto the output we are trying to read.
        guard let text = try? shell(serial, "dumpsys package \(shellQuote(package)) | grep versionName")
        else { return nil }
        for line in text.components(separatedBy: "\n") where line.contains("versionName=") {
            let value = line.components(separatedBy: "versionName=").last?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty { return value }
        }
        return nil
    }

    /// Launch a package's own launcher activity. `monkey` is used rather than `am start` because
    /// it resolves the launch intent itself — we would otherwise have to parse it out of dumpsys.
    static func launch(_ serial: String, package: String) throws {
        _ = try shell(serial,
                      "monkey -p \(shellQuote(package)) -c android.intent.category.LAUNCHER 1")
    }

    /// Launch onto a specific display — monkey cannot target one, so resolve the launcher
    /// activity and use `am start --display`. Display 0 falls back to the plain launch.
    static func launch(_ serial: String, package: String, displayId: Int32) throws {
        guard displayId != 0 else { return try launch(serial, package: package) }
        let out = try shell(serial, "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "
                            + shellQuote(package) + " | tail -1")
        let component = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard component.contains("/") else {
            throw AdbError.failed("no launcher activity found for \(package)")
        }
        _ = try shell(serial, "am start --display \(displayId) -n \(shellQuote(component))")
    }

    /// The on-device path of a package's APK — the base split, preferred over config splits — for
    /// pulling it back to the Mac. `pm path` lists one `package:/path` line per split.
    static func apkPath(_ serial: String, package: String) throws -> String {
        let out = try shell(serial, "pm path \(shellQuote(package))")
        let paths = out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("package:") }
            .map { String($0.dropFirst("package:".count)) }
        guard let base = paths.first(where: { $0.hasSuffix("base.apk") }) ?? paths.first else {
            throw AdbError.failed("no APK path for \(package)")
        }
        return base
    }

    static func forceStop(_ serial: String, package: String) throws {
        _ = try shell(serial, "am force-stop \(shellQuote(package))")
    }

    static func uninstall(_ serial: String, package: String) throws {
        let out = try shell(serial, "pm uninstall \(shellQuote(package))")
        guard out.contains("Success") else {
            throw AdbError.failed("uninstall \(package): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Install an APK: push it to a staging path, `pm install -r`, then clean up. This is what
    /// `adb install` does, and doing it ourselves keeps everything on the one socket protocol.
    static func install(_ serial: String, apkPath: String) throws {
        let staged = "/data/local/tmp/rplayhub-install-\(UUID().uuidString.prefix(8)).apk"
        try push(serial, localPath: apkPath, remotePath: staged, mode: 0o644)
        defer { _ = try? shell(serial, "rm -f \(staged)") }
        let out = try shell(serial, "pm install -r -t \(staged)")
        guard out.contains("Success") else {
            throw AdbError.failed(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - helpers

    /// Undo the backslash escaping toybox's `ls` applies to names.
    private static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var escaped = false
        for ch in s {
            if escaped { out.append(ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else { out.append(ch) }
        }
        return out
    }

    /// Single-quote for the device's shell. Anything can appear in a file name, and an unquoted
    /// path with a space in it silently lists the wrong thing.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
