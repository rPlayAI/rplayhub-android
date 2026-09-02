//
//  EmulatorSession.swift
//  Hosting an Android Emulator the way Android Studio's embedded emulator does: the engine runs
//  headless (-no-window -grpc), its display is streamed and its input injected over the
//  EmulatorController gRPC — no virtual display, no on-device agent, and adb stays open in
//  parallel so tools can act on the same instance.
//
//  grpc-swift never links into the app. The bundled `emulator-bridge` subprocess talks gRPC and
//  bridges it over stdio: frames come out as [4-byte BE length][PNG]; input goes in as JSON lines.
//

import Accelerate
import AppKit
import CoreVideo
import ImageIO

final class EmulatorSession {
    /// A frame ready for the mirror's display layer, its pixel size, and the display's native
    /// size oriented like the frame (equal to the frame's when the stream is not scaled) — what
    /// input coordinates must be expressed in.
    var onFrame: ((CVPixelBuffer, CGSize, CGSize) -> Void)?
    /// The bridge ended (emulator gone, gRPC refused…). Not called after `stop()`.
    var onExit: ((String) -> Void)?

    let port: Int
    /// Scaled RGB888 frames fitted to this size (Studio's model: the stream is the view's size,
    /// re-requested on resize) instead of whole-display PNGs. nil = the PNG path.
    let scaledTo: CGSize?
    private let bridgeURL: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var stopped = false
    private let queue = DispatchQueue(label: "ai.rplay.rplayhub.emulator-frames")

    init(bridge: URL, port: Int, scaledTo: CGSize? = nil) {
        bridgeURL = bridge
        self.port = port
        self.scaledTo = scaledTo
    }

    // MARK: - discovery

    /// The emulator writes a discovery file per running instance — the same files Android
    /// Studio reads to find an emulator's gRPC endpoint. `port.serial` is the console port that
    /// makes up the adb serial (`emulator-5554`), `grpc.port` the endpoint to host it through.
    static func discoverGrpcPort(serial: String) -> Int? {
        if let env = ProcessInfo.processInfo.environment["RPLAYHUB_EMU_PORT"], let p = Int(env) {
            return p
        }
        guard serial.hasPrefix("emulator-"), let console = Int(serial.dropFirst("emulator-".count))
        else { return nil }
        for dir in discoveryDirs {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
            else { continue }
            for name in names where name.hasPrefix("pid_") && name.hasSuffix(".ini") {
                guard let text = try? String(contentsOf: dir.appendingPathComponent(name),
                                             encoding: .utf8) else { continue }
                var serialPort: Int?, grpcPort: Int?
                for line in text.split(separator: "\n") {
                    let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard kv.count == 2 else { continue }
                    if kv[0] == "port.serial" { serialPort = Int(kv[1]) }
                    if kv[0] == "grpc.port" { grpcPort = Int(kv[1]) }
                }
                if serialPort == console, let grpcPort { return grpcPort }
            }
        }
        return nil
    }

    private static var discoveryDirs: [URL] {
        var dirs: [URL] = []
        let env = ProcessInfo.processInfo.environment
        if let runtime = env["XDG_RUNTIME_DIR"] {
            dirs.append(URL(fileURLWithPath: runtime).appendingPathComponent("avd/running"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        dirs.append(home.appendingPathComponent("Library/Caches/TemporaryItems/avd/running"))
        dirs.append(home.appendingPathComponent(".android/avd/running"))
        return dirs
    }

    /// The bridge binary: bundled next to adb in Contents/MacOS, or `RPLAYHUB_EMU_BRIDGE` for a
    /// development build that has no bundle phase.
    static var bridgeURL: URL? {
        if let env = ProcessInfo.processInfo.environment["RPLAYHUB_EMU_BRIDGE"],
           FileManager.default.isExecutableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/emulator-bridge")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }

    // MARK: - lifecycle

    func start() {
        process.executableURL = bridgeURL
        var arguments = [String(port)]
        if let scaledTo { arguments += ["--rgb", "\(Int(scaledTo.width))x\(Int(scaledTo.height))"] }
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self] p in
            guard let self, !self.stopped else { return }
            self.onExit?("emulator bridge exited (\(p.terminationStatus))")
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            // EOF keeps signalling readable; drop the handler or it spins.
            guard let self, !chunk.isEmpty else { h.readabilityHandler = nil; return }
            self.queue.async { self.consume(chunk) }
        }
        // A write into a bridge that just died must not take the app down with it.
        signal(SIGPIPE, SIG_IGN)
        do {
            try process.run()
            AppBuild.log("emulator: bridge up on gRPC :\(port)")
        } catch {
            onExit?("could not start the emulator bridge: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopped = true
        output.fileHandleForReading.readabilityHandler = nil
        send(#"{"quit":true}"#)
        if process.isRunning { process.terminate() }
    }

    // MARK: - frames

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard buffer.count >= 4 + length else { return }
            let payload = buffer.subdata(in: 4 ..< 4 + length)
            buffer.removeSubrange(0 ..< 4 + length)
            if scaledTo != nil {
                if let (picture, size, native) = Self.unpackRGB(payload) {
                    adoptParity(fromFrameLandscape: size.width > size.height)
                    onFrame?(picture, size, native)
                }
            } else if let (picture, size) = Self.decode(payload) {
                adoptParity(fromFrameLandscape: size.width > size.height)
                onFrame?(picture, size, size)
            }
        }
    }

    /// Ask for the stream at a new size (the bridge restarts it). Scaled mode only.
    func setSize(_ size: CGSize) {
        guard scaledTo != nil else { return }
        send(#"{"size":{"w":\#(Int(size.width)),"h":\#(Int(size.height))}}"#)
    }

    /// `[w][h][nativeW][nativeH]` (big-endian) + RGB888 → a BGRA pixel buffer via vImage. No
    /// codec on either side: the engine scales and copies, we swizzle.
    private static func unpackRGB(_ d: Data) -> (CVPixelBuffer, CGSize, CGSize)? {
        guard d.count >= 16 else { return nil }
        func u32(_ i: Int) -> Int { d[i ..< i + 4].reduce(0) { ($0 << 8) | Int($1) } }
        let w = u32(0), h = u32(4), nw = u32(8), nh = u32(12)
        guard w > 0, h > 0, d.count >= 16 + w * h * 3 else { return nil }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
                == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let ok: Bool = d.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base + 16),
                                    height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 3)
            var dst = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb),
                                    height: vImagePixelCount(h), width: vImagePixelCount(w),
                                    rowBytes: CVPixelBufferGetBytesPerRow(pb))
            return vImageConvert_RGB888toBGRA8888(&src, nil, 255, &dst, false, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard ok else { return nil }
        // The native size, oriented like the frame: a rotated guest streams landscape, and input
        // coordinates live in that rotated framebuffer.
        var native = CGSize(width: nw, height: nh)
        if (w > h) != (nw > nh) { native = CGSize(width: nh, height: nw) }
        return (pb, CGSize(width: w, height: h), native)
    }

    /// PNG → BGRA pixel buffer, the same kind the video decoder hands the display layer.
    private static func decode(_ png: Data) -> (CVPixelBuffer, CGSize)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
                == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (pb, CGSize(width: w, height: h))
    }

    // MARK: - input (Studio's model: everything over EmulatorController)

    func sendTouch(x: Int32, y: Int32, down: Bool, display: Int32 = 0) {
        send(#"{"touch":{"x":\#(x),"y":\#(y),"down":\#(down),"display":\#(display)}}"#)
    }

    func press(_ domKey: String) { send(#"{"press":"\#(domKey)"}"#) }

    func type(_ text: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["text": text]),
              let line = String(data: data, encoding: .utf8) else { return }
        send(line)
    }

    /// Which quadrant the emulator is currently turned to (0 portrait, 1 landscape…).
    ///
    /// The session has to own this. `setPhysicalModel(ROTATION, …)` takes an ABSOLUTE angle, and
    /// nothing tells us the guest's orientation on the way back: a hosted emulator sends frames,
    /// not the agent's packet header, so `MirrorView.displayOrientation` stays 0 for ever. Asking
    /// the mirror for the current quadrant therefore always answered 0, every Rotate press sent
    /// the same -90, and the picture turned once and then stuck.
    private(set) var rotationQuadrant = 0

    /// Line the counter up with what is actually on screen, once, when hosting starts.
    ///
    /// The guest cannot be asked: `setPhysicalModel(ROTATION, …)` turns the emulator's own
    /// presentation, and Android inside never re-lays-out for it — while the stream is landscape
    /// the guest still reports `mRotation=ROTATION_0` and `wm size` still says portrait. What the
    /// frame does tell us is parity: a landscape frame means an odd quadrant. That is enough to
    /// keep one Rotate button honest when we attach to an emulator someone already turned.
    private var adoptedParity = false

    func adoptParity(fromFrameLandscape landscape: Bool) {
        guard !adoptedParity else { return }
        adoptedParity = true
        let isOdd = rotationQuadrant % 2 == 1
        if landscape != isOdd { rotationQuadrant = landscape ? 1 : 0 }
    }

    /// Rotation quadrant as the mirror counts it (0 portrait, 1 landscape…), in the emulator's
    /// physical-model degrees.
    func rotate(toQuadrant q: Int) {
        let quadrant = ((q % 4) + 4) % 4
        rotationQuadrant = quadrant
        send(#"{"rotate":\#(-90 * quadrant)}"#)
    }

    /// A control-strip button, by the DOM key value the emulator's key sender understands.
    /// `currentOrientation` is the mirror's idea of the angle; rotation ignores it deliberately.
    func perform(_ action: ControlStrip.Action, currentOrientation: Int) {
        switch action {
        case .back:       press("GoBack")
        case .home:       press("GoHome")
        case .overview:   press("AppSwitch")
        case .power:      press("Power")
        case .volumeUp:   press("AudioVolumeUp")
        case .volumeDown: press("AudioVolumeDown")
        // Advance from what we last set, not from the mirror: see `rotationQuadrant`.
        case .rotate:     rotate(toQuadrant: rotationQuadrant + 1)
        case .screenshot, .record: break        // over adb, handled by the caller
        }
    }

    /// The keyboard keys the mirror maps to Android keycodes, in DOM key values.
    static func domKey(for keycode: Int32) -> String? {
        switch keycode {
        case AndroidKey.back:       return "GoBack"
        case AndroidKey.home:       return "GoHome"
        case AndroidKey.appSwitch:  return "AppSwitch"
        case AndroidKey.del:        return "Backspace"
        case AndroidKey.forwardDel: return "Delete"
        case AndroidKey.enter:      return "Enter"
        case AndroidKey.tab:        return "Tab"
        case AndroidKey.dpadLeft:   return "ArrowLeft"
        case AndroidKey.dpadRight:  return "ArrowRight"
        case AndroidKey.dpadUp:     return "ArrowUp"
        case AndroidKey.dpadDown:   return "ArrowDown"
        case AndroidKey.moveHome:   return "Home"
        case AndroidKey.moveEnd:    return "End"
        default:                    return nil
        }
    }

    private func send(_ line: String) {
        guard process.isRunning else { return }
        input.fileHandleForWriting.write(Data((line + "\n").utf8))
    }
}
