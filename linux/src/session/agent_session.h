#pragma once

#include "net/tcp_socket.h"
#include "net/tcp_listener.h"
#include "adb/adb_client.h"
#include "video/video_decoder.h"
#include "video/stream_recorder.h"
#include "protocol/control_messages.h"
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include <functional>

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
        int max_w = 1080;           // agent --max_size
        int max_h = 2400;
        std::string codec = "avc";  // agent --codec: avc, hevc, vp8, vp9, av1
        std::string decoder;        // FFmpeg decoder name; empty = generic
    };

    bool start(const Options& options);
    bool start() { return start(Options()); }
    void stop();

    SessionState getState() const { return state_.load(); }
    std::string getStatusMessage() const;
    const std::string& getSerial() const { return serial_; }

    VideoDecoder& getDecoder() { return decoder_; }
    StreamRecorder& getRecorder() { return recorder_; }
    // Codec the agent reported in the channel header ("h264", "hevc"); empty until RUNNING.
    std::string getCodecName() const;

    // Input injection
    void sendTouch(int x, int y, int action);
    // Mouse wheel at (x, y): one unit of hscroll / vscroll per notch.
    void sendScroll(int x, int y, float hscroll, float vscroll);
    void sendKey(int keycode, int action = KeyAction::DOWN_AND_UP);
    void sendText(const std::string& text);
    void setOrientation(int quadrants);
    // Restart the primary display's encoder so the next packets are SPS/PPS and an IDR.
    // The agent's encoders emit no periodic keyframes, and a recording needs one to start.
    // Costs a ~100 ms gap in the mirror.
    void requestKeyframe();
    void wakeOrPower(bool power);

    // Logs
    std::vector<std::string> getLogs();

    static std::string findAgentDirectory();

private:
    std::string serial_;
    std::atomic<SessionState> state_{SessionState::IDLE};
    std::string status_message_;
    mutable std::mutex status_mutex_;

    AdbClient adb_;
    VideoDecoder decoder_;
    StreamRecorder recorder_;
    std::string codec_name_;

    TCPSocket video_socket_;
    TCPSocket control_socket_;
    TCPSocket audio_socket_; // Parked to keep agent audio writer happy
    std::unique_ptr<TCPSocket> shell_socket_;
    std::string socket_name_;

    std::thread session_thread_;
    std::thread video_thread_;
    std::thread log_thread_;
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
};

} // namespace rplayhub
