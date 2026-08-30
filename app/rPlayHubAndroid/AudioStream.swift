//
//  AudioStream.swift
//  Device audio on the Mac's speakers — the audio channel, decoded and played.
//
//  The agent captures device playback (AudioRecord remote-submix capture; all upstream code),
//  encodes 48 kHz stereo Opus, and writes each encoded packet as a 4-byte little-endian header
//  — sign bit marks a codec config packet, low 31 bits are the payload size — followed by the
//  payload. Streaming starts and stops by control message (StartAudioStream / StopAudioStream),
//  so forwarding toggles live without touching the session.
//
//  Decoding is AVAudioConverter with a kAudioFormatOpus source; playback is one
//  AVAudioPlayerNode fed buffer by buffer. If playback falls behind the stream — a stall, a
//  paused engine — buffers are dropped once more than half a second is queued: live mirroring
//  wants low latency, never a growing backlog.
//

import AVFoundation
import Foundation

final class AudioStream {
    private let socket: TCPSocket
    private var thread: Thread?
    private var stopping = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var opusFormat: AVAudioFormat?
    private let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var engineReady = false

    /// Reader thread writes, anyone reads — the health panel shows these.
    private(set) var packetsReceived = 0
    private(set) var packetsDropped = 0
    private(set) var lastError: String?

    /// Scheduled minus played, in frames, for the latency cap.
    private var framesScheduled: Int64 = 0

    init(socket: TCPSocket) {
        self.socket = socket
    }

    func start() {
        stopping = false
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "rplayhub.android.audio"
        thread = t
        t.start()
    }

    /// Stops playback but keeps reading — the agent stops sending on StopAudioStream, and
    /// keeping the reader alive means forwarding can turn back on without a new session.
    func pause() {
        player.stop()
        framesScheduled = 0
    }

    func stop() {
        stopping = true
        socket.shutdownAndClose()
        if engineReady {
            player.stop()
            engine.stop()
        }
    }

    // MARK: - the loop

    private func readLoop() {
        do {
            while !stopping {
                let headerData = try socket.readFully(4)
                let raw = headerData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
                let isConfig = raw & 0x8000_0000 != 0
                let size = Int(raw & 0x7FFF_FFFF)
                guard size > 0, size < 1 << 20 else {
                    if size != 0 { throw AdbError.protocolError("implausible audio packet size \(size)") }
                    continue
                }
                let payload = try socket.readFully(size)
                packetsReceived += 1
                if isConfig {
                    configure(with: payload)
                } else if let pcm = decode(payload) {
                    play(pcm)
                }
            }
        } catch {
            if !stopping { AppBuild.log("audio stream ended: \(error)") }
        }
    }

    /// The config packet is the Opus identification header ("OpusHead"). AudioConverter can
    /// decode standard stereo without it, but it is the proper magic cookie, so pass it along.
    private func configure(with payload: Data) {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0,
            mReserved: 0)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            lastError = "could not describe the Opus stream"
            return
        }
        opusFormat = format
        guard let made = AVAudioConverter(from: format, to: pcmFormat) else {
            lastError = "no Opus decoder available"
            AppBuild.log("audio: AVAudioConverter refused Opus -> PCM")
            return
        }
        if payload.starts(with: Array("OpusHead".utf8)) {
            made.magicCookie = payload
        }
        converter = made
        AppBuild.log("audio: Opus decoder ready (config \(payload.count) bytes)")
    }

    private func decode(_ payload: Data) -> AVAudioPCMBuffer? {
        guard let converter, let opusFormat else { return nil }
        let compressed = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1,
                                                 maximumPacketSize: payload.count)
        payload.withUnsafeBytes { raw in
            compressed.data.copyMemory(from: raw.baseAddress!, byteCount: payload.count)
        }
        compressed.byteLength = UInt32(payload.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(payload.count))

        // One Opus packet is 960 frames at 48 kHz; leave room in case the encoder ever sends more.
        guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 4096) else { return nil }
        var handedOver = false
        var conversionError: NSError?
        let status = converter.convert(to: pcm, error: &conversionError) { _, outStatus in
            if handedOver {
                outStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            outStatus.pointee = .haveData
            return compressed
        }
        if status == .error {
            lastError = "audio decode failed: \(conversionError?.localizedDescription ?? "?")"
            return nil
        }
        return pcm.frameLength > 0 ? pcm : nil
    }

    private func play(_ pcm: AVAudioPCMBuffer) {
        if !engineReady {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
            do {
                try engine.start()
            } catch {
                lastError = "audio engine failed: \(error)"
                AppBuild.log("audio: engine start failed: \(error)")
                return
            }
            engineReady = true
        }
        if !player.isPlaying {
            player.play()
            framesScheduled = 0
        }

        // The latency cap. playerTime is nil until the node has rendered once.
        if let nodeTime = player.lastRenderTime,
           let playerTime = player.playerTime(forNodeTime: nodeTime) {
            let queued = framesScheduled - playerTime.sampleTime
            if queued > 24000 {   // half a second at 48 kHz
                packetsDropped += 1
                return
            }
        }
        framesScheduled += Int64(pcm.frameLength)
        player.scheduleBuffer(pcm)
    }
}
