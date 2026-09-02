// Probe: connect to a running headless emulator over gRPC, print status, save a screenshot,
// and tap the middle. Proves the whole transport from Swift.
//   swift run emulator-probe [port]
import Foundation
import EmulatorTransport

let port = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 8554 : 8554

try await EmulatorTransport.withController(port: port) { c in
    let s = try await EmulatorTransport.status(c)
    print("status: version=\(s.version) booted=\(s.booted) uptime=\(s.uptime)ms")

    let (bytes, w, h) = try await EmulatorTransport.screenshot(c)
    let out = "/tmp/emulator-transport-shot.png"
    try bytes.write(to: URL(fileURLWithPath: out))
    print("screenshot: \(w)x\(h), \(bytes.count) bytes -> \(out)")

    // tap the middle
    try await EmulatorTransport.tap(c, x: Int32(w/2), y: Int32(h/2))
    print("tapped (\(w/2), \(h/2))")

    try await EmulatorTransport.key(c, "KEYCODE_HOME")
    print("pressed HOME")
}
print("OK")
