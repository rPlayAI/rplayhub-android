//
//  AvdCreator.swift
//  Creating an AVD by writing its config files directly — no avdmanager, no JDK, no Studio.
//
//  An AVD is two files: a pointer `<name>.ini` in the AVD home, and a `config.ini` inside
//  `<name>.avd/` holding the hardware description. The emulator fills everything it is not told
//  into `hardware-qemu.ini` on first boot, so only the keys that actually decide the machine are
//  written here. That is deliberate: every key we emit is one we can be held responsible for.
//
//  `hw.keyboard=yes` is the load-bearing one. avdmanager inherits `no` from the phone device
//  profile, and with `no` the engine creates no keyboard device in the guest — every key we send
//  over gRPC (and the console's own `event send`) is dropped while touch still works. Studio's
//  Device Manager writes `yes`, which is why the bug never shows up there. See doc/EMULATOR-HOST.md.
//

import Foundation

/// A screen and form factor to build an AVD around. Deliberately a short list: rPlayHub is not
/// rebuilding Studio's device catalogue, it is making one good VM easy.
struct DeviceProfile: Equatable {
    let id: String                  // hw.device.name, e.g. "pixel_9"
    let name: String                // what the picker shows
    let manufacturer: String
    let width: Int                  // native pixels
    let height: Int
    let density: Int                // dpi bucket
    /// RAM in MB, and the Dalvik heap that goes with it.
    let ramMB: Int
    let heapMB: Int

    static let phone = DeviceProfile(id: "pixel_9", name: "Phone (Pixel 9)", manufacturer: "Google",
                                     width: 1080, height: 2424, density: 420, ramMB: 2048, heapMB: 228)
    static let largePhone = DeviceProfile(id: "pixel_9_pro_xl", name: "Large phone (Pixel 9 Pro XL)",
                                          manufacturer: "Google", width: 1344, height: 2992,
                                          density: 480, ramMB: 3072, heapMB: 256)
    static let tablet = DeviceProfile(id: "pixel_tablet", name: "Tablet (Pixel Tablet)",
                                      manufacturer: "Google", width: 2560, height: 1600,
                                      density: 320, ramMB: 4096, heapMB: 384)

    static let all: [DeviceProfile] = [.phone, .largePhone, .tablet]
}

enum AvdCreator {
    enum Failure: Error, CustomStringConvertible {
        case nameTaken(String)
        case badName(String)
        case missingImage(String)
        case write(String)

        var description: String {
            switch self {
            case .nameTaken(let n):   return "An AVD called \"\(n)\" already exists."
            case .badName(let n):     return "\"\(n)\" is not a usable AVD name — use letters, digits, dots, dashes or underscores."
            case .missingImage(let p): return "The system image is not installed at \(p)."
            case .write(let m):       return "Could not write the AVD: \(m)"
            }
        }
    }

    /// The emulator accepts a narrow set of characters in an AVD name; anything else and `-avd`
    /// cannot find it again.
    static func sanitize(_ proposed: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let mapped = proposed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let name = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return name.isEmpty ? "Android_VM" : name
    }

    /// A name that is not taken yet, by appending _2, _3…
    static func availableName(basedOn proposed: String) -> String {
        let base = sanitize(proposed)
        let home = AndroidSdk.avdHome
        var candidate = base, n = 2
        while FileManager.default.fileExists(atPath: home.appendingPathComponent("\(candidate).ini").path) {
            candidate = "\(base)_\(n)"
            n += 1
        }
        return candidate
    }

    /// Create an AVD for an installed system image.
    ///
    /// - Parameters:
    ///   - name: the AVD name, as `-avd` will take it.
    ///   - imagePath: the sdkmanager package path, `system-images;android-35;google_apis;arm64-v8a`.
    ///   - sdkRoot: the SDK the image is installed under.
    @discardableResult
    static func create(name: String, imagePath: String, profile: DeviceProfile,
                       sdkRoot: URL, dataSizeGB: Int = 8) throws -> Avd {
        let fm = FileManager.default
        guard name == sanitize(name), !name.isEmpty else { throw Failure.badName(name) }

        let home = AndroidSdk.avdHome
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let pointer = home.appendingPathComponent("\(name).ini")
        let directory = home.appendingPathComponent("\(name).avd", isDirectory: true)
        guard !fm.fileExists(atPath: pointer.path), !fm.fileExists(atPath: directory.path) else {
            throw Failure.nameTaken(name)
        }

        // system-images;android-35;google_apis;arm64-v8a  ->  system-images/android-35/google_apis/arm64-v8a
        let segments = imagePath.split(separator: ";").map(String.init)
        let relativeImage = segments.joined(separator: "/") + "/"
        let imageDirectory = sdkRoot.appendingPathComponent(relativeImage, isDirectory: true)
        guard fm.fileExists(atPath: imageDirectory.path) else {
            throw Failure.missingImage(imageDirectory.path)
        }
        let api = segments.first(where: { $0.hasPrefix("android-") }) ?? "android-35"
        let tag = segments.count >= 3 ? segments[2] : "google_apis"
        let abi = segments.last ?? "arm64-v8a"
        let playStore = tag.contains("playstore")

        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // Only the keys that decide the machine. The emulator defaults the rest on first boot.
        var config: [String: String] = [
            "avd.ini.encoding": "UTF-8",
            "AvdId": name,
            "avd.id": name,
            "avd.name": name,
            "avd.ini.displayname": name.replacingOccurrences(of: "_", with: " "),
            "abi.type": abi,
            "tag.id": tag,
            "tag.ids": tag,
            "tag.display": tag == "google_apis" ? "Google APIs" : tag,
            "image.sysdir.1": relativeImage,
            "target": api,
            "PlayStore.enabled": playStore ? "yes" : "no",

            "hw.cpu.arch": abi.hasPrefix("arm") ? "arm64" : "x86_64",
            "hw.cpu.ncore": "4",
            "hw.ramSize": "\(profile.ramMB)",
            "vm.heapSize": "\(profile.heapMB)",

            "hw.device.name": profile.id,
            "hw.device.manufacturer": profile.manufacturer,
            "hw.lcd.width": "\(profile.width)",
            "hw.lcd.height": "\(profile.height)",
            "hw.lcd.density": "\(profile.density)",
            "hw.lcd.depth": "32",
            "hw.initialOrientation": profile.width > profile.height ? "landscape" : "portrait",

            // The one that matters: without a keyboard device every key we inject is dropped.
            "hw.keyboard": "yes",
            "hw.keyboard.charmap": "qwerty2",
            "hw.mainKeys": "no",
            "hw.dPad": "no",
            "hw.trackBall": "no",
            "hw.screen": "multi-touch",

            "hw.audioInput": "yes",
            "hw.audioOutput": "yes",
            "hw.battery": "yes",
            "hw.accelerometer": "yes",
            "hw.gyroscope": "yes",
            "hw.gps": "yes",
            "hw.sensors.orientation": "yes",
            "hw.sensors.proximity": "yes",
            "hw.sensors.light": "yes",

            "hw.camera.back": "emulated",
            "hw.camera.front": "emulated",

            "hw.gpu.enabled": "yes",
            "hw.gpu.mode": "auto",

            "disk.dataPartition.size": "\(dataSizeGB)G",
            "hw.sdCard": "yes",
            "sdcard.size": "512 MB",
            "hw.useext4": "yes",
            "showDeviceFrame": "no",
        ]
        config["fastboot.forceColdBoot"] = "no"

        let body = config.keys.sorted().map { "\($0)=\(config[$0]!)" }.joined(separator: "\n") + "\n"
        do {
            try body.write(to: directory.appendingPathComponent("config.ini"),
                           atomically: true, encoding: .utf8)
            let pointerBody = """
                avd.ini.encoding=UTF-8
                path=\(directory.path)
                path.rel=avd/\(name).avd
                target=\(api)

                """
            try pointerBody.write(to: pointer, atomically: true, encoding: .utf8)
        } catch {
            try? fm.removeItem(at: directory)
            try? fm.removeItem(at: pointer)
            throw Failure.write(error.localizedDescription)
        }

        AppBuild.log("avd: created \(name) (\(api), \(tag), \(abi)) at \(directory.path)")
        return Avd(name: name, displayName: config["avd.ini.displayname"] ?? name,
                   device: profile.id, apiLevel: Int(api.dropFirst("android-".count).prefix { $0.isNumber }),
                   abi: abi, directory: directory)
    }
}
