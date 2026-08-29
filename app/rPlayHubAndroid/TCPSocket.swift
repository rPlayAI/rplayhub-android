//
//  TCPSocket.swift
//  Blocking TCP over Darwin sockets, plus the loopback listener the agent dials back into.
//
//  Adopted from ~/rplay-hub with the listener added. Deliberately not Network.framework: every
//  socket here wants a plain blocking reader thread, and adb's own protocol is request/response
//  over a blocking stream.
//

import Darwin
import Foundation

enum SocketError: Error, CustomStringConvertible {
    case create(Int32)
    case connect(String, UInt16, Int32)
    case bind(Int32)
    case accept(Int32)
    case closed
    case write(Int32)
    case timeout

    var description: String {
        switch self {
        case .create(let e):                return "socket() failed: \(String(cString: strerror(e)))"
        case .connect(let h, let p, let e): return "connect \(h):\(p) failed: \(String(cString: strerror(e)))"
        case .bind(let e):                  return "bind failed: \(String(cString: strerror(e)))"
        case .accept(let e):                return "accept failed: \(String(cString: strerror(e)))"
        case .closed:                       return "connection closed by peer"
        case .write(let e):                 return "write failed: \(String(cString: strerror(e)))"
        case .timeout:                      return "timed out"
        }
    }
}

final class TCPSocket {
    private(set) var fd: Int32 = -1
    let host: String
    let port: UInt16

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Adopt an already-connected descriptor — how the listener hands sockets over.
    init(adopting descriptor: Int32, from peer: String = "agent") {
        fd = descriptor
        host = peer
        port = 0
    }

    var isOpen: Bool { fd >= 0 }

    func connect(timeout: TimeInterval = 5) throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw SocketError.create(errno) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            close(s)
            throw SocketError.connect(host, port, e)
        }

        setReadTimeout(s, timeout)
        var one: Int32 = 1
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = s
    }

    private func setReadTimeout(_ s: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func setReadTimeout(_ seconds: TimeInterval) {
        guard fd >= 0 else { return }
        setReadTimeout(fd, seconds)
    }

    func setNoDelay() {
        guard fd >= 0 else { return }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// One read. Returns nil on timeout, throws on EOF or error.
    func read(max: Int = 1 << 16) throws -> Data? {
        guard fd >= 0 else { throw SocketError.closed }
        var buf = [UInt8](repeating: 0, count: max)
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, max) }
        if n > 0 { return Data(buf[0..<n]) }
        if n == 0 { throw SocketError.closed }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
        throw SocketError.closed
    }

    /// Exactly `count` bytes, retrying across timeouts. The agent's framing is fixed-width in
    /// places (the 44-byte packet header, the 20-byte codec header), and a short read there
    /// desynchronises the whole stream — so those callers must never see a partial buffer.
    func readFully(_ count: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count {
            guard fd >= 0 else { throw SocketError.closed }
            let want = count - out.count
            var buf = [UInt8](repeating: 0, count: want)
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, want) }
            if n > 0 { out.append(contentsOf: buf[0..<n]); continue }
            if n == 0 { throw SocketError.closed }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            throw SocketError.closed
        }
        return out
    }

    func writeAll(_ data: Data) throws {
        guard fd >= 0 else { throw SocketError.closed }
        try data.withUnsafeBytes { raw in
            var remaining = raw.count
            var p = raw.baseAddress
            while remaining > 0 {
                let w = Darwin.write(fd, p, remaining)
                if w <= 0 {
                    if errno == EINTR { continue }
                    throw SocketError.write(errno)
                }
                remaining -= w
                p = p?.advanced(by: w)
            }
        }
    }

    func shutdownAndClose() {
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        close(fd)
        fd = -1
    }
}

/// A loopback listener on an ephemeral port.
///
/// This is the half of the arrangement that has no counterpart in the iOS engine: the agent runs
/// on the phone and dials BACK to us through `adb reverse`, so the host is the server. Binding
/// port 0 and reading the port back is what lets several sessions run at once without a registry
/// of who owns which port — the abstract socket name embeds it.
final class TCPListener {
    private var fd: Int32 = -1
    private(set) var port: UInt16 = 0

    func open() throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw SocketError.create(errno) }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                                  // kernel picks
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { let e = errno; Darwin.close(s); throw SocketError.bind(e) }
        guard listen(s, 8) == 0 else { let e = errno; Darwin.close(s); throw SocketError.bind(e) }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(s, sa, &len)
            }
        }
        port = UInt16(bigEndian: actual.sin_port)
        fd = s
    }

    /// Block until a connection arrives or `timeout` elapses.
    func accept(timeout: TimeInterval) throws -> TCPSocket {
        guard fd >= 0 else { throw SocketError.closed }
        var set = fd_set()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw SocketError.timeout }
            fdZero(&set)
            fdSet(fd, &set)
            var tv = timeval(tv_sec: Int(left), tv_usec: Int32((left - Double(Int(left))) * 1e6))
            let ready = select(fd + 1, &set, nil, nil, &tv)
            if ready < 0 {
                if errno == EINTR { continue }
                throw SocketError.accept(errno)
            }
            if ready == 0 { throw SocketError.timeout }
            let c = Darwin.accept(fd, nil, nil)
            guard c >= 0 else {
                if errno == EINTR { continue }
                throw SocketError.accept(errno)
            }
            return TCPSocket(adopting: c)
        }
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }
}

// fd_set is an opaque tuple to Swift, so the FD_ZERO/FD_SET macros have to be written out.
private func fdZero(_ set: inout fd_set) {
    _ = withUnsafeMutableBytes(of: &set) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd) / 32
    let bit = Int(fd) % 32
    withUnsafeMutableBytes(of: &set) { raw in
        let words = raw.bindMemory(to: Int32.self)
        words[intOffset] |= Int32(1 << bit)
    }
}
