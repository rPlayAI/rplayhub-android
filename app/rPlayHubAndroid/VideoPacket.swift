//
//  VideoPacket.swift
//  The 44-byte header in front of every video packet.
//
//  Layout from the agent's `cpp/video_packet_header.h`, little-endian, in field order. It is
//  naturally packed with no interior padding — the int64 pair lands on offset 24, already
//  8-aligned — but `sizeof` rounds the struct up to 48 for the trailing alignment, which is why
//  the agent keeps a separate SIZE constant and why we must read 44 and not 48.
//
//  Everything the renderer needs about geometry rides in here, on every single frame. There is no
//  side channel for rotation or resize: the picture simply starts arriving with a different
//  header, and the view reacts.
//

import CoreGraphics
import Foundation

struct VideoPacketHeader {
    static let size = 44

    var displayId: Int32
    var displayWidth: Int32
    var displayHeight: Int32
    /// Quadrants. The display's current rotation.
    var displayOrientation: UInt8
    /// Quadrants. What the agent already rotated for us, so we do not rotate twice.
    var displayOrientationCorrection: UInt8
    var flags: Int16
    var bitRate: Int32
    /// Starts at 1.
    var frameNumber: UInt32
    var originationTimestampUs: Int64
    /// Zero marks a config packet — codec parameter sets, no picture.
    var presentationTimestampUs: Int64
    var packetSize: Int32

    static let flagDisplayRound: Int16 = 0x01
    static let flagBitRateReduced: Int16 = 0x02
    static let flagCamera: Int16 = 0x04

    var isConfig: Bool { presentationTimestampUs == 0 }
    var isDisplayRound: Bool { flags & Self.flagDisplayRound != 0 }
    var isBitRateReduced: Bool { flags & Self.flagBitRateReduced != 0 }

    /// The display in its canonical orientation.
    var displaySize: CGSize {
        CGSize(width: CGFloat(displayWidth), height: CGFloat(displayHeight))
    }

    /// The display as the picture presents it — the agent may already have rotated the frame, and
    /// `displayOrientationCorrection` says by how much. Studio computes its crop against exactly
    /// this (`VideoDecoder.kt`: `header.displayOrientation - header.displayOrientationCorrection`).
    var rotatedDisplaySize: CGSize {
        let quadrants = (Int(displayOrientation) - Int(displayOrientationCorrection) + 4) % 4
        return quadrants % 2 == 1
            ? CGSize(width: CGFloat(displayHeight), height: CGFloat(displayWidth))
            : displaySize
    }

    init?(_ data: Data) {
        guard data.count >= Self.size else { return nil }
        let b = [UInt8](data)
        func i32(_ o: Int) -> Int32 {
            Int32(bitPattern: UInt32(b[o]) | UInt32(b[o+1]) << 8 | UInt32(b[o+2]) << 16 | UInt32(b[o+3]) << 24)
        }
        func u32(_ o: Int) -> UInt32 { UInt32(bitPattern: i32(o)) }
        func i64(_ o: Int) -> Int64 {
            Int64(bitPattern: UInt64(u32(o)) | UInt64(u32(o + 4)) << 32)
        }
        displayId = i32(0)
        displayWidth = i32(4)
        displayHeight = i32(8)
        displayOrientation = b[12]
        displayOrientationCorrection = b[13]
        flags = Int16(bitPattern: UInt16(b[14]) | UInt16(b[15]) << 8)
        bitRate = i32(16)
        frameNumber = u32(20)
        originationTimestampUs = i64(24)
        presentationTimestampUs = i64(32)
        packetSize = i32(40)
    }

    var debugDescription: String {
        "display \(displayId) \(displayWidth)x\(displayHeight) rot=\(displayOrientation)"
        + "/\(displayOrientationCorrection) frame=\(frameNumber) size=\(packetSize)"
        + (isConfig ? " CONFIG" : "")
    }
}
