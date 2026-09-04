//
//  DesktopShortcut.swift
//  An Android app as a double-clickable icon on the Mac's Desktop.
//
//  The shortcut is a tiny .app bundle whose executable is a shell script that opens a
//  `rplayhub://fuse?package=…&device=…` URL; this app registers the `rplayhub` scheme and
//  answers by opening that app in a window of its own on that device (starting the app and the
//  session if they are not running). The bundle carries the Android app's own launcher icon,
//  so the Desktop shows a YouTube icon, not a script icon. Written by us, never quarantined,
//  so Gatekeeper has nothing to say about it.
//

import AppKit

enum DesktopShortcut {
    static let scheme = "rplayhub"

    static func url(package: String, serial: String?) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "fuse"
        c.queryItems = [URLQueryItem(name: "package", value: package)]
            + (serial.map { [URLQueryItem(name: "device", value: $0)] } ?? [])
        return c.url!
    }

    /// Write `<label> on <device>.app` to the Desktop and return its URL.
    static func write(package: String, label: String, deviceName: String, serial: String?,
                      icon: NSImage?) throws -> URL {
        let fm = FileManager.default
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let safe = "\(label) on \(deviceName)".replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let bundle = desktop.appendingPathComponent("\(safe).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        if fm.fileExists(atPath: bundle.path) { try fm.removeItem(at: bundle) }
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let target = url(package: package, serial: serial).absoluteString
        let script = "#!/bin/sh\nexec /usr/bin/open \"\(target)\"\n"
        let exe = macos.appendingPathComponent("launch")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let id = "ai.rplay.rplayhub.shortcut." + package.replacingOccurrences(of: "_", with: "-")
        var plist: [String: Any] = [
            "CFBundleName": label,
            "CFBundleDisplayName": "\(label) on \(deviceName)",
            "CFBundleIdentifier": id,
            "CFBundleExecutable": "launch",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "LSUIElement": true,          // no Dock bounce: it only opens a URL and exits
        ]
        if let icon, (try? writeIcns(icon, to: resources.appendingPathComponent("icon.icns"))) != nil {
            plist["CFBundleIconFile"] = "icon"
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        // Finder caches icons by bundle; touching the bundle makes it look again.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: bundle.path)
        return bundle
    }

    /// An .icns from an image, through an iconset and `iconutil` — the only supported route.
    private static func writeIcns(_ image: NSImage, to url: URL) throws {
        let fm = FileManager.default
        let set = fm.temporaryDirectory.appendingPathComponent("rplayhub-\(UUID().uuidString).iconset", isDirectory: true)
        try fm.createDirectory(at: set, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: set) }
        for size in [16, 32, 64, 128, 256, 512] {
            for scale in [1, 2] where size * scale <= 1024 {
                let px = size * scale
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.current?.imageInterpolation = .high
                image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero,
                           operation: .copy, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                try png.write(to: set.appendingPathComponent(name))
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", set.path, "-o", url.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "DesktopShortcut", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
        }
    }
}
