#pragma once

#include <vector>
#include <string>
#include <map>
#include <cstdint>

namespace rplayhub {

struct Pointer {
    int32_t x = 0;
    int32_t y = 0;
    int32_t pointerId = 0;
    std::map<int32_t, float> axisValues; // Axis -> value
};

namespace MotionAction {
    constexpr int32_t DOWN = 0;
    constexpr int32_t UP = 1;
    constexpr int32_t MOVE = 2;
    constexpr int32_t CANCEL = 3;
    constexpr int32_t SCROLL = 8;
    constexpr int32_t BUTTON_PRESS = 11;
    constexpr int32_t BUTTON_RELEASE = 12;
}

namespace MotionAxis {
    constexpr int32_t VSCROLL = 9;
    constexpr int32_t HSCROLL = 10;
}

namespace KeyAction {
    constexpr int32_t DOWN = 0;
    constexpr int32_t UP = 1;
    constexpr int32_t DOWN_AND_UP = 8;
}

namespace AndroidKey {
    constexpr int32_t HOME = 3;
    constexpr int32_t BACK = 4;
    constexpr int32_t VOLUME_UP = 24;
    constexpr int32_t VOLUME_DOWN = 25;
    constexpr int32_t POWER = 26;
    constexpr int32_t ENTER = 66;
    constexpr int32_t DEL = 67;
    constexpr int32_t ESCAPE = 111;
    constexpr int32_t FORWARD_DEL = 112;
    constexpr int32_t APP_SWITCH = 187; // Recents / Overview
    constexpr int32_t SLEEP = 223;
    constexpr int32_t WAKEUP = 224;
    constexpr int32_t DPAD_UP = 19;
    constexpr int32_t DPAD_DOWN = 20;
    constexpr int32_t DPAD_LEFT = 21;
    constexpr int32_t DPAD_RIGHT = 22;
    constexpr int32_t TAB = 61;
}

class ControlMessages {
public:
    static std::vector<uint8_t> motionEvent(
        const std::vector<Pointer>& pointers,
        int32_t action,
        int32_t buttonState = 0,
        int32_t actionButton = 0,
        int32_t displayId = 0,
        bool isMouse = false);

    static std::vector<uint8_t> keyEvent(
        int32_t action,
        int32_t keycode,
        uint32_t metaState = 0);

    static std::vector<uint8_t> textInput(const std::string& text);

    static std::vector<uint8_t> setDeviceOrientation(int32_t quadrants);

    static std::vector<uint8_t> startVideoStream(int32_t displayId, int32_t width, int32_t height);
    static std::vector<uint8_t> stopVideoStream(int32_t displayId = 0);

    static std::vector<uint8_t> startAudioStream();
    static std::vector<uint8_t> stopAudioStream();

    static std::vector<uint8_t> startClipboardSync(int32_t maxSyncedLength, const std::string& text);
    static std::vector<uint8_t> stopClipboardSync();

    static std::vector<uint8_t> displayConfigurationRequest(int32_t requestId = 1);

    // rPlayHub agent additions (scrcpy's --new-display): a standalone virtual display the agent
    // starts streaming at once; its id shows up in the video packet headers. decorations = the
    // Android taskbar and launcher (Desktop Mode); off for a single app's window.
    static std::vector<uint8_t> createNewDisplay(int32_t width, int32_t height, int32_t dpi, bool decorations);
    static std::vector<uint8_t> destroyNewDisplay(int32_t displayId);
};

} // namespace rplayhub
