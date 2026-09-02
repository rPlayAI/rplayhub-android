//
//  EmulatorTransport.swift
//  Drive a headless Android Emulator through its gRPC EmulatorController — the Android Studio
//  "embedded emulator" model. rPlayHub spawns the engine with `-no-window -grpc <port>` (no Qt),
//  then this is the client: pull the display (getScreenshot / streamScreenshot), send input
//  (sendTouch / sendKey), configure native multi-display, read status. NO virtual display, NO
//  agent — and the emulator stays a normal adb device the whole time, so the SDK/MCP tools keep
//  acting on it in parallel.
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf

public typealias EmulatorController = Android_Emulation_Control_EmulatorController

public enum EmulatorTransport {
    /// Launch the emulator headless with the gRPC service on `port`. It still registers with adb.
    /// Returns the child Process (kill it to stop the emulator).
    @discardableResult
    public static func launchHeadless(emulatorBinary: String, avd: String, port: Int,
                                      gpu: String = "swiftshader_indirect") throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: emulatorBinary)
        p.arguments = ["-avd", avd, "-no-window", "-no-snapshot",
                       "-grpc", String(port), "-gpu", gpu]
        try p.run()
        return p
    }

    /// Open a gRPC connection to a running emulator and run `body` with a live controller client.
    /// The connection lives only for the duration of `body` (grpc-swift v2 scopes the client).
    public static func withController<T: Sendable>(
        host: String = "127.0.0.1", port: Int,
        _ body: @Sendable @escaping (EmulatorController.Client<HTTP2ClientTransport.Posix>)
            async throws -> T
    ) async throws -> T {
        let transport = try HTTP2ClientTransport.Posix(
            target: .ipv4(host: host, port: port),
            transportSecurity: .plaintext)
        return try await withGRPCClient(transport: transport) { client in
            try await body(EmulatorController.Client(wrapping: client))
        }
    }

    // MARK: - convenience calls

    /// A PNG (or RGBA) frame of a display. `display` 0 is the main screen.
    public static func screenshot(
        _ c: EmulatorController.Client<HTTP2ClientTransport.Posix>,
        format: Android_Emulation_Control_ImageFormat.ImgFormat = .png,
        width: UInt32 = 0, height: UInt32 = 0, display: Int32 = 0
    ) async throws -> (bytes: Data, width: UInt32, height: UInt32) {
        var fmt = Android_Emulation_Control_ImageFormat()
        fmt.format = format
        fmt.width = width
        fmt.height = height
        fmt.display = UInt32(display)
        let img = try await c.getScreenshot(request: ClientRequest(message: fmt))
        return (img.image, img.width > 0 ? img.width : img.format.width,
                img.height > 0 ? img.height : img.format.height)
    }

    /// Stream display frames as they change (server-streaming). Calls `onFrame(bytes,w,h)` per
    /// frame until the stream ends or the task is cancelled.
    public static func streamScreenshots(
        _ c: EmulatorController.Client<HTTP2ClientTransport.Posix>,
        format: Android_Emulation_Control_ImageFormat.ImgFormat = .png,
        width: UInt32 = 0, height: UInt32 = 0, display: Int32 = 0,
        onFrame: @Sendable @escaping (Data, UInt32, UInt32) async -> Void
    ) async throws {
        var fmt = Android_Emulation_Control_ImageFormat()
        fmt.format = format; fmt.width = width; fmt.height = height; fmt.display = UInt32(display)
        try await c.streamScreenshot(request: ClientRequest(message: fmt)) { response in
            for try await img in response.messages {
                // The engine fills format.width/height with the delivered size and leaves the
                // top-level width/height at 0 (observed on emulator 37.1).
                let w = img.width > 0 ? img.width : img.format.width
                let h = img.height > 0 ? img.height : img.format.height
                await onFrame(img.image, w, h)
            }
        }
    }

    /// The emulator's displays (0 is the main screen) with their native pixel sizes.
    public static func displayConfigurations(
        _ c: EmulatorController.Client<HTTP2ClientTransport.Posix>
    ) async throws -> [Android_Emulation_Control_DisplayConfiguration] {
        try await c.getDisplayConfigurations(
            request: ClientRequest(message: SwiftProtobuf.Google_Protobuf_Empty())).displays
    }

    public static func status(
        _ c: EmulatorController.Client<HTTP2ClientTransport.Posix>
    ) async throws -> Android_Emulation_Control_EmulatorStatus {
        try await c.getStatus(request: ClientRequest(message: SwiftProtobuf.Google_Protobuf_Empty()))
    }

    /// A tap at device pixels (x, y) on `display`: a pressed touch then a release.
    public static func tap(
        _ c: EmulatorController.Client<HTTP2ClientTransport.Posix>,
        x: Int32, y: Int32, display: Int32 = 0
    ) async throws {
        func send(_ pressure: Int32) async throws {
            var t = Android_Emulation_Control_Touch()
            t.x = x; t.y = y; t.identifier = 0; t.pressure = pressure
            var e = Android_Emulation_Control_TouchEvent()
            e.touches = [t]; e.display = display
            _ = try await c.sendTouch(request: ClientRequest(message: e))
        }
        try await send(1)   // down
        try await send(0)   // up
    }

    /// Press a key by its Android/Linux keycode string (e.g. "KEYCODE_HOME") — the emulator maps it.
    public static func key(
        _ c: EmulatorController.Client<HTTP2ClientTransport.Posix>,
        _ keycode: String,
        type: Android_Emulation_Control_KeyboardEvent.KeyEventType = .keypress
    ) async throws {
        var k = Android_Emulation_Control_KeyboardEvent()
        k.key = keycode
        k.eventType = type
        _ = try await c.sendKey(request: ClientRequest(message: k))
    }
}
