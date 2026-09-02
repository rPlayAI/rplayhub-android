// emulator-bridge: the app spawns this per emulator session. It connects to a running headless
// emulator's gRPC and bridges it to the app over stdio, so the app itself never links grpc-swift.
//
//   Protocol (app <-> bridge):
//     bridge -> app (stdout, binary): repeated frames, each = 4-byte BE length + payload.
//        PNG mode (default):  payload = PNG bytes of the whole display.
//        RGB mode (--rgb WxH): payload = [w:4][h:4][nativeW:4][nativeH:4] (all BE) + RGB888
//           pixels, w*h*3 bytes. The emulator scales the display to fit WxH (aspect kept; 0x0 =
//           native). nativeW/H is the display's real size, for mapping input back to it.
//     app -> bridge (stdin, text):    one JSON object per line:
//        {"touch":{"x":540,"y":1200,"down":true,"display":0}}   one finger; down:false releases
//        {"tap":{"x":540,"y":1200,"display":0}}                  press + release
//        {"press":"GoHome"}      DOM key value (GoBack, AppSwitch, Power, AudioVolumeUp, Enter …)
//        {"text":"hello"}        typed through the emulator's key sender
//        {"rotate":-90}          device rotation around Z in degrees (0 portrait, -90 landscape)
//        {"size":{"w":730,"h":1640}}  RGB mode: restart the stream scaled to fit a new size
//        {"key":"KEYCODE_HOME"}  legacy; {"quit":true}
//
//   usage: emulator-bridge <grpc-port> [--rgb <w>x<h>]
import Foundation
import EmulatorTransport

let port = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 8554 : 8554
let rgbSize: (UInt32, UInt32)? = {
    guard let i = CommandLine.arguments.firstIndex(of: "--rgb"), i + 1 < CommandLine.arguments.count
    else { return nil }
    let parts = CommandLine.arguments[i + 1].split(separator: "x").compactMap { UInt32($0) }
    return parts.count == 2 ? (parts[0], parts[1]) : (0, 0)
}()

// stdout: length-prefixed frames. FileHandle write is safe from one task.
let out = FileHandle.standardOutput
func emitFrame(_ data: Data) {
    var len = UInt32(data.count).bigEndian
    out.write(Data(bytes: &len, count: 4))
    out.write(data)
}
func emitRGB(_ pixels: Data, _ w: UInt32, _ h: UInt32, _ nw: UInt32, _ nh: UInt32) {
    var header = Data(capacity: 16)
    for v in [w, h, nw, nh] { var be = v.bigEndian; header.append(Data(bytes: &be, count: 4)) }
    var len = UInt32(16 + pixels.count).bigEndian
    out.write(Data(bytes: &len, count: 4))
    out.write(header)
    out.write(pixels)
}
func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// The size the RGB stream is scaled to, and the task streaming it — a size change cancels the
/// stream so the main loop restarts it at the new size (Studio re-requests on resize the same way).
actor StreamControl {
    var size: (UInt32, UInt32)
    var restart = false
    private var task: Task<Void, Error>?
    init(size: (UInt32, UInt32)) { self.size = size }
    func request(_ w: UInt32, _ h: UInt32) {
        guard (w, h) != size else { return }
        size = (w, h); restart = true
        task?.cancel()
    }
    func run(_ t: Task<Void, Error>) { restart = false; task = t }
}
let control = StreamControl(size: rgbSize ?? (0, 0))

@Sendable func handleCommand(_ line: String,
    _ c: EmulatorController.Client<GRPCNIOTransportHTTP2.HTTP2ClientTransport.Posix>) async {
    guard let d = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
    do {
        if let t = obj["touch"] as? [String: Any],
           let x = t["x"] as? Int, let y = t["y"] as? Int {
            try await EmulatorTransport.touch(c, x: Int32(x), y: Int32(y),
                                              down: t["down"] as? Bool ?? true,
                                              display: Int32(t["display"] as? Int ?? 0))
        } else if let t = obj["tap"] as? [String: Any],
           let x = t["x"] as? Int, let y = t["y"] as? Int {
            try await EmulatorTransport.tap(c, x: Int32(x), y: Int32(y),
                                            display: Int32(t["display"] as? Int ?? 0))
        } else if let k = obj["press"] as? String {
            try await EmulatorTransport.pressKey(c, k)
        } else if let s = obj["text"] as? String {
            try await EmulatorTransport.typeText(c, s)
        } else if let z = obj["rotate"] as? Double {
            try await EmulatorTransport.rotate(c, degreesZ: Float(z))
        } else if let sz = obj["size"] as? [String: Any], rgbSize != nil,
                  let w = sz["w"] as? Int, let h = sz["h"] as? Int {
            await control.request(UInt32(max(0, w)), UInt32(max(0, h)))
        } else if let k = obj["key"] as? String {
            try await EmulatorTransport.key(c, k)
        } else if obj["quit"] != nil {
            exit(0)
        }
    } catch { log("bridge: command failed: \(error)") }
}

import GRPCNIOTransportHTTP2

do {
    try await EmulatorTransport.withController(port: port) { c in
        // input reader
        let input = Task {
            for try await line in FileHandle.standardInput.bytes.lines {
                await handleCommand(line, c)
            }
        }
        defer { input.cancel() }
        guard rgbSize != nil else {
            log("bridge: streaming display (PNG) from emulator gRPC :\(port)")
            try await EmulatorTransport.streamScreenshots(c, format: .png) { data, _, _ in
                emitFrame(data)
            }
            return
        }
        // The display's real size, for the app to map input back to. If the emulator will not
        // say, the first frame at native scale fills it in.
        var native: (UInt32, UInt32) = (0, 0)
        let displays = (try? await EmulatorTransport.displayConfigurations(c)) ?? []
        if let d = displays.first(where: { $0.display == 0 }) ?? displays.first {
            native = (d.width, d.height)
        }
        log("bridge: streaming display (RGB888) from emulator gRPC :\(port), native \(native.0)x\(native.1)")
        repeat {
            let (w, h) = await control.size
            let n = native
            let t = Task {
                try await EmulatorTransport.streamScreenshots(c, format: .rgb888, width: w, height: h) { data, fw, fh in
                    var nn = n
                    if nn.0 == 0 { nn = (fw, fh) }
                    emitRGB(data, fw, fh, nn.0, nn.1)
                }
            }
            await control.run(t)
            do { try await t.value } catch {
                if await !control.restart { throw error }   // a real end; a restart cancels
            }
        } while await control.restart
    }
} catch {
    log("bridge: \(error)")
    exit(1)
}
