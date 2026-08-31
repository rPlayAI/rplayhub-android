//
//  ControlMessages.swift
//  Host → agent control messages.
//
//  The agent has no Serialize() for these — it only ever receives them — so the encoding here is
//  the mirror image of its Deserialize(), which is the authority. Field order is taken straight
//  from `cpp/control_messages.cc`; type ids from `cpp/control_messages.h`.
//
//  Messages are written back to back with no length prefix. Each one is self-delimiting: a type
//  varint followed by its fields. That is why a single wrong varint width is unrecoverable, and
//  why every field below is annotated with the reader that consumes it.
//

import Foundation

enum ControlMessage {
    // Type ids — control_messages.h
    static let typeMotionEvent = 1
    static let typeKeyEvent = 2
    static let typeTextInput = 3
    static let typeSetDeviceOrientation = 4
    static let typeSetMaxVideoResolution = 5
    static let typeStartVideoStream = 6
    static let typeStopVideoStream = 7
    static let typeStartAudioStream = 8
    static let typeStopAudioStream = 9
    static let typeStartClipboardSync = 10
    static let typeStopClipboardSync = 11
    static let typeDisplayConfigurationRequest = 20
    // Our agent additions (see refs/studio/PROVENANCE.md).
    static let typeCreateNewDisplay = 120
    static let typeDestroyNewDisplay = 121

    // Device → host. Parsed by ControlSender's reader; nothing is length-prefixed, so every
    // type the agent can send unprompted has to be decodable or the channel desynchronises.
    static let typeErrorResponse = 21
    static let typeDisplayConfigurationResponse = 22
    static let typeClipboardChanged = 23
    static let typeSupportedDeviceStates = 24
    static let typeDeviceState = 25
    static let typeDisplayAddedOrChanged = 26
    static let typeDisplayRemoved = 27
    static let typeXrPassthroughChanged = 28
    static let typeXrEnvironmentChanged = 29
    static let typeXrInputUnavailable = 30

    /// One finger or mouse pointer, in the display's ORIGINAL orientation — not the rotated one
    /// we happen to be showing. The agent injects these coordinates verbatim.
    struct Pointer {
        var x: Int32
        var y: Int32
        var pointerId: Int32 = 0
        /// Axis → value, for scroll wheels and joysticks. AMOTION_EVENT_AXIS_VSCROLL is 9.
        var axisValues: [Int32: Float] = [:]
    }

    /// MotionEventMessage::Deserialize reads, in order: pointer count, then per pointer
    /// (x, y, id, axis count, then axis/value pairs), then action, button state, action button,
    /// display id, is_mouse.
    static func motionEvent(pointers: [Pointer],
                            action: Int32,
                            buttonState: Int32 = 0,
                            actionButton: Int32 = 0,
                            displayId: Int32 = 0,
                            isMouse: Bool = false) -> Data {
        var w = Base128Writer()
        w.writeInt32(Int32(typeMotionEvent))
        w.writeUInt32(UInt32(pointers.count))
        for p in pointers {
            w.writeInt32(p.x)
            w.writeInt32(p.y)
            w.writeInt32(p.pointerId)
            w.writeUInt32(UInt32(p.axisValues.count))
            // A std::map is read back in key order on the agent side; sort so the two agree even
            // though the reader does not actually depend on it.
            for (axis, value) in p.axisValues.sorted(by: { $0.key < $1.key }) {
                w.writeInt32(axis)
                w.writeFloat(value)
            }
        }
        w.writeInt32(action)
        w.writeInt32(buttonState)
        w.writeInt32(actionButton)
        w.writeInt32(displayId)
        w.writeBool(isMouse)
        return w.data
    }

    /// KeyEventMessage::Deserialize reads action, keycode, meta_state.
    static func keyEvent(action: Int32, keycode: Int32, metaState: UInt32 = 0) -> Data {
        var w = Base128Writer()
        w.writeInt32(Int32(typeKeyEvent))
        w.writeInt32(action)
        w.writeInt32(keycode)
        w.writeUInt32(metaState)
        return w.data
    }

    static func textInput(_ text: String) -> Data {
        var w = Base128Writer()
        w.writeInt32(Int32(typeTextInput))
        w.writeString16(text)
        return w.data
    }

    /// -1 asks the agent to go back to following the device's own orientation.
    static func setDeviceOrientation(_ quadrants: Int32) -> Data {
        var w = Base128Writer()
        w.writeInt32(Int32(typeSetDeviceOrientation))
        w.writeInt32(quadrants)
        return w.data
    }

    static func setMaxVideoResolution(displayId: Int32 = 0, width: Int32, height: Int32) -> Data {
        var w = Base128Writer()
        w.writeInt32(Int32(typeSetMaxVideoResolution))
        w.writeInt32(displayId)
        w.writeInt32(width)
        w.writeInt32(height)
        return w.data
    }

    static func startVideoStream(displayId: Int32 = 0, width: Int32, height: Int32) -> Data {
        var w = Base128Writer()
        w.writeInt32(Int32(typeStartVideoStream))
        w.writeInt32(displayId)
        w.writeInt32(width)
        w.writeInt32(height)
        return w.data
    }

    static func stopVideoStream(displayId: Int32 = 0) -> Data {
        var w = Base128Writer()
        w.writeInt32(Int32(typeStopVideoStream))
        w.writeInt32(displayId)
        return w.data
    }

    /// The agent starts capturing and encoding device audio onto the audio channel. Works any
    /// time on API 31+ — the channel itself is always open.
    static func startAudioStream() -> Data {
        var w = Base128Writer()
        w.writeInt32(Int32(typeStartAudioStream))
        return w.data
    }

    static func stopAudioStream() -> Data {
        var w = Base128Writer()
        w.writeInt32(Int32(typeStopAudioStream))
        return w.data
    }

    /// Sets the device clipboard to `text` (the agent skips the set when unchanged) and
    /// subscribes to device-side clipboard changes, which arrive as ClipboardChanged
    /// notifications. This one message is both "set clipboard" and "start syncing" — there is
    /// no separate setter in the protocol.
    static func startClipboardSync(maxSyncedLength: Int32 = 262144, text: String) -> Data {
        var w = Base128Writer()
        w.writeInt32(Int32(typeStartClipboardSync))
        w.writeInt32(maxSyncedLength)
        w.writeBytes(text)
        return w.data
    }

    static func stopClipboardSync() -> Data {
        var w = Base128Writer()
        w.writeInt32(Int32(typeStopClipboardSync))
        return w.data
    }

    /// Ask for the device's displays; the answer arrives as a DisplayConfigurationResponse on
    /// the control channel, matched by the request id.
    static func displayConfigurationRequest(requestId: Int32 = 1) -> Data {
        var w = Base128Writer()
        w.writeInt32(Int32(typeDisplayConfigurationRequest))
        w.writeInt32(requestId)
        return w.data
    }

    /// Our agent addition — scrcpy's --new-display: create a standalone virtual display and
    /// start streaming it. The new display's id shows up in the video packet headers.
    static func createNewDisplay(width: Int32, height: Int32, dpi: Int32,
                                 decorations: Bool) -> Data {
        var w = Base128Writer()
        w.writeInt32(Int32(typeCreateNewDisplay))
        w.writeInt32(width)
        w.writeInt32(height)
        w.writeInt32(dpi)
        // Whether the display gets Android's system decorations (taskbar, launcher): yes for
        // Desktop Mode — the shell IS the content — no for an app window, where the taskbar
        // along the bottom is clutter.
        w.writeInt32(decorations ? 1 : 0)
        return w.data
    }

    /// Our agent addition: stop streaming and destroy a display made by createNewDisplay.
    static func destroyNewDisplay(displayId: Int32) -> Data {
        var w = Base128Writer()
        w.writeInt32(Int32(typeDestroyNewDisplay))
        w.writeInt32(displayId)
        return w.data
    }
}

/// android.view.MotionEvent constants, only the ones we send.
enum MotionAction {
    static let down: Int32 = 0
    static let up: Int32 = 1
    static let move: Int32 = 2
    static let cancel: Int32 = 3
    static let scroll: Int32 = 8
    static let buttonPress: Int32 = 11
    static let buttonRelease: Int32 = 12
}

enum MotionAxis {
    static let vscroll: Int32 = 9
    static let hscroll: Int32 = 10
}

enum MotionButton {
    static let primary: Int32 = 1
    static let secondary: Int32 = 2
}

/// android.view.KeyEvent. `downAndUp` is the agent's own extension (KeyEventMessage's
/// ACTION_DOWN_AND_UP = 8), which saves a round trip for a simple button press.
enum KeyAction {
    static let down: Int32 = 0
    static let up: Int32 = 1
    static let downAndUp: Int32 = 8
}

enum AndroidKey {
    static let home: Int32 = 3
    static let back: Int32 = 4
    static let volumeUp: Int32 = 24
    static let volumeDown: Int32 = 25
    static let power: Int32 = 26
    static let enter: Int32 = 66
    static let del: Int32 = 67
    static let escape: Int32 = 111
    static let forwardDel: Int32 = 112
    static let appSwitch: Int32 = 187
    static let sleep: Int32 = 223
    static let wakeup: Int32 = 224
    static let dpadUp: Int32 = 19
    static let dpadDown: Int32 = 20
    static let dpadLeft: Int32 = 21
    static let dpadRight: Int32 = 22
    static let moveHome: Int32 = 122
    static let moveEnd: Int32 = 123
    static let tab: Int32 = 61
}
