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

final class AgentSession {
    enum State: Equatable {
        case idle
        case deploying(String)
        case running
        case failed(String)
    }

    static let devicePathBase = "/data/local/tmp/.studio"
    static let jarName = "screen-sharing-agent.jar"
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

        let soPath = "\(agentDir)/\(abi)/\(Self.soName)"
        guard FileManager.default.fileExists(atPath: soPath) else {
            throw AdbError.failed("no \(Self.soName) built for \(abi) in \(agentDir)")
        }

        state = .deploying("pushing the agent")
        // chown so the agent can be launched as shell even when adb is running as root — a rooted
        // push lands as root and app_process then cannot read it.
        _ = try? Adb.shell(serial, "mkdir -p \(Self.devicePathBase)")
        try Adb.push(serial, localPath: "\(agentDir)/\(Self.jarName)",
                     remotePath: "\(Self.devicePathBase)/\(Self.jarName)", mode: 0o644)
        try Adb.push(serial, localPath: soPath,
                     remotePath: "\(Self.devicePathBase)/\(Self.soName)", mode: 0o755)
        _ = try? Adb.shell(serial, "chown shell:shell \(Self.devicePathBase) \(Self.devicePathBase)/*")

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
        let command = "CLASSPATH=\(Self.devicePathBase)/\(Self.jarName)"
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

    func stop() {
        stopping = true
        teardown()
        state = .idle
    }

    private func teardown() {
        control?.stop()
        video?.stop()
        sensor?.stop()
        control = nil
        video = nil
        sensor = nil
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

/// The control channel. Writes are serialised onto one queue; the agent's replies are drained and
/// discarded, which is not optional — an unread socket eventually blocks the agent's writer and
/// with it the thread that also drives input injection.
final class ControlSender {
    private let socket: TCPSocket
    private let queue = DispatchQueue(label: "rplayhub.android.control")
    private var reader: Thread?
    private var stopping = false

    private(set) var messagesSent = 0

    init(socket: TCPSocket) {
        self.socket = socket
    }

    func start() {
        socket.setReadTimeout(2)
        let t = Thread { [weak self] in
            while true {
                guard let self, !self.stopping else { return }
                do { _ = try self.socket.read() } catch { return }
            }
        }
        t.name = "rplayhub.android.controlreader"
        reader = t
        t.start()
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
