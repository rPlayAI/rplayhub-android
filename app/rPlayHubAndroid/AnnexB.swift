//
//  AnnexB.swift
//  Annex-B start-code splitting, and what the two codecs disagree about.
//
//  Simpler than the iOS path's parser, and for a good reason: the agent frames the stream for us.
//  Every video packet carries its own length and holds exactly one complete access unit, so there
//  is no re-assembly across reads and no first-slice heuristic to decide where a picture ends.
//  (Studio relies on the same guarantee — it sets ffmpeg's PARSER_FLAG_COMPLETE_FRAMES.)
//

import Foundation

enum VideoCodec: String {
    case h264
    case hevc

    /// What the agent writes in the 20-byte channel header, mapped to what we can decode.
    /// av01/vp8/vp9/vvc are codecs the agent can be asked for but VideoToolbox will not take
    /// through this path, so we never request them.
    static func from(channelHeader name: String) -> VideoCodec? {
        switch name {
        case "avc", "h264": return .h264
        case "hevc":        return .hevc
        default:            return nil
        }
    }

    /// H.264 has a 1-byte NAL header with the type in bits 0-4; HEVC a 2-byte header, bits 1-6.
    var headerLength: Int { self == .h264 ? 1 : 2 }

    func nalType(_ nal: Data) -> Int {
        guard let first = nal.first else { return -1 }
        return self == .h264 ? Int(first & 0x1F) : Int((first >> 1) & 0x3F)
    }

    func isParameterSet(_ type: Int) -> Bool {
        self == .h264 ? (type == 7 || type == 8) : (32...34).contains(type)
    }

    func isVCL(_ type: Int) -> Bool {
        self == .h264 ? (1...5).contains(type) : type < 32
    }

    func isKeyframe(_ type: Int) -> Bool {
        self == .h264 ? type == 5 : (16...23).contains(type)
    }

    /// The parameter sets a format description needs, in order. H.264: SPS, PPS.
    /// HEVC: VPS, SPS, PPS.
    var parameterSetTypes: [Int] { self == .h264 ? [7, 8] : [32, 33, 34] }
}

enum AnnexB {
    /// Split one complete buffer into its NAL units, tolerating both 3- and 4-byte start codes.
    static func split(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        let n = bytes.count
        guard n > 3 else { return [] }

        var starts: [(offset: Int, codeLength: Int)] = []
        var i = 0
        while i + 3 <= n {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append((i, 3)); i += 3; continue
                }
                if i + 4 <= n, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append((i, 4)); i += 4; continue
                }
            }
            i += 1
        }
        guard !starts.isEmpty else { return [] }

        var out: [Data] = []
        out.reserveCapacity(starts.count)
        for (index, start) in starts.enumerated() {
            let from = start.offset + start.codeLength
            let to = index + 1 < starts.count ? starts[index + 1].offset : n
            guard from < to else { continue }
            var nal = Data(bytes[from..<to])
            while nal.last == 0 { nal.removeLast() }      // trailing_zero_8bits
            if !nal.isEmpty { out.append(nal) }
        }
        return out
    }

    /// Annex-B NALs → the 4-byte-length-prefixed form the format description declares.
    static func lengthPrefixed(_ nals: [Data]) -> Data {
        var payload = Data()
        payload.reserveCapacity(nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            var be = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &be) { payload.append(contentsOf: $0) }
            payload.append(nal)
        }
        return payload
    }
}
