//
//  AppIcons.swift
//  Launcher icons for the Apps tab, read out of the APK on the device.
//
//  Best effort by design. There is no adb command that hands over an app's icon, and the only
//  fully general route is to resolve `android:icon` through the APK's resources.arsc — a binary
//  format we do not parse. What we do instead is exploit the naming convention: Android's own
//  project template calls the launcher icon `ic_launcher`, and the tooling puts it under
//  `res/mipmap-<density>/`. That holds for most apps built from the template.
//
//  It does NOT hold for apps whose resource names were obfuscated by R8 resource shrinking —
//  Google's own apps ship as `res/js.png` and friends, with the names gone. Those return nil and
//  the list falls back to showing no icon, which is why every call site treats an icon as
//  optional rather than as something it can wait for.
//
//  Extraction runs entirely on the device: `unzip -p` streams one entry out of the APK, so a
//  200 MB app costs us the size of a PNG rather than a full pull.
//

import AppKit

enum AppIcons {
    /// package -> icon, with a recorded nil meaning "looked, found nothing" so a miss is not
    /// retried on every scroll. Main queue only.
    private static var cache: [String: NSImage?] = [:]
    private static let queue = DispatchQueue(label: "ai.rplay.hub.appicons", qos: .utility)

    /// Densities worth preferring, best first. `nodpi` and unqualified come last: they are
    /// usually the adaptive-icon fallbacks rather than the crisp raster.
    private static let densities = ["xxxhdpi", "xxhdpi", "xhdpi", "hdpi", "mdpi", "ldpi"]

    static func icon(serial: String, package: String,
                     completion: @escaping (NSImage?) -> Void) {
        let key = "\(serial)|\(package)"
        if let hit = cache[key] { completion(hit); return }
        queue.async {
            let image = fetch(serial: serial, package: package)
            DispatchQueue.main.async {
                cache[key] = image
                completion(image)
            }
        }
    }

    static func forget() { cache.removeAll() }

    // MARK: - device side

    private static func fetch(serial: String, package: String) -> NSImage? {
        // Split APKs put density resources in their own file, so every path is a candidate.
        guard let paths = try? Adb.shell(serial, "pm path \(package)") else { return nil }
        let apks = paths
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("package:") }
            .map { String($0.dropFirst("package:".count)) }
        guard !apks.isEmpty else { return nil }

        for apk in apks {
            guard let listing = try? Adb.shell(serial, "unzip -l '\(apk)'") else { continue }
            let entries = listing
                .components(separatedBy: "\n")
                .compactMap { line -> String? in
                    // "   size  date  time   name" — the name is the remainder after the time,
                    // and may contain spaces, so take everything past the 4th column start.
                    let parts = line.split(separator: " ", maxSplits: 3,
                                           omittingEmptySubsequences: true)
                    guard parts.count == 4 else { return nil }
                    let name = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
                    return name.isEmpty ? nil : name
                }
            guard let entry = pick(from: entries) else { continue }
            guard let data = try? Adb.shellData(serial, "unzip -p '\(apk)' '\(entry)'"),
                  !data.isEmpty, let image = NSImage(data: data) else { continue }
            return image
        }
        return nil
    }

    /// Choose the launcher icon among an APK's entries: raster only, mipmap before drawable,
    /// densest first. Prefers an `ic_launcher`-named file, but falls back to any raster in a
    /// `mipmap` directory — Android reserves those folders for launcher icons, so this catches
    /// the many apps whose icon resource was renamed by R8 and no longer says "ic_launcher".
    static func pick(from entries: [String]) -> String? {
        func rasters(where matches: (String) -> Bool) -> [String] {
            entries.filter { name in
                let lower = name.lowercased()
                guard lower.hasSuffix(".png") || lower.hasSuffix(".webp") else { return false }
                // The two halves of an adaptive icon are not the icon; the background alone is a
                // coloured square. Keep foreground only as a last resort, handled by the sort.
                guard !lower.contains("_background") else { return false }
                return matches(lower)
            }
        }
        var candidates = rasters { $0.contains("ic_launcher") || $0.contains("ic_app_icon") }
        if candidates.isEmpty { candidates = rasters { $0.contains("/mipmap") } }
        guard !candidates.isEmpty else { return nil }

        func score(_ name: String) -> Int {
            let lower = name.lowercased()
            var s = 0
            if lower.contains("/mipmap") { s += 1000 }
            if let i = densities.firstIndex(where: { lower.contains("-\($0)") }) {
                s += (densities.count - i) * 100
            }
            if lower.contains("_round") { s -= 10 }          // prefer the square original
            if lower.contains("_foreground") { s -= 50 }     // only if nothing better exists
            return s
        }
        return candidates.max { score($0) < score($1) }
    }
}
