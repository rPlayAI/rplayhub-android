#pragma once

#include "net/tcp_socket.h"
#include "net/tcp_listener.h"
#include "adb/adb_client.h"
#include "video/video_decoder.h"
#include "video/stream_recorder.h"
#include "audio/audio_player.h"
#include "protocol/control_messages.h"
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include <functional>
#include <map>
#include <memory>

namespace rplayhub {

enum class SessionState {
    IDLE,
    DEPLOYING,
    RUNNING,
    FAILED,
    STOPPED
};

class AgentSession {
public:
    explicit AgentSession(std::string serial);
    ~AgentSession();

    struct Options {
        int max_w = 1920;           // agent --max_size, applied per dimension: a phone streams at
        int max_h = 2400;           // (nearly) native size and a 1920x1080 desktop display in full.
        std::string codec = "avc";  // agent --codec: avc, hevc, vp8, vp9, av1
        std::string decoder;        // FFmpeg decoder name; empty = generic
        bool audio = true;          // forward device audio once the session is up (API 31+)
        bool turn_screen_off = false;   // agent flag 0x02: phone screen dark while mirroring
    };

    struct DisplayDescriptor {
        int32_t id = 0;
        int32_t width = 0;
        int32_t height = 0;
        int32_t rotation = 0;
        int32_t type = 0;
    };

    // What the agent sends unprompted on the control channel, queued for the UI thread.
    struct AgentEvent {
        enum Kind { CLIPBOARD_CHANGED, DISPLAYS, DISPLAY_ADDED_OR_CHANGED, DISPLAY_REMOVED, ERROR_RESPONSE,
                    NEW_DISPLAY_STREAM };   // first video packet of a display id we had not seen
        Kind kind = ERROR_RESPONSE;
        std::string text;                          // clipboard text / error message
        DisplayDescriptor display;                 // DISPLAY_ADDED_OR_CHANGED / DISPLAY_REMOVED
        std::vector<DisplayDescriptor> displays;   // DISPLAYS
    };
    std::vector<AgentEvent> takeEvents();

    bool start(const Options& options);
    bool start() { return start(Options()); }
    void stop();

    SessionState getState() const { return state_.load(); }
    std::string getStatusMessage() const;
    const std::string& getSerial() const { return serial_; }

    VideoDecoder& getDecoder() { return decoder_; }
    // Decoder of a virtual display's stream (nullptr until its first packet). Display 0 is getDecoder().
    VideoDecoder* decoderFor(int32_t display_id);
    void forgetDisplay(int32_t display_id);
    // Virtual displays (rPlayHub agent addition). The new display announces itself by its
    // first video packet: a NEW_DISPLAY_STREAM event with the id and size.
    void requestNewDisplay(int32_t width, int32_t height, int32_t dpi, bool decorations);
    void destroyDisplay(int32_t display_id);
    StreamRecorder& getRecorder() { return recorder_; }
    // Device audio through the host's speakers. Works any time while RUNNING on API 31+;
    // the agent starts and stops capture by control message.
    void setAudioForwarding(bool enabled);
    bool isAudioForwarding() const { return audio_enabled_.load(); }
    bool hasAudioChannel() const { return audio_socket_.isValid(); }
    const AudioPlayer* getAudioPlayer() const { return audio_player_.get(); }
    // Codec the agent reported in the channel header ("h264", "hevc"); empty until RUNNING.
    std::string getCodecName() const;

    // Input injection
    void sendTouch(int x, int y, int action, int32_t display_id = 0);
    // Mouse wheel at (x, y): one unit of hscroll / vscroll per notch.
    void sendScroll(int x, int y, float hscroll, float vscroll, int32_t display_id = 0);
    void sendKey(int keycode, int action = KeyAction::DOWN_AND_UP);
    void sendText(const std::string& text);
    void setOrientation(int quadrants);
    // Clipboard: one message both sets the device clipboard and subscribes to its changes
    // (which arrive as CLIPBOARD_CHANGED events).
    void syncClipboard(const std::string& host_text);
    void stopClipboardSync();
    // Freeze the mirror (no frames, no bandwidth) and resume it.
    void setDisplayPaused(bool paused);
    bool isDisplayPaused() const { return display_paused_.load(); }
    void requestDisplayConfiguration();
    // Restart the primary display's encoder so the next packets are SPS/PPS and an IDR.
    // The agent's encoders emit no periodic keyframes, and a recording needs one to start.
    // Costs a ~100 ms gap in the mirror.
    void requestKeyframe();
    void wakeOrPower(bool power);

    // Logs
    std::vector<std::string> getLogs();
    // Echo every agent log line to stderr as well (the -v flag).
    static void setVerbose(bool on) { verbose_ = on; }

    static std::string findAgentDirectory();

private:
    static inline bool verbose_ = false;
    std::string serial_;
    std::atomic<SessionState> state_{SessionState::IDLE};
    std::string status_message_;
    mutable std::mutex status_mutex_;

    AdbClient adb_;
    VideoDecoder decoder_;
    std::mutex displays_mutex_;
    std::map<int32_t, std::unique_ptr<VideoDecoder>> display_decoders_;
    StreamRecorder recorder_;
    std::string codec_name_;

    TCPSocket video_socket_;
    TCPSocket control_socket_;
    TCPSocket audio_socket_; // Opened by the agent on API 31+; read by audio_player_ when forwarding
    std::unique_ptr<AudioPlayer> audio_player_;
    std::atomic<bool> audio_enabled_{false};
    std::unique_ptr<TCPSocket> shell_socket_;
    std::unique_ptr<TCPSocket> logcat_socket_;   // `logcat` filtered to the agent's tag
    std::string socket_name_;

    std::thread session_thread_;
    std::thread video_thread_;
    std::thread log_thread_;
    std::thread logcat_thread_;
    std::thread control_thread_;
    std::atomic<bool> display_paused_{false};
    std::mutex events_mutex_;
    std::vector<AgentEvent> events_;
    std::atomic<bool> stopping_{false};

    std::mutex control_mutex_;
    std::mutex log_mutex_;
    std::vector<std::string> logs_;

    void setStatus(SessionState state, const std::string& msg);
    void addLog(const std::string& line);

    Options options_;

    void runBringup();
    void runVideoLoop();
    void runLogLoop();
    void runLogcatLoop();
    void runControlLoop();
    void sendControl(const std::vector<uint8_t>& msg);
    void pushEvent(AgentEvent ev);
};

} // namespace rplayhub
