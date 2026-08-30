//
//  VideoStream.swift
//  The video channel: 20-byte codec header, then header+payload packets, forever.
//
//  Runs its own blocking reader thread. Per packet it splits the Annex-B payload, routes
//  parameter sets into the format description and VCL NALs into a sample buffer, and hands that
//  to VideoDecoder. Nothing is dropped between here and the decoder — display-side skipping is
//  VideoLayer's business, where it is free.
//
//  Keyframe gating is kept from ~/rplay-hub and matters just as much here. Parameter sets alone
//  are not enough to start: without an IRAP every P-frame references pictures the decoder never
//  saw, and VideoToolbox's response to that is a black window with no error at all.
//

import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

final class VideoStream {
    /// Codec name as the agent advertised it, before mapping.
    private(set) var advertisedCodec = ""
    private(set) var codec: VideoCodec = .h264

    /// The most recent packet header — geometry, bit rate, frame number.
    private(set) var lastHeader: VideoPacketHeader?

    private(set) var framesEnqueued = 0
    private(set) var packetsReceived = 0
    private(set) var bytesReceived = 0
    private(set) var framesBeforeKeyframe = 0
    private(set) var awaitingKeyframe = true

    var framesDecoded: Int { decoder.framesDecoded }
    var decodeFailures: Int { decoder.decodeFailures }
    var lastError: String? { decoder.lastError }

    /// Coded frame size from the parameter sets, once known. Main queue.
    var onFormat: ((CGSize) -> Void)?
    /// Every packet's header, so the view can follow rotation and resize. Main queue, coalesced
    /// to changes only — this would otherwise fire at the frame rate.
    var onGeometry: ((VideoPacketHeader) -> Void)?
    /// Connection ended. Main queue.
    var onDisconnect: ((String) -> Void)?
    /// The byte stream stopped being a packet stream — see `desyncReason`. The session is dead
    /// the same as a disconnect, but the caller may want to reconnect rather than report. Falls
    /// back to `onDisconnect` when unset. Main queue.
    var onDesync: ((String) -> Void)?

    private let socket: TCPSocket
    let decoder: VideoDecoder
    private var thread: Thread?
    private var stopping = false

    private var parameterSets: [Int: Data] = [:]
    private var format: CMVideoFormatDescription?
    private var framesSubmitted: Int64 = 0
    private var lastGeometry: (w: Int32, h: Int32, rot: UInt8)?
    private var lastFrameNumber: UInt32?
    private var lastDisplayId: Int32?

    /// `RPLAYHUB_VIDEO_STALL="<packet>:<seconds>[:<count>]"` stops reading the socket for
    /// <seconds> before each of the <count> packets starting at <packet> (count defaults to 1).
    /// With seconds > the agent's 10s write deadline this reproduces the desync bug in seconds
    /// instead of whenever the network next chokes for real: the first stall fills every buffer
    /// between the encoder and us, and each packet read after that frees just enough room for
    /// the agent to write *part* of its next packet before the deadline passes — a truncated
    /// packet on the wire. Debug only; unset means never.
    private static let debugStall: (packet: Int, seconds: TimeInterval, count: Int)? = {
        guard let raw = ProcessInfo.processInfo.environment["RPLAYHUB_VIDEO_STALL"] else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count >= 2, let packet = Int(parts[0]), let seconds = TimeInterval(parts[1]),
              packet > 0, seconds > 0 else { return nil }
        let count = parts.count >= 3 ? Int(parts[2]) ?? 1 : 1
        return (packet, seconds, max(1, count))
    }()

    init(socket: TCPSocket, decoder: VideoDecoder) {
        self.socket = socket
        self.decoder = decoder
    }

    func start() {
        stopping = false
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "rplayhub.android.video"
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    func stop() {
        stopping = true
        socket.shutdownAndClose()
        decoder.invalidate()
    }

    // MARK: - the loop

    private func readLoop() {
        do {
            // The channel opens with a fixed 20-byte codec name, space padded.
            let nameBytes = try socket.readFully(20)
            let name = String(decoding: nameBytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\0", with: "")
            advertisedCodec = name
            guard let mapped = VideoCodec.from(channelHeader: name) else {
                fail("device advertised '\(name)', which this host cannot decode")
                return
            }
            codec = mapped
            AppBuild.log("video channel: codec \(name)")

            // No read timeout past this point: a still screen produces no packets at all, and a
            // timeout would read as a dropped connection every time the user stops touching it.
            socket.setReadTimeout(0)

            while !stopping {
                if let stall = Self.debugStall,
                   packetsReceived >= stall.packet, packetsReceived < stall.packet + stall.count {
                    AppBuild.log("debug: stalling video reads for \(stall.seconds)s"
                                 + " (\(packetsReceived - stall.packet + 1)/\(stall.count))")
                    Thread.sleep(forTimeInterval: stall.seconds)
                }
                let headerBytes = try socket.readFully(VideoPacketHeader.size)
                guard let header = VideoPacketHeader(headerBytes) else {
                    fail("malformed packet header")
                    return
                }
                if let reason = desyncReason(header) {
                    fail(reason, desync: true)
                    return
                }
                let payload = header.packetSize > 0
                    ? try socket.readFully(Int(header.packetSize))
                    : Data()

                packetsReceived += 1
                bytesReceived += VideoPacketHeader.size + payload.count
                lastHeader = header
                publishGeometry(header)
                handle(header: header, payload: payload)
            }
        } catch {
            if !stopping { fail("\(error)") }
        }
    }

    private func fail(_ reason: String, desync: Bool = false) {
        AppBuild.log("video stream ended: \(reason)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if desync, let onDesync = self.onDesync {
                onDesync(reason)
            } else {
                self.onDisconnect?(reason)
            }
        }
    }

    /// Is this header the next thing this stream could legitimately say? The agent's SocketWriter
    /// can time out with a packet half-written, and an agent build without our fix keeps streaming
    /// afterwards — from then on payload bytes get parsed as headers. A garbage header can pass a
    /// size check by chance, and then everything downstream of it is garbage too: the visible
    /// symptom is VideoToolbox dying with kVTVideoDecoderBadDataErr (-12909) on every frame.
    ///
    /// So check what garbage cannot plausibly satisfy. Geometry and orientation are bounded, and
    /// the frame number is nearly sequential — not strictly `last + 1`, because config packets
    /// repeat the current number and the agent's empty-frame-on-timeout path skips one, so allow
    /// a small forward window instead of exact succession.
    private func desyncReason(_ header: VideoPacketHeader) -> String? {
        guard header.packetSize >= 0, header.packetSize < 32 << 20 else {
            return "protocol desync: implausible packet size \(header.packetSize)"
        }
        guard (1...16384).contains(header.displayWidth),
              (1...16384).contains(header.displayHeight) else {
            return "protocol desync: implausible display \(header.displayWidth)x\(header.displayHeight)"
        }
        guard header.displayOrientation < 4, header.displayOrientationCorrection < 4 else {
            return "protocol desync: implausible orientation \(header.displayOrientation)"
                + "/\(header.displayOrientationCorrection)"
        }
        // Each display's streamer numbers its own frames, so switching displays legitimately
        // resets the count; within one display the sequence stays nearly monotonic.
        if header.displayId != lastDisplayId {
            lastDisplayId = header.displayId
            lastFrameNumber = nil
        }
        if let last = lastFrameNumber,
           !(header.frameNumber >= last && header.frameNumber <= last &+ 64) {
            return "protocol desync: frame number jumped \(last) → \(header.frameNumber)"
        }
        lastFrameNumber = header.frameNumber
        return nil
    }

    /// Only on change — the header is identical on every frame of a still screen, and posting it
    /// to the main queue at the frame rate would be pure overhead.
    private func publishGeometry(_ header: VideoPacketHeader) {
        let now = (header.displayWidth, header.displayHeight, header.displayOrientation)
        if let last = lastGeometry, last == now { return }
        lastGeometry = now
        DispatchQueue.main.async { [weak self] in self?.onGeometry?(header) }
    }

    private func handle(header: VideoPacketHeader, payload: Data) {
        guard !payload.isEmpty else { return }
        let nals = AnnexB.split(payload)
        guard !nals.isEmpty else { return }

        var picture: [Data] = []
        var sawKeyframe = false
        var newParameterSet = false

        for nal in nals where nal.count > codec.headerLength {
            let type = codec.nalType(nal)
            if codec.isParameterSet(type) {
                if parameterSets[type] != nal {
                    parameterSets[type] = nal
                    newParameterSet = true
                }
                continue
            }
            guard codec.isVCL(type) else { continue }   // SEI, AUD — nothing to display
            if codec.isKeyframe(type) { sawKeyframe = true }
            picture.append(nal)
        }

        // A changed parameter set means a new resolution: rebuild the format description, and
        // make the decoder rebuild its session against it on the next access unit.
        if newParameterSet { rebuildFormat() }

        // A config packet (presentation timestamp zero) carries parameter sets and no picture.
        guard !picture.isEmpty else { return }

        if sawKeyframe {
            awaitingKeyframe = false
        } else if awaitingKeyframe {
            framesBeforeKeyframe += 1
            return
        }

        guard let format else { return }
        guard let sample = makeSampleBuffer(AnnexB.lengthPrefixed(picture), format: format) else {
            return
        }
        let status = decoder.decode(sample)
        if status == kVTVideoDecoderBadDataErr {
            // The data was bad, not the session — rebuilding it would not help. What does help
            // is a clean restart of the reference chain: drop everything until the next IRAP
            // instead of decoding damaged pictures against damaged pictures.
            awaitingKeyframe = true
        }
        framesEnqueued += 1
    }

    // MARK: - format description

    private func rebuildFormat() {
        let wanted = codec.parameterSetTypes
        let sets = wanted.compactMap { parameterSets[$0] }
        guard sets.count == wanted.count else { return }   // still waiting for one

        var desc: CMVideoFormatDescription?
        let status: OSStatus = withParameterSets(sets) { pointers, sizes in
            switch codec {
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &desc)
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc)
            }
        }
        guard status == noErr, let desc else {
            AppBuild.log("could not build \(codec.rawValue) format description (status \(status))")
            return
        }
        format = desc
        // Fresh parameter sets mean the reference chain restarts; wait for the IRAP that goes
        // with them rather than feeding the new session the tail of the old GOP.
        awaitingKeyframe = true
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        AppBuild.log("coded frame is \(Int(size.width))x\(Int(size.height)) \(codec.rawValue)")
        DispatchQueue.main.async { [weak self] in self?.onFormat?(size) }
    }

    /// Hold every parameter set as a C pointer for the duration of one call, rather than nesting
    /// withUnsafeBytes once per set.
    private func withParameterSets<R>(
        _ sets: [Data],
        _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        var owned: [UnsafeMutablePointer<UInt8>] = []
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        for set in sets {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: buf, count: set.count)
            owned.append(buf)
            pointers.append(UnsafePointer(buf))
            sizes.append(set.count)
        }
        defer { owned.forEach { $0.deallocate() } }
        return pointers.withUnsafeBufferPointer { pp in
            sizes.withUnsafeBufferPointer { ss in
                body(pp.baseAddress!, ss.baseAddress!)
            }
        }
    }

    private func makeSampleBuffer(_ payload: Data,
                                  format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else { return nil }

        status = payload.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!,
                                          blockBuffer: block,
                                          offsetIntoDestination: 0,
                                          dataLength: payload.count)
        }
        guard status == noErr else { return nil }

        // Nothing schedules on these — every access unit is decoded the moment it arrives and
        // shown as soon as it comes back — but VideoToolbox still wants strictly increasing
        // timing. The agent's own presentation timestamps are not used for the same reason.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: framesSubmitted, timescale: 60),
            decodeTimeStamp: .invalid)
        framesSubmitted += 1

        var sample: CMSampleBuffer?
        var size = payload.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { return nil }
        return sample
    }
}
