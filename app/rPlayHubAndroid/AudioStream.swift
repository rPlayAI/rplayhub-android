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
import CoreAudio
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

    /// Peak of the most recent decoded buffers, in dBFS (-inf for silence). Nobody can hear the
    /// Mac from a log, so this is how the path proves it carries signal: the health panel shows
    /// it, and the periodic log line below records it with the engine's state and output device.
    private(set) var peakDb: Float = -.infinity
    private var buffersSinceReport = 0
    private var windowPeak: Float = 0
    /// Opus payload bytes since the last report: music at 128 kbps is ~320 bytes a packet, an
    /// encoder fed silence emits a few bytes — which tells a silent capture from a broken decode.
    private var payloadBytesSinceReport = 0
    private var lastReport = Date()

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
                payloadBytesSinceReport += size
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
            AppBuild.log("audio: engine started, output device \"\(Self.defaultOutputDeviceName())\"")
        }
        meter(pcm)
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

    // MARK: - proof of signal

    private func meter(_ pcm: AVAudioPCMBuffer) {
        var peak: Float = 0
        if let channels = pcm.floatChannelData {
            for c in 0 ..< Int(pcm.format.channelCount) {
                let samples = UnsafeBufferPointer(start: channels[c], count: Int(pcm.frameLength))
                for v in samples { peak = max(peak, abs(v)) }
            }
        }
        // Peak over the reporting window (reset after each log line), so the number means
        // "the loudest sample since the last report" and silence reads as -inf, not a decay.
        windowPeak = max(windowPeak, peak)
        peakDb = windowPeak > 0 ? 20 * log10(windowPeak) : -.infinity
        buffersSinceReport += 1
        if Date().timeIntervalSince(lastReport) >= 30 {
            lastReport = Date()
            AppBuild.log(String(format: "audio: %d pkts, %d buffers/30s, avg %d B/pkt, peak %.0f dBFS, engine %@, player %@, dropped %d",
                                packetsReceived, buffersSinceReport,
                                payloadBytesSinceReport / max(buffersSinceReport, 1), peakDb,
                                engine.isRunning ? "running" : "STOPPED",
                                player.isPlaying ? "playing" : "STOPPED", packetsDropped))
            buffersSinceReport = 0
            payloadBytesSinceReport = 0
            windowPeak = 0
        }
    }

    /// The system default output device, which is where AVAudioEngine renders.
    private static func defaultOutputDeviceName() -> String {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr else { return "?" }
        var name: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return "?" }
        return name as String
    }
}
