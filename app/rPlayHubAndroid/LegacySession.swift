//
//  LegacySession.swift
//  Mirroring and control for Android 5.0-7.1 (API 21-25), the boards Studio's agent cannot reach.
//
//  The vendored screen-sharing agent is built minSdk 26 and cannot be lowered: its capture needs
//  AMediaCodec_createInputSurface, which the NDK only exposes at 26. Java's
//  MediaCodec.createInputSurface() has no such limit, so these devices get our own small Java
//  agent (legacy-agent/src/Main.java, built by tools/build-legacy-agent.sh) run through
//  app_process as the shell user. Many embedded boards — car boxes, dashcams, signage — are still
//  on Android 5, and they are exactly what scrcpy is used for.
//
//  One adb `exec:` stream carries everything, so there is no reverse tunnel and no second socket:
//  the agent writes raw Annex-B H.264 to stdout, which goes straight into the VideoToolbox
//  decoder we already have, and reads one-line input commands from stdin.
//
//  Limits worth knowing: no virtual displays, so no fusion windows here, and the picture is the
//  real screen rather than a private display.
//

import CoreMedia
import Foundation
import VideoToolbox

final class LegacySession {
    enum State: Equatable {
        case starting
        case running
        case failed(String)
    }

    let serial: String
    var onState: ((State) -> Void)?
    /// A decoded frame for the mirror's display layer.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// The display's pixel size, once `wm size` has answered.
    var onSize: ((CGSize) -> Void)?

    private(set) var displaySize: CGSize = .zero
    private(set) var framesDecoded = 0
    private(set) var restarts = 0

    private let decoder = VideoDecoder()
    private var socket: TCPSocket?
    private var thread: Thread?
    private var stopping = false
    /// Serialises `input` calls: two `adb shell` round trips at once interleave badly.
    private let inputQueue = DispatchQueue(label: "ai.rplay.rplayhub.legacy-input")

    /// screenrecord's own ceiling. Restart a little early so the stream never actually ends.
    private let segmentSeconds = 170

    init(serial: String) {
        self.serial = serial
    }

    // MARK: - lifecycle

    func start() {
        stopping = false
        decoder.onFrame = { [weak self] picture in
            guard let self else { return }
            self.framesDecoded += 1
            self.onFrame?(picture)
        }
        report(.starting)
        let t = Thread { [weak self] in self?.run() }
        t.name = "rplayhub.legacy.capture"
        thread = t
        t.start()
    }

    func stop() {
        send("q")
        stopping = true
        socket?.shutdownAndClose()
        socket = nil
        decoder.invalidate()
        // "q" only lands if the agent is still reading stdin; make sure it is gone either way,
        // so the next session does not fight a process still holding the encoder.
        let serial = self.serial
        DispatchQueue.global(qos: .utility).async {
            _ = try? Adb.shell(serial, "pkill -f ai.rplay.legacy", timeout: 5)
        }
    }

    /// `wm size` reports "Physical size: 1280x720"; an override line wins when present.
    private func loadDisplaySize() {
        guard let text = try? Adb.shell(serial, "wm size") else { return }
        var size: CGSize?
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: ":") else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let parts = value.split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2 else { continue }
            let candidate = CGSize(width: parts[0], height: parts[1])
            if line.contains("Override") { size = candidate } else if size == nil { size = candidate }
        }
        guard let size, size.width > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.displaySize = size
            self.onSize?(size)
        }
    }

    /// Push the agent if the device does not already have this build, then run it. Unlike
    /// `screenrecord` there is no time limit to work around: the agent streams until told to stop.
    private func run() {
        loadDisplaySize()
        do {
            try deployAgent()
        } catch {
            report(.failed("could not install the legacy agent: \(error)"))
            return
        }
        // A leftover agent from an earlier attempt still holds a display and an encoder, and the
        // next one then starts badly or not at all — which is what made mirroring take several
        // tries before it held. Clear it before every launch.
        _ = try? Adb.shell(serial, "pkill -f ai.rplay.legacy", timeout: 5)

        let size = displaySize
        var w = 1024, h = 600
        if size.width > 0, size.height > 0 {
            // Keep the long edge at or under 1280: these boards have modest encoders.
            let scale = min(1, 1280 / max(size.width, size.height))
            w = Int((size.width * scale).rounded()) & ~1
            h = Int((size.height * scale).rounded()) & ~1
        }
        let command = "CLASSPATH=\(Self.dexRemotePath) app_process / ai.rplay.legacy.Main \(w) \(h) 4000000"

        // The agent path reconnects itself when a stream dies; this one has to as well, or a
        // single hiccup on a slow board ends mirroring until the user clicks Start again.
        var attempt = 0
        while !stopping {
            attempt += 1
            AppBuild.log("legacy: \(serial) launching (attempt \(attempt)) \(command)")
            do {
                let s = try Adb.shellStream(serial, command)
                socket = s
                report(.running)
                readStream(from: s)
                s.shutdownAndClose()
                socket = nil
            } catch {
                if stopping { return }
                AppBuild.log("legacy: \(serial) could not start: \(error)")
            }
            guard !stopping else { return }
            guard attempt < 5 else {
                report(.failed("the legacy agent kept stopping (\(attempt) attempts)"))
                return
            }
            // A fresh run means fresh parameter sets; drop the decoder state with the stream.
            parameterSets.removeAll()
            format = nil
            awaitingKeyframe = true
            decoder.invalidate()
            _ = try? Adb.shell(serial, "pkill -f ai.rplay.legacy", timeout: 5)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    static let dexRemotePath = "/data/local/tmp/rplayhub-legacy.dex"

    /// Where the built dex lives: bundled in Resources for a shipping build, or the build tree
    /// when running from Xcode.
    static var dexURL: URL? {
        if let env = ProcessInfo.processInfo.environment["RPLAYHUB_LEGACY_AGENT"],
           FileManager.default.fileExists(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        if let bundled = Bundle.main.url(forResource: "rplayhub-legacy", withExtension: "dex") {
            return bundled
        }
        let build = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/legacy-agent/rplayhub-legacy.dex")
        return FileManager.default.fileExists(atPath: build.path) ? build : nil
    }

    private func deployAgent() throws {
        guard let dex = Self.dexURL else {
            throw AdbError.failed("the legacy agent (rplayhub-legacy.dex) is not in this build")
        }
        // 0o755: app_process must be able to read it, and an executable bit costs nothing.
        try Adb.push(serial, localPath: dex.path, remotePath: Self.dexRemotePath, mode: 0o755)
    }

    /// Feed NALs to the decoder as they complete.
    private func readStream(from s: TCPSocket) {
        var buffer = Data()
        while !stopping {
            // read() returns nil on TIMEOUT and throws on EOF. Collapsing the two ends the
            // session the first time the screen sits still for a couple of seconds, because a
            // surface encoder emits nothing at all while nothing changes.
            let chunk: Data?
            do { chunk = try s.read(max: 64 << 10) } catch { return }
            guard let chunk, !chunk.isEmpty else { continue }
            bytesIn += chunk.count
            buffer.append(chunk)
            // Nobody can see the picture from a log, so say what is arriving and what came out.
            if Date().timeIntervalSince(lastReport) >= 5 {
                lastReport = Date()
                let types = nalTypes.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: " ")
                AppBuild.log("legacy: \(bytesIn / 1024) KiB in, \(nalsSeen) NALs [\(types)], "
                             + "\(framesDecoded) decoded, awaitingKey=\(awaitingKeyframe), "
                             + "format=\(format != nil), decodeStatus=\(lastDecodeStatus), "
                             + "buffered \(buffer.count) B")
            }
            // Hand off everything up to the last start code; the tail may be a partial NAL.
            guard let lastStart = Self.lastStartCodeIndex(in: buffer), lastStart > 0 else { continue }
            let complete = buffer.prefix(lastStart)
            buffer.removeSubrange(0 ..< lastStart)
            consume(Data(complete))
        }
    }

    /// Index of the final Annex-B start code, so a partial trailing NAL stays buffered.
    private static func lastStartCodeIndex(in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        var i = data.count - 4
        let bytes = [UInt8](data)
        while i > 0 {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 { return i }
            if i >= 1, bytes[i - 1] == 0, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 { return i - 1 }
            i -= 1
        }
        return nil
    }

    // MARK: - decode

    private var parameterSets: [Int: Data] = [:]     // 7 = SPS, 8 = PPS
    private var format: CMVideoFormatDescription?
    private var awaitingKeyframe = true
    private var presentation = CMTime.zero
    private var lastReport = Date.distantPast
    private var bytesIn = 0
    private var nalsSeen = 0
    /// nal_unit_type -> count, so a stall shows which kinds are actually arriving.
    private var nalTypes: [Int: Int] = [:]
    private var lastDecodeStatus: OSStatus = noErr

    private func consume(_ data: Data) {
        var picture: [Data] = []
        var sawKeyframe = false
        var newParameterSet = false

        for nal in AnnexB.split(data) where !nal.isEmpty {
            nalsSeen += 1
            nalTypes[Int(nal[nal.startIndex] & 0x1F), default: 0] += 1
            let type = Int(nal[nal.startIndex] & 0x1F)     // H.264 nal_unit_type
            switch type {
            case 7, 8:
                if parameterSets[type] != nal {
                    parameterSets[type] = nal
                    newParameterSet = true
                }
            case 5:
                sawKeyframe = true
                picture.append(nal)
            case 1:
                picture.append(nal)
            default:
                break                                       // SEI, AUD — nothing to display
            }
        }

        if newParameterSet { rebuildFormat() }
        guard !picture.isEmpty, let format else { return }
        if sawKeyframe {
            awaitingKeyframe = false
        } else if awaitingKeyframe {
            return
        }
        guard let sample = makeSample(AnnexB.lengthPrefixed(picture), format: format) else {
            AppBuild.log("legacy: could not build a sample buffer")
            return
        }
        let status = decoder.decode(sample)
        if status != noErr { lastDecodeStatus = status }
        if status == kVTVideoDecoderBadDataErr { awaitingKeyframe = true }

    }

    private func rebuildFormat() {
        guard let sps = parameterSets[7], let pps = parameterSets[8] else { return }
        var description: CMVideoFormatDescription?
        let made: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let s = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let p = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                var pointers: [UnsafePointer<UInt8>] = [s, p]
                var sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard made == noErr, let description else { return }
        format = description
        awaitingKeyframe = true
        decoder.invalidate()
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        AppBuild.log("legacy: \(serial) stream \(dimensions.width)x\(dimensions.height)")
    }

    /// Wrap one access unit as a sample buffer.
    ///
    /// The bytes are COPIED into the block buffer. Pointing a kCFAllocatorNull block at Data's
    /// storage looks cheaper, but that pointer is only valid inside withUnsafeBytes — by the time
    /// VideoToolbox reads it the memory is gone, and every decode silently produces nothing.
    private func makeSample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: data.count, flags: 0,
                blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
                                                 offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }

        // The agent sends no timestamps, so present in arrival order at the encoder's rate.
        presentation = CMTimeAdd(presentation, CMTime(value: 1, timescale: 30))
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: presentation,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var length = data.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &length,
                                        sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    private func report(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }

    // MARK: - input (over the agent's stdin)

    func touch(x: Int, y: Int, phase: Int) {
        send("t \(x) \(y) \(phase)")
    }

    func key(_ keycode: Int32) {
        send("k \(keycode)")
    }

    /// A control-strip button. Rotation, screenshot and recording stay on adb with the caller.
    func perform(_ action: ControlStrip.Action) {
        switch action {
        case .back:       key(AndroidKey.back)
        case .home:       key(AndroidKey.home)
        case .overview:   key(AndroidKey.appSwitch)
        case .power:      key(26)                    // KEYCODE_POWER
        case .volumeUp:   key(24)
        case .volumeDown: key(25)
        case .rotate, .screenshot, .record: break
        }
    }

    private func send(_ line: String) {
        guard let socket, !stopping else { return }
        inputQueue.async { try? socket.writeAll(Data((line + "\n").utf8)) }
    }
}
