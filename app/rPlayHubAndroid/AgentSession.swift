//
//  AgentSession.swift
//  Deploy the agent, get it talking, and own the two channels for as long as it runs.
//
//  This is the whole of what Android Studio's DeviceClient does, minus audio, clipboard and XR.
//  There is no separate engine process the way ~/rplay-hub has one: the iOS tunnel needs root, so
//  the privileged half had to live outside the app. adb needs nothing, so the app owns the lot.
//
//  Sequence, from `DeviceClient.kt`:
//
//    1. push screen-sharing-agent.jar and libscreen-sharing-agent.so to /data/local/tmp/.studio
//    2. listen on loopback:0, take the port the kernel gave us
//    3. adb reverse localabstract:screen-sharing-agent-<port> -> tcp:<port>
//    4. adb shell CLASSPATH=... app_process ... --socket=screen-sharing-agent-<port>
//    5. accept two connections, read one marker byte from each ('V' video, 'C' control)
//
//  app_process is the load-bearing part: it runs the agent as SHELL uid, which is what grants
//  INJECT_EVENTS and access to the hidden system services it captures the display through. No
//  root, no install, nothing left behind but two files in /data/local/tmp.
//

import Foundation
import CryptoKit

final class AgentSession {
    enum State: Equatable {
        case idle
        case deploying(String)
        case running
        case failed(String)
    }

    static let devicePathBase = "/data/local/tmp/.studio"
    static let jarName = "screen-sharing-agent.jar"
    /// A second copy of the jar for the tools that run from it outside the agent (AppLabel, via
    /// app_process). The agent DELETES its own files from devicePathBase once it is up (Studio's
    /// RemoveAgentFiles), so anything launched from there after that point aborts; this path is
    /// the agent's business to leave alone.
    static let toolsJarRemote = "/data/local/tmp/.rplayhub/screen-sharing-agent.jar"
    static let soName = "libscreen-sharing-agent.so"

    let serial: String
    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            let s = state
            DispatchQueue.main.async { [weak self] in self?.onState?(s) }
        }
    }

    /// Main queue.
    var onState: ((State) -> Void)?
    /// A line of the agent's own log, main queue.
    var onAgentLog: ((String) -> Void)?

    private(set) var video: VideoStream?
    private(set) var control: ControlSender?
    /// Device orientation, when the agent build has our sensor channel. Nil on older builds.
    private(set) var sensor: SensorStream?
    /// Device audio playback, created on first use — see `setAudioForwarding`.
    private(set) var audio: AudioStream?
    let decoder = VideoDecoder()

    private var listener: TCPListener?
    private var agentShell: TCPSocket?
    /// Held open but never read. The agent opens an audio channel unconditionally on API 31+
    /// (agent.cc, feature_level_ >= 31) whatever the flags say, and only *streams* audio if
    /// STREAM_AUDIO is set — which we never set. Closing it instead would take the agent's
    /// writer down with it, so it is simply parked here for the life of the session.
    private var audioSocket: TCPSocket?
    private var socketName = ""
    private var logThread: Thread?
    private var stopping = false

    init(serial: String) {
        self.serial = serial
    }

    // MARK: - agent artifacts

    /// Where the built agent lives. In order: an explicit override, then the app bundle, then the
    /// checkout's own build output — so a developer who has just run the agent's gradle build
    /// does not have to configure anything.
    ///
    /// The directory must hold `screen-sharing-agent.jar` and `<abi>/libscreen-sharing-agent.so`.
    /// See `tools/build-agent.sh`, which produces exactly that layout from the vendored source.
    static func agentDirectory() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["RPLAYHUB_AGENT_DIR"], !override.isEmpty {
            candidates.append(override)
        }
        if let stored = UserDefaults.standard.string(forKey: "AgentDirectory"), !stored.isEmpty {
            candidates.append(stored)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("agent").path {
            candidates.append(bundled)
        }
        candidates.append(NSString(string: "~/rplay-hub-android/build/agent").expandingTildeInPath)
        return candidates.first { fm.fileExists(atPath: $0 + "/" + jarName) }
    }

    /// flags.h values.
    private static let flagStartVideoStream: Int = 0x01
    private static let flagTurnOffDisplay: Int = 0x02
    private static let flagUseUInput: Int = 0x08
    /// Our addition (see PROVENANCE.md): stream rotation vector quaternions on a fourth channel.
    private static let flagStreamOrientation: Int = 0x100

    /// START_VIDEO_STREAM is not optional: without it the agent comes up, connects its channels
    /// and streams nothing until asked, which reads exactly like a broken pipeline.
    ///
    /// USE_UINPUT is deliberately NOT set. On API 37 it routes input through a virtual drawing
    /// tablet, and on a Pixel 9a that tablet is created — the UI_ABS_SETUP ioctls all log
    /// cleanly, with axis ranges matching the display — but it never appears in /dev/input, so
    /// every touch is silently dropped. `getevent -p` lists only the four real devices. Plain
    /// InputManager injection works there, so this stays off; override to experiment.
    private func agentFlags(featureLevel: Int) -> Int {
        if let override = ProcessInfo.processInfo.environment["RPLAYHUB_AGENT_FLAGS"],
           let value = Int(override) { return value }
        // The sensor channel rides the twin gate: with the feature off, the agent is asked for
        // exactly what it always was. Screen-off is scrcpy's --turn-screen-off: the agent
        // blanks the panel while mirroring and restores it when the session ends.
        return Self.flagStartVideoStream
            | (AppBuild.twinEnabled ? Self.flagStreamOrientation : 0)
            | (UserDefaults.standard.bool(forKey: "TurnScreenOffWhileMirroring")
                   ? Self.flagTurnOffDisplay : 0)
    }

    // MARK: - lifecycle

    func start(maxVideoSize: CGSize) {
        state = .deploying("looking for the device")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.bringUp(maxVideoSize: maxVideoSize)
            } catch {
                AppBuild.log("session failed: \(error)")
                self.state = .failed("\(error)")
                self.teardown()
            }
        }
    }

    /// Push the agent jar + native lib, skipping the transfer when the device already holds
    /// byte-identical copies. Safe to call speculatively: when a ready device is selected we run
    /// this in the background so a later View Screen click finds the files already in place and
    /// pays only for app_process start-up, not the push. Idempotent and cheap on a warm device
    /// (two md5 checks), a full push on a cold one.
    static func predeploy(serial: String) throws {
        guard let agentDir = agentDirectory() else {
            throw AdbError.failed("no built agent found — run tools/build-agent.sh, or set RPLAYHUB_AGENT_DIR")
        }
        let abi = try Adb.getprop(serial, "ro.product.cpu.abi")
        try deployBinaries(serial: serial, agentDir: agentDir, abi: abi)
    }

    static func deployBinaries(serial: String, agentDir: String, abi: String) throws {
        let jarLocal = "\(agentDir)/\(jarName)"
        let soLocal = "\(agentDir)/\(abi)/\(soName)"
        guard FileManager.default.fileExists(atPath: soLocal) else {
            throw AdbError.failed("no \(soName) built for \(abi) in \(agentDir)")
        }
        let jarRemote = "\(devicePathBase)/\(jarName)"
        let soRemote = "\(devicePathBase)/\(soName)"
        if !deployedMatches(serial: serial, pairs: [(jarLocal, toolsJarRemote)]) {
            _ = try? Adb.shell(serial, "mkdir -p \((toolsJarRemote as NSString).deletingLastPathComponent)")
            try Adb.push(serial, localPath: jarLocal, remotePath: toolsJarRemote, mode: 0o644)
        }
        if deployedMatches(serial: serial, pairs: [(jarLocal, jarRemote), (soLocal, soRemote)]) {
            return
        }
        // chown so the agent can be launched as shell even when adb is running as root — a rooted
        // push lands as root and app_process then cannot read it.
        _ = try? Adb.shell(serial, "mkdir -p \(devicePathBase)")
        try Adb.push(serial, localPath: jarLocal, remotePath: jarRemote, mode: 0o644)
        try Adb.push(serial, localPath: soLocal, remotePath: soRemote, mode: 0o755)
        _ = try? Adb.shell(serial, "chown shell:shell \(devicePathBase) \(devicePathBase)/*")
    }

    /// True only when every remote file's md5 matches its local source, so a skip is safe even if
    /// a previous push was interrupted or the artifacts were rebuilt. Any failure (no `md5sum`,
    /// missing file) reads as "not matched" and falls through to a normal push.
    private static func deployedMatches(serial: String, pairs: [(local: String, remote: String)]) -> Bool {
        for (local, remote) in pairs {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: local)) else { return false }
            let localMD5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard let out = try? Adb.shell(serial, "md5sum \(Adb.shellQuote(remote)) 2>/dev/null"),
                  let remoteMD5 = out.split(whereSeparator: { $0 == " " || $0 == "\n" }).first
                      .map(String.init),
                  remoteMD5 == localMD5 else { return false }
        }
        return true
    }

    private func bringUp(maxVideoSize: CGSize) throws {
        guard let agentDir = Self.agentDirectory() else {
            throw AdbError.failed(
                "no built agent found — run tools/build-agent.sh, or set RPLAYHUB_AGENT_DIR")
        }

        let abi = try Adb.getprop(serial, "ro.product.cpu.abi")
        let sdk = Int(try Adb.getprop(serial, "ro.build.version.sdk")) ?? 0
        AppBuild.log("device \(serial): abi=\(abi) sdk=\(sdk)")
        guard sdk >= 26 else {
            throw AdbError.failed("the agent needs API 26 or newer; this device reports \(sdk)")
        }

        state = .deploying("pushing the agent")
        // Idempotent: skips the transfer when the device already holds these exact files — which
        // it does whenever the selection pre-warmed it (see deployBinaries). The push is the slow
        // part over wifi, so this is usually where the click's latency disappears.
        try Self.deployBinaries(serial: serial, agentDir: agentDir, abi: abi)

        state = .deploying("opening the tunnel")
        let listener = TCPListener()
        try listener.open()
        self.listener = listener
        // The port is in the name only to keep concurrent sessions from colliding — the agent
        // treats it as an opaque string.
        socketName = "screen-sharing-agent-\(listener.port)"
        try Adb.reverse(serial, localAbstract: socketName, toPort: listener.port)
        AppBuild.log("reverse localabstract:\(socketName) -> tcp:\(listener.port)")

        state = .deploying("starting the agent")
        let maxSize = "\(Int(maxVideoSize.width)),\(Int(maxVideoSize.height))"
        // How the agent captures device audio (RPLAYHUB_AUDIO_SUBMIX, read by our patch in the
        // agent's audio_streamer.cc). 2 = an AudioRecord on the REMOTE_SUBMIX source, scrcpy's
        // capture, the default: upstream's API 34+ AudioPolicy loopback sink registers and reads
        // but yields only silence (3-byte DTX packets) on tegu (Pixel 9a / Android 17), and its
        // AAudio fallback (1) loses the route after ~13 s. 0 = upstream's behaviour unchanged.
        let submixEnv = ProcessInfo.processInfo.environment["RPLAYHUB_AUDIO_SUBMIX"] ?? "2"
        let audioPrefix = ["1", "2"].contains(submixEnv) ? "RPLAYHUB_AUDIO_SUBMIX=\(submixEnv) " : ""
        let command = "\(audioPrefix)CLASSPATH=\(Self.devicePathBase)/\(Self.jarName)"
            + " app_process \(Self.devicePathBase)"
            + " com.android.tools.screensharing.Main"
            + " --socket=\(socketName)"
            + " --max_size=\(maxSize)"
            + " --flags=\(agentFlags(featureLevel: sdk))"
            // "avc", not "h264": the agent builds its MediaCodec mime as "video/" + this, and
            // "video/avc" is the Android name. Read off agent.cc, which also shows the default
            // is vp8 — a codec VideoToolbox will not take through our path, so this is required
            // rather than a preference.
            + " --codec=avc"
            // "--log", not "--log_level". Studio's Kotlin calls the variable logLevelArg, which
            // is not the flag the agent parses.
            + " --log=\(ProcessInfo.processInfo.environment["RPLAYHUB_AGENT_LOG"] ?? "info")"
        AppBuild.log("launching: \(command)")
        agentShell = try Adb.shellStream(serial, command)
        startAgentLogReader()

        state = .deploying("waiting for the agent to connect")
        let flags = agentFlags(featureLevel: sdk)
        let channels = try acceptChannels(on: listener, featureLevel: sdk,
                                          expectSensor: flags & Self.flagStreamOrientation != 0)

        // The reverse can go now: connections already established keep working without it, and
        // leaving it installed leaks an abstract socket name on the device per session.
        try? Adb.reverseRemove(serial, localAbstract: socketName)
        listener.close()
        self.listener = nil

        channels.control.setNoDelay()
        let sender = ControlSender(socket: channels.control)
        sender.start()
        control = sender

        let stream = VideoStream(socket: channels.video, decoder: decoder)
        video = stream
        stream.start()

        if let sensorSocket = channels.sensor {
            let s = SensorStream(socket: sensorSocket)
            sensor = s
            s.start()
        }

        state = .running
        AppBuild.log("session up on \(serial)")
    }

    /// The agent dials back once per channel and identifies each with a single byte. Order is not
    /// guaranteed, so accept all of them and sort by marker.
    ///
    /// How many to expect is not a choice we get to make: the agent opens an audio channel on
    /// API 31+ whether or not anyone wants audio. Accepting only two leaves the third connection
    /// queued and the control channel unfound.
    private func acceptChannels(on listener: TCPListener, featureLevel: Int,
                                expectSensor: Bool) throws -> (video: TCPSocket, control: TCPSocket,
                                                               sensor: TCPSocket?) {
        var video: TCPSocket?
        var control: TCPSocket?
        var sensor: TCPSocket?
        let expected = (featureLevel >= 31 ? 3 : 2) + (expectSensor ? 1 : 0)
        for _ in 0..<expected {
            let socket: TCPSocket
            do {
                socket = try listener.accept(timeout: 20)
            } catch {
                // An agent built before the sensor channel connects one socket fewer than we
                // asked for. If the essentials arrived, run without orientation rather than
                // failing the whole session over a garnish.
                if video != nil, control != nil, expectSensor, sensor == nil {
                    AppBuild.log("agent opened no sensor channel — running without orientation")
                    break
                }
                throw error
            }
            socket.setReadTimeout(10)
            let marker = try socket.readFully(1)
            switch marker[marker.startIndex] {
            case UInt8(ascii: "V"): video = socket
            case UInt8(ascii: "C"): control = socket
            case UInt8(ascii: "A"): audioSocket = socket       // parked, see the property
            case UInt8(ascii: "S"): sensor = socket
            case let other:
                socket.shutdownAndClose()
                throw AdbError.protocolError("unexpected channel marker 0x\(String(other, radix: 16))")
            }
        }
        guard let video else { throw AdbError.protocolError("no video channel") }
        guard let control else { throw AdbError.protocolError("no control channel") }
        return (video, control, sensor)
    }

    /// The agent writes its log to stdout, which is our shell socket. Worth surfacing: when
    /// mirroring fails on a particular device, the reason is almost always in here.
    private func startAgentLogReader() {
        guard let shell = agentShell else { return }
        let t = Thread { [weak self] in
            var buffer = Data()
            while true {
                guard let self, !self.stopping else { return }
                do {
                    guard let chunk = try shell.read() else { continue }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        buffer = buffer.suffix(from: buffer.index(after: nl))
                        guard !line.isEmpty else { continue }
                        AppBuild.log("agent: \(line)")
                        DispatchQueue.main.async { [weak self] in self?.onAgentLog?(line) }
                    }
                } catch {
                    // `self` is already unwrapped by the guard at the top of the loop.
                    if !self.stopping {
                        AppBuild.log("agent shell closed: \(error)")
                        // The agent exiting is the end of the session, however healthy the
                        // sockets still look.
                        self.state = .failed("the agent exited")
                    }
                    return
                }
            }
        }
        t.name = "rplayhub.android.agentlog"
        logThread = t
        t.start()
    }

    /// Turn device-audio playback on or off, live. The audio channel is always open on API 31+;
    /// what starts and stops is the agent's capture (by control message) and our player. The
    /// reader survives a pause so forwarding can come back without a new session.
    func setAudioForwarding(_ enabled: Bool) {
        guard let control else { return }
        if enabled {
            guard let socket = audioSocket else {
                AppBuild.log("audio: no audio channel (device below API 31)")
                return
            }
            if audio == nil {
                let a = AudioStream(socket: socket)
                audio = a
                a.start()
            }
            control.send(ControlMessage.startAudioStream())
        } else {
            control.send(ControlMessage.stopAudioStream())
            audio?.pause()
        }
    }

    func stop() {
        stopping = true
        teardown()
        state = .idle
    }

    private func teardown() {
        control?.stop()
        video?.stop()
        sensor?.stop()
        audio?.stop()
        control = nil
        video = nil
        sensor = nil
        audio = nil
        listener?.close()
        listener = nil
        if !socketName.isEmpty {
            try? Adb.reverseRemove(serial, localAbstract: socketName)
            socketName = ""
        }
        audioSocket?.shutdownAndClose()
        audioSocket = nil
        agentShell?.shutdownAndClose()
        agentShell = nil
    }
}

/// The control channel. Writes are serialised onto one queue; the agent's messages back are
/// parsed on a reader thread — reading them is not optional even when nobody listens, since an
/// unread socket eventually blocks the agent's writer and with it the thread that also drives
/// input injection.
final class ControlSender {
    private let socket: TCPSocket
    private let queue = DispatchQueue(label: "rplayhub.android.control")
    private var reader: Thread?
    private var stopping = false

    private(set) var messagesSent = 0
    private(set) var notificationsReceived = 0

    /// The device's clipboard changed (only sent while clipboard sync is started). Main queue.
    var onClipboardChanged: ((String) -> Void)?

    /// One display the device reported: id, canonical size, rotation, and the agent's type code.
    struct DisplayDescriptor {
        let id: Int32
        let width: Int32
        let height: Int32
        let rotation: Int32
        let type: Int32
    }

    /// The answer to a DisplayConfigurationRequest. Main queue.
    var onDisplays: (([DisplayDescriptor]) -> Void)?

    init(socket: TCPSocket) {
        self.socket = socket
    }

    func start() {
        socket.setReadTimeout(0)   // messages arrive whenever they arrive; stop() breaks the read
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "rplayhub.android.controlreader"
        reader = t
        t.start()
    }

    // MARK: - reading the agent's messages

    /// Nothing on this channel is length-prefixed, so every message type the agent can send
    /// unprompted must be decoded field by field; one unknown type and the byte stream can no
    /// longer be framed. That is handled by giving up parsing, not the draining: the loop falls
    /// back to reading and discarding, which keeps the agent's writer unblocked.
    private func readLoop() {
        do {
            while !stopping {
                let type = try readVarint()
                switch Int(type) {
                case ControlMessage.typeErrorResponse:
                    _ = try readVarint()                     // request id
                    let message = try readBytesString()
                    AppBuild.log("agent error response: \(message)")
                case ControlMessage.typeDisplayConfigurationResponse:
                    _ = try readVarint()                     // request id
                    let count = try readVarint()
                    var displays: [DisplayDescriptor] = []
                    for _ in 0..<min(count, 64) {
                        displays.append(DisplayDescriptor(
                            id: Int32(bitPattern: try readVarint()),
                            width: Int32(bitPattern: try readVarint()),
                            height: Int32(bitPattern: try readVarint()),
                            rotation: Int32(bitPattern: try readVarint()),
                            type: Int32(bitPattern: try readVarint())))
                    }
                    let found = displays
                    DispatchQueue.main.async { [weak self] in self?.onDisplays?(found) }
                case ControlMessage.typeClipboardChanged:
                    let text = try readBytesString()
                    notificationsReceived += 1
                    DispatchQueue.main.async { [weak self] in self?.onClipboardChanged?(text) }
                case ControlMessage.typeSupportedDeviceStates:
                    let count = try readVarint()
                    for _ in 0..<count {
                        _ = try readVarint()                 // identifier
                        _ = try readBytesString()            // name
                        _ = try readVarint()                 // system properties
                        _ = try readVarint()                 // physical properties
                    }
                    _ = try readVarint()                     // current state id + 1
                case ControlMessage.typeDeviceState:
                    _ = try readVarint()
                case ControlMessage.typeDisplayAddedOrChanged:
                    for _ in 0..<7 { _ = try readVarint() }
                case ControlMessage.typeDisplayRemoved:
                    _ = try readVarint()
                case ControlMessage.typeXrPassthroughChanged:
                    _ = try socket.readFully(4)              // fixed32 float
                case ControlMessage.typeXrEnvironmentChanged, ControlMessage.typeXrInputUnavailable:
                    _ = try readVarint()
                default:
                    AppBuild.log("control channel: unknown message type \(type); draining from here on")
                    while !stopping { _ = try socket.read() }
                    return
                }
            }
        } catch {
            if !stopping { AppBuild.log("control channel reader ended: \(error)") }
        }
    }

    private func readVarint() throws -> UInt32 {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        while true {
            let data = try socket.readFully(1)
            let b = data[data.startIndex]
            result |= UInt32(b & 0x7F) &<< shift
            if b & 0x80 == 0 { return result }
            shift += 7
            guard shift < 35 else { throw AdbError.protocolError("runaway varint on the control channel") }
        }
    }

    /// The agent's WriteBytes: varint byte count, then that many UTF-8 bytes.
    private func readBytesString() throws -> String {
        let count = try readVarint()
        guard count < 8 << 20 else { throw AdbError.protocolError("implausible string size \(count)") }
        let data = count > 0 ? try socket.readFully(Int(count)) : Data()
        return String(decoding: data, as: UTF8.self)
    }

    func send(_ message: Data) {
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            do {
                try self.socket.writeAll(message)
                self.messagesSent += 1
            } catch {
                AppBuild.log("control write failed: \(error)")
            }
        }
    }

    func stop() {
        stopping = true
        socket.shutdownAndClose()
    }
}
