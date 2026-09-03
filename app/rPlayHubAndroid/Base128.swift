//
//  Base128.swift
//  The agent's control-channel wire codec.
//
//  Ported from the agent's own C++ (`cpp/base128_output_stream.cc`), which is the original —
//  Studio's ControlMessages.kt is itself a port of it. Plain unsigned LEB128, seven bits per
//  byte, high bit set while more follow. NOT zigzag: WriteInt32 is literally WriteUInt32, so a
//  negative int32 reinterprets as a large unsigned and costs five bytes. Getting that wrong
//  desynchronises the whole channel, since nothing is length-prefixed.
//
//  Floats go over as a raw little-endian IEEE-754 bit pattern (WriteFixed32), not as a varint.
//

import Foundation

struct Base128Writer {
    private(set) var data = Data()

    mutating func writeByte(_ b: UInt8) { data.append(b) }

    mutating func writeUInt32(_ value: UInt32) {
        var v = value
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            data.append(b)
        } while v != 0
    }

    /// Signed values reinterpret, they do not zigzag — see the file comment.
    mutating func writeInt32(_ value: Int32) { writeUInt32(UInt32(bitPattern: value)) }

    mutating func writeUInt64(_ value: UInt64) {
        var v = value
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            data.append(b)
        } while v != 0
    }

    mutating func writeInt64(_ value: Int64) { writeUInt64(UInt64(bitPattern: value)) }

    mutating func writeBool(_ value: Bool) { data.append(value ? 1 : 0) }

    mutating func writeFixed32(_ value: Int32) {
        let u = UInt32(bitPattern: value)
        data.append(UInt8(u & 0xFF))
        data.append(UInt8((u >> 8) & 0xFF))
        data.append(UInt8((u >> 16) & 0xFF))
        data.append(UInt8((u >> 24) & 0xFF))
    }

    mutating func writeFloat(_ value: Float) { writeFixed32(Int32(bitPattern: value.bitPattern)) }

    /// UTF-16 code units, length first — the agent reads these into a std::u16string.
    /// The agent's ReadString16: the count is written PLUS ONE — 0 stands for a null string —
    /// then one varint per UTF-16 unit. Sending the raw count made every one-character text
    /// (each keystroke) decode as an empty string, which the agent treats as a fatal protocol
    /// error and exits on.
    mutating func writeString16(_ value: String) {
        let units = Array(value.utf16)
        writeUInt32(UInt32(units.count + 1))
        for u in units { writeUInt32(UInt32(u)) }
    }

    /// The agent's WriteBytes: varint byte count, then the raw bytes. Its std::string fields —
    /// clipboard text among them — are UTF-8.
    mutating func writeBytes(_ value: String) {
        let utf8 = Array(value.utf8)
        writeUInt32(UInt32(utf8.count))
        data.append(contentsOf: utf8)
    }
}

/// Reads the agent's replies. The control channel is bidirectional: display configuration,
/// clipboard, and device state all come back this way.
struct Base128Reader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var hasMore: Bool { offset < bytes.count }

    mutating func readUInt32() throws -> UInt32 {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        while true {
            guard offset < bytes.count else { throw SocketError.closed }
            let b = bytes[offset]; offset += 1
            result |= UInt32(b & 0x7F) &<< shift
            if b & 0x80 == 0 { return result }
            shift += 7
            guard shift < 32 else { throw SocketError.closed }
        }
    }

    mutating func readInt32() throws -> Int32 { Int32(bitPattern: try readUInt32()) }

    mutating func readBool() throws -> Bool {
        guard offset < bytes.count else { throw SocketError.closed }
        defer { offset += 1 }
        return bytes[offset] != 0
    }
}
