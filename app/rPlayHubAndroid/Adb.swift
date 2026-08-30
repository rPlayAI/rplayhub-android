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

    /// What the sidebar shows. `model` comes back with underscores for spaces.
    var displayName: String {
        guard let model, !model.isEmpty else { return serial }
        return model.replacingOccurrences(of: "_", with: " ")
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
    static func shell(_ serial: String, _ command: String) throws -> String {
        let s = try openTransport(serial)
        defer { s.shutdownAndClose() }
        // exec: rather than shell: — shell: on API 24+ multiplexes stdout/stderr/exit into a
        // framed protocol, and we only want the raw bytes.
        try send(s, "exec:\(command)")
        s.setReadTimeout(15)
        return String(decoding: try readToEnd(s), as: UTF8.self)
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
    static func push(_ serial: String, localPath: String, remotePath: String, mode: Int = 0o644) throws {
        guard let data = FileManager.default.contents(atPath: localPath) else {
            throw AdbError.failed("cannot read \(localPath)")
        }
        let s = try openTransport(serial)
        defer { s.shutdownAndClose() }
        try send(s, "sync:")

        let spec = Data("\(remotePath),\(mode)".utf8)
        try s.writeAll(Data("SEND".utf8) + le32(UInt32(spec.count)) + spec)

        var offset = 0
        let chunkSize = 64 * 1024              // the sync protocol's maximum
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data[data.startIndex.advanced(by: offset)..<data.startIndex.advanced(by: end)]
            try s.writeAll(Data("DATA".utf8) + le32(UInt32(chunk.count)) + Data(chunk))
            offset = end
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
