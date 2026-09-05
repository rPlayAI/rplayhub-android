#include "control_messages.h"
#include "base128.h"

namespace rplayhub {

constexpr int32_t TYPE_MOTION_EVENT = 1;
constexpr int32_t TYPE_KEY_EVENT = 2;
constexpr int32_t TYPE_TEXT_INPUT = 3;
constexpr int32_t TYPE_SET_DEVICE_ORIENTATION = 4;
constexpr int32_t TYPE_SET_MAX_VIDEO_RESOLUTION = 5;
constexpr int32_t TYPE_START_VIDEO_STREAM = 6;
constexpr int32_t TYPE_STOP_VIDEO_STREAM = 7;
constexpr int32_t TYPE_START_AUDIO_STREAM = 8;
constexpr int32_t TYPE_STOP_AUDIO_STREAM = 9;
constexpr int32_t TYPE_START_CLIPBOARD_SYNC = 10;
constexpr int32_t TYPE_CREATE_NEW_DISPLAY = 120;
constexpr int32_t TYPE_DESTROY_NEW_DISPLAY = 121;
constexpr int32_t TYPE_STOP_CLIPBOARD_SYNC = 11;
constexpr int32_t TYPE_DISPLAY_CONFIGURATION_REQUEST = 20;

std::vector<uint8_t> ControlMessages::motionEvent(
    const std::vector<Pointer>& pointers,
    int32_t action,
    int32_t buttonState,
    int32_t actionButton,
    int32_t displayId,
    bool isMouse) {
    Base128Writer w;
    w.writeInt32(TYPE_MOTION_EVENT);
    w.writeUInt32(static_cast<uint32_t>(pointers.size()));
    for (const auto& p : pointers) {
        w.writeInt32(p.x);
        w.writeInt32(p.y);
        w.writeInt32(p.pointerId);
        w.writeUInt32(static_cast<uint32_t>(p.axisValues.size()));
        for (const auto& [axis, val] : p.axisValues) {
            w.writeInt32(axis);
            w.writeFloat(val);
        }
    }
    w.writeInt32(action);
    w.writeInt32(buttonState);
    w.writeInt32(actionButton);
    w.writeInt32(displayId);
    w.writeBool(isMouse);
    return w.data();
}

std::vector<uint8_t> ControlMessages::keyEvent(
    int32_t action,
    int32_t keycode,
    uint32_t metaState) {
    Base128Writer w;
    w.writeInt32(TYPE_KEY_EVENT);
    w.writeInt32(action);
    w.writeInt32(keycode);
    w.writeUInt32(metaState);
    return w.data();
}

std::vector<uint8_t> ControlMessages::textInput(const std::string& text) {
    Base128Writer w;
    w.writeInt32(TYPE_TEXT_INPUT);
    w.writeString16(text);
    return w.data();
}

std::vector<uint8_t> ControlMessages::setDeviceOrientation(int32_t quadrants) {
    Base128Writer w;
    w.writeInt32(TYPE_SET_DEVICE_ORIENTATION);
    w.writeInt32(quadrants);
    return w.data();
}

std::vector<uint8_t> ControlMessages::startVideoStream(int32_t displayId, int32_t width, int32_t height) {
    Base128Writer w;
    w.writeInt32(TYPE_START_VIDEO_STREAM);
    w.writeInt32(displayId);
    w.writeInt32(width);
    w.writeInt32(height);
    return w.data();
}

std::vector<uint8_t> ControlMessages::stopVideoStream(int32_t displayId) {
    Base128Writer w;
    w.writeInt32(TYPE_STOP_VIDEO_STREAM);
    w.writeInt32(displayId);
    return w.data();
}

std::vector<uint8_t> ControlMessages::startAudioStream() {
    Base128Writer w;
    w.writeInt32(TYPE_START_AUDIO_STREAM);
    return w.data();
}

std::vector<uint8_t> ControlMessages::stopAudioStream() {
    Base128Writer w;
    w.writeInt32(TYPE_STOP_AUDIO_STREAM);
    return w.data();
}

std::vector<uint8_t> ControlMessages::startClipboardSync(int32_t maxSyncedLength, const std::string& text) {
    Base128Writer w;
    w.writeInt32(TYPE_START_CLIPBOARD_SYNC);
    w.writeInt32(maxSyncedLength);
    w.writeBytes(text);
    return w.data();
}

std::vector<uint8_t> ControlMessages::stopClipboardSync() {
    Base128Writer w;
    w.writeInt32(TYPE_STOP_CLIPBOARD_SYNC);
    return w.data();
}

std::vector<uint8_t> ControlMessages::displayConfigurationRequest(int32_t requestId) {
    Base128Writer w;
    w.writeInt32(TYPE_DISPLAY_CONFIGURATION_REQUEST);
    w.writeInt32(requestId);
    return w.data();
}

std::vector<uint8_t> ControlMessages::createNewDisplay(int32_t width, int32_t height, int32_t dpi, bool decorations) {
    Base128Writer w;
    w.writeInt32(TYPE_CREATE_NEW_DISPLAY);
    w.writeInt32(width);
    w.writeInt32(height);
    w.writeInt32(dpi);
    w.writeInt32(decorations ? 1 : 0);
    return w.data();
}

std::vector<uint8_t> ControlMessages::destroyNewDisplay(int32_t displayId) {
    Base128Writer w;
    w.writeInt32(TYPE_DESTROY_NEW_DISPLAY);
    w.writeInt32(displayId);
    return w.data();
}

} // namespace rplayhub
