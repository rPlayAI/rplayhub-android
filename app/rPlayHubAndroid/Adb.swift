//
//  Adb.swift
//  A client for the adb server's host protocol, spoken directly on 127.0.0.1:5037.
//
//  We talk to the adb SERVER rather than spawning the `adb` binary. Both work, but the server
//  protocol is what gives us a long-lived socket per shell command — which the agent needs, since
//  its stdout is where its log and its exit code come from and it runs for the whole session.
//  Spawning a process per command would also put an NSTask lifecycle between us and every failure.
//
//  Reimplementing adb's USB transport is deliberately NOT on the table, which is the one place
//  this project differs in spirit from ~/rplay-hub. There, usbmuxd was worth replacing because
//  Apple's daemon is undocumented and in the way. Here adb IS the documented interface, Studio
//  itself goes through it, and the device end of the link is the part we care about.
//
//  Wire format: every request is a 4-hex-digit length followed by the request text. The reply is
//  "OKAY" or "FAIL" + a 4-hex-digit length + a message. A socket that has been switched to a
//  device with `host:transport:<serial>` stays bound to that device for its remaining life.
//

import Foundation

struct AdbDevice: Equatable {
    let serial: String
    /// "device", "unauthorized", "offline", "recovery"…
    let state: String
    let model: String?
    let product: String?
    let transportId: String?

    var isReady: Bool { state == "device" }

    /// An Android Emulator instance (adb names them emulator-<console port>). It is a device
    /// like any other to adb and the agent; only the sidebar treats it as its own kind.
    var isEmulator: Bool { serial.hasPrefix("emulator-") }

    /// What the sidebar shows. `model` comes back with underscores for spaces. An emulator's
    /// model is the meaningless "sdk_gphone64_arm64"; the sidebar replaces this with the AVD's
    /// name once it has asked the device for it.
    var displayName: String {
        if isEmulator { return "Android Emulator" }
        guard let model, !model.isEmpty else { return serial }
        return model.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: - File Provider domain identity

    /// A serial as a File Provider domain identifier. The system forbids '/' and ':' there, and
    /// a network device's serial is "host:port" — so those (and '%', to keep it reversible) are
    /// percent-encoded. The extension turns it back with `serial(fromDomainIdentifier:)`.
    static func domainIdentifier(for serial: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return serial.addingPercentEncoding(withAllowedCharacters: allowed) ?? serial
    }

    static func serial(fromDomainIdentifier id: String) -> String {
        id.removingPercentEncoding ?? id
    }
}

enum AdbError: Error, CustomStringConvertible {
    case noServer
    case failed(String)
    case protocolError(String)

    var description: String {
        switch self {
        case .noServer:            return "no adb server on 127.0.0.1:5037 — run `adb start-server`"
        case .failed(let m):       return "adb: \(m)"
        case .protocolError(let m): return "adb protocol: \(m)"
        }
    }
}

enum Adb {
    static let serverHost = "127.0.0.1"
    static let serverPort: UInt16 = 5037

    // MARK: - request plumbing

    private static func openServer(timeout: TimeInterval = 5) throws -> TCPSocket {
        let s = TCPSocket(host: serverHost, port: serverPort)
        do { try s.connect(timeout: timeout) } catch { throw AdbError.noServer }
        return s
    }

    /// Send one request and read its OKAY/FAIL. Leaves the socket open for whatever follows.
    static func send(_ socket: TCPSocket, _ request: String) throws {
        let body = Data(request.utf8)
        let header = String(format: "%04x", body.count)
        try socket.writeAll(Data(header.utf8) + body)
        try expectOkay(socket)
    }

    private static func expectOkay(_ socket: TCPSocket) throws {
        let status = try socket.readFully(4)
        switch String(decoding: status, as: UTF8.self) {
        case "OKAY":
            return
        case "FAIL":
            let len = Int(String(decoding: try socket.readFully(4), as: UTF8.self), radix: 16) ?? 0
            let msg = len > 0 ? String(decoding: try socket.readFully(len), as: UTF8.self) : "unknown"
            throw AdbError.failed(msg)
        case let other:
            throw AdbError.protocolError("expected OKAY, got '\(other)'")
        }
    }

    /// Read to EOF — how the host protocol delimits a payload it did not length-prefix.
    private static func readToEnd(_ socket: TCPSocket) throws -> Data {
        var out = Data()
        while true {
            do {
                guard let chunk = try socket.read() else { continue }
                out.append(chunk)
            } catch {
                return out          // EOF is the terminator, not a failure
            }
        }
    }

    /// A host-scoped request whose reply is a 4-hex-length-prefixed string.
    private static func hostRequest(_ request: String) throws -> String {
        let s = try openServer()
        defer { s.shutdownAndClose() }
        try send(s, request)
        let len = Int(String(decoding: try s.readFully(4), as: UTF8.self), radix: 16) ?? 0
        guard len > 0 else { return "" }
        return String(decoding: try s.readFully(len), as: UTF8.self)
    }

    /// A socket already switched to one device, ready for a device-scoped service.
    static func openTransport(_ serial: String) throws -> TCPSocket {
        let s = try openServer(timeout: 10)
        do {
            try send(s, "host:transport:\(serial)")
        } catch {
            s.shutdownAndClose()
            throw error
        }
        return s
    }

    // MARK: - the commands we need

    static func serverVersion() throws -> String {
        try hostRequest("host:version")
    }

    /// Kill the adb server. Everything connected through it drops, so callers should expect to
    /// rebuild any session they hold.
    static func killServer() throws {
        // host:kill gets no reply — the server closes the socket as it dies — so a missing OKAY
        // here is success, not failure.
        let s = try openServer(timeout: 3)
        defer { s.shutdownAndClose() }
        let body = Data("host:kill".utf8)
        try s.writeAll(Data(String(format: "%04x", body.count).utf8) + body)
        _ = try? s.readFully(4)
    }

    /// Start the adb server, which is the one thing the wire protocol cannot do — only the adb
    /// binary can fork a server. Everything else in this file talks to :5037 directly.
    static func startServer() throws {
        guard let binary = binaryPath() else {
            throw AdbError.failed("cannot find the adb binary to start a server")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["start-server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AdbError.failed("`adb start-server` exited \(process.terminationStatus)")
        }
    }

    /// Where adb lives. A GUI app does not inherit the shell's PATH, so `which` is no help and
    /// the usual install locations have to be tried directly.
    static func binaryPath() -> String? {
        var candidates = [
            // The bundled adb, next to the app's own executable in Contents/MacOS — where a
            // sandboxed app's helper tool must live, signed to inherit the app's sandbox (this
            // is exactly how the store build ships it). package-dmg.sh puts it here.
            Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("adb").path ?? "/nonexistent",
            // Older layout: a copy under Resources/adb (kept so an existing bundle still works).
            Bundle.main.resourcePath.map { $0 + "/adb/adb" } ?? "/nonexistent",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
        ]
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = ProcessInfo.processInfo.environment[key], !root.isEmpty {
                candidates.insert(root + "/platform-tools/adb", at: 0)
            }
        }
        candidates.append(NSString(string: "~/Library/Android/sdk/platform-tools/adb")
                            .expandingTildeInPath)
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `adb connect`. The reply is a human sentence rather than a status code, so success has to
    /// be read out of the text — "connected to" and "already connected to" both mean it worked.
    static func connect(_ address: String) throws -> String {
        let reply = try hostRequest("host:connect:\(address)")
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().contains("connected to") else {
            throw AdbError.failed(text.isEmpty ? "no reply from adb" : text)
        }
        return text
    }

    static func disconnect(_ address: String) throws -> String {
        try hostRequest("host:disconnect:\(address)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func devices() throws -> [AdbDevice] {
        let text = try hostRequest("host:devices-l")
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { return nil }
            var model: String?, product: String?, transport: String?
            for f in fields.dropFirst(2) {
                let pair = f.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "model":        model = String(pair[1])
                case "product":      product = String(pair[1])
                case "transport_id": transport = String(pair[1])
                default:             break
                }
            }
            return AdbDevice(serial: String(fields[0]), state: String(fields[1]),
                             model: model, product: product, transportId: transport)
        }
    }

    /// Run a shell command and collect all of its output. For anything long-running use
    /// `shellStream` instead — this reads to EOF and will not return until the command exits.
    /// `timeout` is the per-read idle limit, not a total budget. The default suits ordinary
    /// commands; something that thinks for minutes before printing anything — `bugreportz` —
    /// has to raise it or the read gives up mid-run.
    static func shell(_ serial: String, _ command: String,
                      timeout: TimeInterval = 15) throws -> String {
        let s = try openTransport(serial)
        defer { s.shutdownAndClose() }
        // exec: rather than shell: — shell: on API 24+ multiplexes stdout/stderr/exit into a
        // framed protocol, and we only want the raw bytes.
        try send(s, "exec:\(command)")
        s.setReadTimeout(timeout)
        return String(decoding: try readToEnd(s), as: UTF8.self)
    }

    /// Same as `shell`, but hands back the raw bytes. `exec:` does no newline translation, so
    /// this is safe for binary payloads — a PNG streamed out of an APK, for instance.
    static func shellData(_ serial: String, _ command: String) throws -> Data {
        let s = try openTransport(serial)
        defer { s.shutdownAndClose() }
        try send(s, "exec:\(command)")
        s.setReadTimeout(15)
        return try readToEnd(s)
    }

    /// Start a shell command and hand back its still-open socket, so the caller can read its
    /// output for as long as it runs. This is how the agent is launched.
    static func shellStream(_ serial: String, _ command: String) throws -> TCPSocket {
        let s = try openTransport(serial)
        do {
            try send(s, "exec:\(command)")
        } catch {
            s.shutdownAndClose()
            throw error
        }
        s.setReadTimeout(2)
        return s
    }

    static func getprop(_ serial: String, _ name: String) throws -> String {
        try shell(serial, "getprop \(name)").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `adb reverse` — the device-side abstract socket that forwards back to our loopback port.
    static func reverse(_ serial: String, localAbstract name: String, toPort port: UInt16) throws {
        let s = try openTransport(serial)
        defer { s.shutdownAndClose() }
        try send(s, "reverse:forward:localabstract:\(name);tcp:\(port)")
        // The reverse service answers a second OKAY once the forward is actually installed.
        try expectOkay(s)
    }

    static func reverseRemove(_ serial: String, localAbstract name: String) throws {
        let s = try openTransport(serial)
        defer { s.shutdownAndClose() }
        try send(s, "reverse:killforward:localabstract:\(name)")
        try? expectOkay(s)
    }

    // MARK: - sync: push

    /// Push a local file. `mode` is the POSIX mode the file lands with — 0o755 for anything that
    /// has to be executable, 0o644 otherwise.
    ///
    /// The sync protocol is its own little language spoken after `sync:`: SEND with a
    /// "path,mode" payload, then DATA chunks, then DONE with an mtime, then a single OKAY.
    /// All of its lengths are little-endian u32, unlike the hex lengths of the host protocol.
    static func push(_ serial: String, localPath: String, remotePath: String, mode: Int = 0o644,
                     progress: ((Int) -> Void)? = nil) throws {
        guard let file = FileHandle(forReadingAtPath: localPath) else {
            throw AdbError.failed("cannot read \(localPath)")
        }
        defer { try? file.close() }
        let s = try openTransport(serial)
        defer { s.shutdownAndClose() }
        try send(s, "sync:")

        let spec = Data("\(remotePath),\(mode)".utf8)
        try s.writeAll(Data("SEND".utf8) + le32(UInt32(spec.count)) + spec)

        // Streamed from disk in the sync protocol's maximum chunk — a dropped-in video should
        // not have to fit in memory first.
        let chunkSize = 64 * 1024
        var sent = 0
        while true {
            let chunk = try file.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            try s.writeAll(Data("DATA".utf8) + le32(UInt32(chunk.count)) + chunk)
            sent += chunk.count
            progress?(sent)
        }

        let mtime = UInt32(Date().timeIntervalSince1970)
        try s.writeAll(Data("DONE".utf8) + le32(mtime))

        let reply = try s.readFully(8)
        let tag = String(decoding: reply.prefix(4), as: UTF8.self)
        guard tag == "OKAY" else {
            let len = Int(le32Value(reply.suffix(4)))
            let msg = len > 0 ? String(decoding: try s.readFully(len), as: UTF8.self) : tag
            throw AdbError.failed("push \(remotePath): \(msg)")
        }
    }

    static func le32(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }

    static func le32Value(_ d: Data) -> UInt32 {
        d.reduce(0) { ($0 >> 8) | (UInt32($1) << 24) }
    }
}
