// Input the way Android Studio's embedded emulator sends it: touches, DOM-named keys and text
// over EmulatorController, and rotation through the physical model — never through adb.
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

extension EmulatorTransport {
    /// One finger. `down` keeps the pressure at 1 (press or move); false releases it.
    public static func touch(_ c: EmulatorController.Client<HTTP2ClientTransport.Posix>,
                             x: Int32, y: Int32, down: Bool, display: Int32 = 0) async throws {
        var t = Android_Emulation_Control_Touch()
        t.x = x; t.y = y; t.identifier = 0; t.pressure = down ? 1 : 0
        var ev = Android_Emulation_Control_TouchEvent()
        ev.touches = [t]; ev.display = display
        _ = try await c.sendTouch(ev)
    }

    /// Types a string through the emulator's own key event sender (the guest IME sees real keys).
    public static func typeText(_ c: EmulatorController.Client<HTTP2ClientTransport.Posix>,
                                _ text: String) async throws {
        var ev = Android_Emulation_Control_KeyboardEvent()
        ev.text = text
        _ = try await c.sendKey(ev)
    }

    /// A DOM key value ("GoHome", "GoBack", "AppSwitch", "AudioVolumeUp", "Power", "Enter",
    /// "Backspace", "ArrowLeft" …) as a full press.
    public static func pressKey(_ c: EmulatorController.Client<HTTP2ClientTransport.Posix>,
                                _ domKey: String) async throws {
        var ev = Android_Emulation_Control_KeyboardEvent()
        ev.key = domKey
        ev.eventType = .keypress
        _ = try await c.sendKey(ev)
    }

    /// Rotate the (virtual) device around Z: 0 portrait, -90 landscape, 180, 90.
    public static func rotate(_ c: EmulatorController.Client<HTTP2ClientTransport.Posix>,
                              degreesZ: Float) async throws {
        var v = Android_Emulation_Control_PhysicalModelValue()
        v.target = .rotation
        v.value.data = [0, 0, degreesZ]
        _ = try await c.setPhysicalModel(v)
    }
}
