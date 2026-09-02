// emulator-bridge: the app spawns this per emulator session. It connects to a running headless
// emulator's gRPC and bridges it to the app over stdio, so the app itself never links grpc-swift.
//
//   Protocol (app <-> bridge):
//     bridge -> app (stdout, binary): repeated frames, each = 4-byte BE length + PNG bytes.
//     app -> bridge (stdin, text):    one JSON object per line:
//        {"tap":{"x":540,"y":1200,"display":0}}   {"key":"KEYCODE_HOME"}   {"quit":true}
//
//   usage: emulator-bridge <grpc-port>
import Foundation
import EmulatorTransport

let port = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 8554 : 8554

// stdout: length-prefixed frames. FileHandle write is safe from one task.
let out = FileHandle.standardOutput
func emitFrame(_ data: Data) {
    var len = UInt32(data.count).bigEndian
    out.write(Data(bytes: &len, count: 4))
    out.write(data)
}
func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

@Sendable func handleCommand(_ line: String,
    _ c: EmulatorController.Client<GRPCNIOTransportHTTP2.HTTP2ClientTransport.Posix>) async {
    guard let d = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
    do {
        if let t = obj["tap"] as? [String: Any],
           let x = t["x"] as? Int, let y = t["y"] as? Int {
            try await EmulatorTransport.tap(c, x: Int32(x), y: Int32(y),
                                            display: Int32(t["display"] as? Int ?? 0))
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
        log("bridge: streaming display from emulator gRPC :\(port)")
        try await EmulatorTransport.streamScreenshots(c, format: .png) { data, _, _ in
            emitFrame(data)
        }
    }
} catch {
    log("bridge: \(error)")
    exit(1)
}
