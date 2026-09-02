//
//  EmulatorLauncher.swift
//  "+ Emulator": list the user's AVDs and start one the way Android Studio's embedded emulator
//  does — headless, with gRPC on — so the app can host it (EmulatorSession) while adb keeps its
//  own access to the same instance.
//
//  The emulator is the user's SDK install. It is never bundled (the SDK license forbids
//  redistributing it), and a sandboxed build cannot exec it, so this exists in the DMG build only;
//  the store build never shows the entry (AppBuild.emulatorLaunchEnabled).
//

import Foundation

// MARK: - the SDK

/// The user's Android SDK, as far as launching is concerned: where `emulator/emulator` is.
enum AndroidSdk {
    /// A root the user pointed at (Locate Android SDK…), ahead of every automatic guess.
    static let rootDefaultsKey = "AndroidSdkRoot"

    /// The first candidate that actually has the emulator installed.
    static var root: URL? { candidates.first { hasEmulator($0) } }

    static var emulatorBinary: URL? { root?.appendingPathComponent("emulator/emulator") }

    static func hasEmulator(_ root: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("emulator/emulator").path)
    }

    /// The chosen root, the environment's, then the usual installs — and whichever SDK the adb
    /// we found lives in, since `platform-tools/adb` names its SDK.
    private static var candidates: [URL] {
        var list: [URL] = []
        if let chosen = UserDefaults.standard.string(forKey: rootDefaultsKey), !chosen.isEmpty {
            list.append(URL(fileURLWithPath: chosen))
        }
        let env = ProcessInfo.processInfo.environment
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let value = env[key], !value.isEmpty { list.append(URL(fileURLWithPath: value)) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        list.append(home.appendingPathComponent("Library/Android/sdk"))
        list.append(URL(fileURLWithPath: "/opt/homebrew/share/android-commandlinetools"))
        if let adb = Adb.binaryPath(), adb.hasSuffix("/platform-tools/adb") {
            list.append(URL(fileURLWithPath: adb).deletingLastPathComponent().deletingLastPathComponent())
        }
        return list
    }

    /// Where AVDs live, resolved in the emulator's own order so we list what it would run.
    static var avdHome: URL {
        let env = ProcessInfo.processInfo.environment
        if let v = env["ANDROID_AVD_HOME"], !v.isEmpty { return URL(fileURLWithPath: v) }
        if let v = env["ANDROID_USER_HOME"], !v.isEmpty {
            return URL(fileURLWithPath: v).appendingPathComponent("avd")
        }
        if let v = env["ANDROID_SDK_HOME"], !v.isEmpty {
            return URL(fileURLWithPath: v).appendingPathComponent(".android/avd")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/avd")
    }

    /// `key=value` lines. The AVD's `<name>.ini`, its `config.ini` and the emulator's discovery
    /// files all use this shape.
    static func iniValues(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, !kv[0].hasPrefix("#") else { continue }
            values[kv[0]] = kv[1]
        }
        return values
    }
}

// MARK: - an AVD

struct Avd: Equatable {
    /// What `-avd` takes: the `<name>.ini` basename in the AVD home.
    let name: String
    /// `avd.ini.displayname` when set — "Pixel 9" style — else the name with its underscores
    /// read as spaces.
    let displayName: String
    /// `hw.device.name`, e.g. `pixel_9`.
    let device: String?
    /// From `image.sysdir.1` (`system-images/android-35/…`), else `target`.
    let apiLevel: Int?
    let abi: String?
    let directory: URL

    /// "Pixel 9 · API 35 · arm64-v8a" — what a person needs to tell two AVDs apart.
    var subtitle: String {
        var parts: [String] = []
        if let device, !device.isEmpty {
            parts.append(device.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        if let apiLevel { parts.append("API \(apiLevel)") }
        if let abi, !abi.isEmpty { parts.append(abi) }
        return parts.joined(separator: " · ")
    }

    /// Every AVD in the AVD home, by display name. One `<name>.ini` points at the `<name>.avd`
    /// directory holding the `config.ini` the emulator reads.
    static func all() -> [Avd] {
        let home = AndroidSdk.avdHome
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: home.path)
        else { return [] }
        var avds: [Avd] = []
        for file in names where file.hasSuffix(".ini") {
            let name = String(file.dropLast(".ini".count))
            let pointer = AndroidSdk.iniValues(at: home.appendingPathComponent(file))
            let directory = pointer["path"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent("\(name).avd")
            let config = AndroidSdk.iniValues(at: directory.appendingPathComponent("config.ini"))
            guard !config.isEmpty else { continue }       // a pointer with nothing behind it
            var api: Int?
            for source in [config["image.sysdir.1"], config["target"], pointer["target"]] {
                guard let source, api == nil else { continue }
                if let range = source.range(of: "android-") {
                    api = Int(source[range.upperBound...].prefix { $0.isNumber })
                }
            }
            let display = config["avd.ini.displayname"].flatMap { $0.isEmpty ? nil : $0 }
                ?? name.replacingOccurrences(of: "_", with: " ")
            avds.append(Avd(name: config["AvdId"] ?? name, displayName: display,
                            device: config["hw.device.name"], apiLevel: api,
                            abi: config["abi.type"], directory: directory))
        }
        return avds.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

// MARK: - launching

/// Starts emulators headless with gRPC and remembers the ones it started, so they can be shut
/// down (from the sidebar, and when the app quits — a headless engine has no window of its own
/// to close, so it must not outlive the app that is its only face).
final class EmulatorLauncher {
    static let shared = EmulatorLauncher()

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The engine is alive and healthy, adb just has not seen it yet. Never fatal.
    struct StillBooting: Error, CustomStringConvertible {
        let serial: String
        var description: String {
            "\(serial) is still booting. It will appear in the sidebar when Android has started."
        }
    }

    /// One emulator this launcher started. `serial` is what adb calls it, fixed by the console
    /// port we picked before starting it.
    final class Launch {
        let avd: Avd
        let consolePort: Int
        let grpcPort: Int
        let process = Process()
        let log: URL
        var serial: String { "emulator-\(consolePort)" }
        /// Set once the launch has been reported (success or failure) — the termination handler
        /// reports a death only until then.
        var reported = false

        init(avd: Avd, consolePort: Int, grpcPort: Int, log: URL) {
            self.avd = avd
            self.consolePort = consolePort
            self.grpcPort = grpcPort
            self.log = log
        }
    }

    /// Emulators this launcher started that are still running, by serial.
    private(set) var launches: [String: Launch] = [:]
    /// Progress for the sidebar's "starting…" row: the serial and a short phrase.
    var onPhase: ((String, String) -> Void)?

    private let queue = DispatchQueue(label: "ai.rplay.rplayhub.emulator-launch", qos: .userInitiated)

    /// The engine up and its discovery file written: normally a few seconds.
    private let engineTimeout: TimeInterval = 90
    /// adb listing the instance as `device`. A FIRST boot of a freshly downloaded system image
    /// builds its data partition and can take many minutes — the engine itself says "may take up
    /// to two minutes, or more" — so this is generous.
    private let bootTimeout: TimeInterval = 900

    /// The AVD names of every emulator currently running on this Mac (ours or not), from the
    /// discovery files the emulator writes, with their adb serials — so the picker can mark them.
    static func runningAvds() -> [String: String] {
        var running: [String: String] = [:]
        for dir in discoveryDirs {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
            else { continue }
            for name in names where name.hasPrefix("pid_") && name.hasSuffix(".ini") {
                let values = AndroidSdk.iniValues(at: dir.appendingPathComponent(name))
                guard let pidText = name.dropFirst("pid_".count).split(separator: ".").first,
                      let pid = Int32(pidText), kill(pid, 0) == 0 || errno == EPERM,   // still alive
                      let avd = values["avd.name"] ?? values["avd.id"],
                      let port = values["port.serial"] else { continue }
                running[avd] = "emulator-\(port)"
            }
        }
        return running
    }

    /// Start `avd`. The completion runs on the main queue with the adb serial once adb lists the
    /// instance as a device — hosting can begin then. Returns the serial it will have, so the
    /// sidebar can show the row straight away.
    @discardableResult
    func launch(_ avd: Avd, completion: @escaping (Result<String, Error>) -> Void) -> String? {
        guard let binary = AndroidSdk.emulatorBinary, let root = AndroidSdk.root else {
            completion(.failure(Failure(description: "The Android SDK's emulator was not found. Use Locate Android SDK… to point at an SDK that has it installed.")))
            return nil
        }
        guard let console = Self.freeConsolePort(), let grpc = Self.freePort(from: 8554) else {
            completion(.failure(Failure(description: "No free emulator port (5554–5682) is left.")))
            return nil
        }
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/rPlayHubAndroid", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let launch = Launch(avd: avd, consolePort: console, grpcPort: grpc,
                            log: logs.appendingPathComponent("emulator-\(avd.name).log"))
        launches[launch.serial] = launch

        Self.ensureKeyboard(avd)
        let process = launch.process
        process.executableURL = binary
        // Studio's embedded recipe: no window, gRPC on a known port (localhost allow-list, no
        // token), the console port fixed so the serial is known before the engine is up.
        var arguments = ["-avd", avd.name, "-port", String(console),
                         "-no-window", "-no-snapshot", "-grpc", String(grpc)]
        // `auto` with no window resolves to software rendering (swangle + lavapipe), which is
        // what the engine does for a headless launch. `host` — ANGLE over Metal here — is what
        // the embedded emulator gets, so ask for it unless the AVD pins a mode of its own.
        let gpuMode = AndroidSdk.iniValues(at: avd.directory.appendingPathComponent("config.ini"))["hw.gpu.mode"] ?? "auto"
        if gpuMode == "auto" { arguments += ["-gpu", "host"] }
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_SDK_ROOT"] = root.path
        env["ANDROID_HOME"] = root.path
        for key in env.keys where key.hasPrefix("RPLAYHUB_") { env[key] = nil }
        process.environment = env
        FileManager.default.createFile(atPath: launch.log.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: launch.log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                self.launches[launch.serial] = nil
                AppBuild.log("emulator: \(launch.serial) (\(avd.name)) exited \(p.terminationStatus)")
                if !launch.reported {
                    launch.reported = true
                    completion(.failure(Failure(description: "The emulator exited (\(p.terminationStatus)) while starting.\n\(self.tail(of: launch.log))")))
                }
            }
        }
        do {
            try process.run()
        } catch {
            launches[launch.serial] = nil
            completion(.failure(Failure(description: "Could not run \(binary.path): \(error.localizedDescription)")))
            return nil
        }
        AppBuild.log("emulator: launching \(avd.name) as \(launch.serial), gRPC :\(grpc), pid \(process.processIdentifier)")
        onPhase?(launch.serial, "starting the engine…")

        queue.async { [weak self] in
            guard let self else { return }
            let outcome = self.waitUntilReady(launch)
            DispatchQueue.main.async {
                guard !launch.reported else { return }
                launch.reported = true
                // Only tear the engine down when it actually failed; a slow first boot is not a
                // failure, and the emulator keeps running.
                if case .failure(let error) = outcome, !(error is StillBooting), process.isRunning {
                    process.terminate()
                }
                completion(outcome)
            }
        }
        return launch.serial
    }

    /// Block until the engine has written its discovery file and opened gRPC, then until adb
    /// lists the instance as `device`. Runs on the launcher's queue.
    private func waitUntilReady(_ launch: Launch) -> Result<String, Error> {
        let started = Date()
        var grpcUp = false
        while Date().timeIntervalSince(started) < engineTimeout {
            guard launch.process.isRunning else {
                return .failure(Failure(description: "The emulator exited while starting.\n\(tail(of: launch.log))"))
            }
            if Self.discovered(launch), Self.canConnect(port: launch.grpcPort) {
                grpcUp = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard grpcUp else {
            return .failure(Failure(description: "The emulator did not open its gRPC port :\(launch.grpcPort) in time.\n\(tail(of: launch.log))"))
        }
        AppBuild.log("emulator: \(launch.serial) gRPC :\(launch.grpcPort) is up; waiting for adb")
        DispatchQueue.main.async { [self] in onPhase?(launch.serial, "booting Android…") }

        let booting = Date()
        while Date().timeIntervalSince(booting) < bootTimeout {
            guard launch.process.isRunning else {
                return .failure(Failure(description: "The emulator exited while booting.\n\(tail(of: launch.log))"))
            }
            if let devices = try? Adb.devices(),
               devices.contains(where: { $0.serial == launch.serial && $0.isReady }) {
                AppBuild.log("emulator: \(launch.serial) is on adb")
                return .success(launch.serial)
            }
            Thread.sleep(forTimeInterval: 1)
        }
        // Still booting, not broken. Leave it running and say so: the sidebar polls adb, so it
        // appears by itself the moment it finishes. Killing it here threw away a VM the user had
        // just waited through a 2 GB download for.
        return .failure(StillBooting(serial: launch.serial))
    }

    /// Shut an emulator down: ours by SIGTERM (the engine exits cleanly on it), any other through
    /// its console (`adb emu kill`).
    func shutDown(serial: String) {
        if let launch = launches[serial] {
            AppBuild.log("emulator: shutting down \(serial)")
            launch.reported = true
            launch.process.terminate()
            return
        }
        guard let adb = Adb.binaryPath() else { return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: adb)
            p.arguments = ["-s", serial, "emu", "kill"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            AppBuild.log("emulator: adb emu kill \(serial) → \(p.terminationStatus)")
        }
    }

    /// On quit: every emulator we started goes down with us, and we give them a moment to exit
    /// so their discovery files are cleaned up rather than left for the next launch to skip.
    func shutDownAll() {
        let running = launches.values.filter { $0.process.isRunning }
        guard !running.isEmpty else { return }
        for launch in running {
            launch.reported = true
            launch.process.terminate()
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, running.contains(where: { $0.process.isRunning }) {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: - helpers

    /// `hw.keyboard=yes`, or every key we send is dropped: with `no` the engine creates no
    /// keyboard input device in the guest, so `sendKey` — and the console's `event send` — have
    /// nowhere to go (only touch arrives). An AVD made by `avdmanager` inherits `no` from the
    /// phone's device profile; Studio's Device Manager writes `yes` for the AVDs it creates,
    /// which is why this never shows up there. Written once into the AVD's config.ini, the same
    /// file Studio and the engine itself rewrite.
    private static func ensureKeyboard(_ avd: Avd) {
        let url = avd.directory.appendingPathComponent("config.ini")
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let values = AndroidSdk.iniValues(at: url)
        guard values["hw.keyboard"] != "yes" else { return }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("hw.keyboard=") }) {
            lines[i] = "hw.keyboard=yes"
        } else {
            if lines.last == "" { lines.removeLast() }
            lines.append("hw.keyboard=yes")
        }
        text = lines.joined(separator: "\n") + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            AppBuild.log("emulator: set hw.keyboard=yes in \(url.path) (keys need a keyboard device)")
        } catch {
            AppBuild.log("emulator: could not enable hw.keyboard in \(url.path): \(error)")
        }
    }

    private static var discoveryDirs: [URL] {
        var dirs: [URL] = []
        if let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] {
            dirs.append(URL(fileURLWithPath: runtime).appendingPathComponent("avd/running"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        dirs.append(home.appendingPathComponent("Library/Caches/TemporaryItems/avd/running"))
        dirs.append(home.appendingPathComponent(".android/avd/running"))
        return dirs
    }

    /// The discovery file for this launch — by pid (the `emulator` launcher execs the engine in
    /// place, so the pid is ours) or, failing that, by the console port we chose.
    private static func discovered(_ launch: Launch) -> Bool {
        let pid = launch.process.processIdentifier
        for dir in discoveryDirs {
            let byPid = dir.appendingPathComponent("pid_\(pid).ini")
            if AndroidSdk.iniValues(at: byPid)["grpc.port"] != nil { return true }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
            else { continue }
            for name in names where name.hasPrefix("pid_") && name.hasSuffix(".ini") {
                let values = AndroidSdk.iniValues(at: dir.appendingPathComponent(name))
                if values["port.serial"] == String(launch.consolePort), values["grpc.port"] != nil {
                    return true
                }
            }
        }
        return false
    }

    /// The emulator's console port must be even, in 5554–5682, with the adb port beside it free.
    private static func freeConsolePort() -> Int? {
        for port in stride(from: 5554, through: 5682, by: 2)
        where isFree(port: port) && isFree(port: port + 1) {
            return port
        }
        return nil
    }

    private static func freePort(from start: Int) -> Int? {
        for port in start ..< start + 200 where isFree(port: port) { return port }
        return nil
    }

    /// Bind test on loopback: a port a running emulator (or anything) holds fails to bind.
    private static func isFree(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    private static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }

    /// The last lines of the engine's log — what a failure alert can usefully show.
    private func tail(of log: URL, lines: Int = 8) -> String {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        let all = text.split(separator: "\n", omittingEmptySubsequences: true)
        return all.suffix(lines).joined(separator: "\n")
    }
}
