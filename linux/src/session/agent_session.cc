#include "agent_session.h"
#include <iostream>
#include <sstream>
#include <fstream>
#include <chrono>
#include <cstdlib>
#include <sys/stat.h>
#include <unistd.h>

namespace rplayhub {

static bool fileExists(const std::string& path) {
    struct stat st{};
    return (::stat(path.c_str(), &st) == 0);
}

std::string AgentSession::findAgentDirectory() {
    const char* env_dir = std::getenv("RPLAYHUB_AGENT_DIR");
    if (env_dir && *env_dir && fileExists(std::string(env_dir) + "/screen-sharing-agent.jar")) {
        return env_dir;
    }

    std::vector<std::string> candidates = {
        "build/agent",
        "../build/agent",
        "../../build/agent"
    };

    for (const auto& c : candidates) {
        if (fileExists(c + "/screen-sharing-agent.jar")) {
            return c;
        }
    }
    return "";
}

AgentSession::AgentSession(std::string serial)
    : serial_(std::move(serial)) {}

AgentSession::~AgentSession() {
    stop();
}

std::string AgentSession::getStatusMessage() const {
    std::lock_guard<std::mutex> lock(status_mutex_);
    return status_message_;
}

void AgentSession::setStatus(SessionState state, const std::string& msg) {
    {
        std::lock_guard<std::mutex> lock(status_mutex_);
        status_message_ = msg;
    }
    state_.store(state);
    addLog(msg);
}

void AgentSession::addLog(const std::string& line) {
    std::lock_guard<std::mutex> lock(log_mutex_);
    logs_.push_back(line);
    if (logs_.size() > 500) {
        logs_.erase(logs_.begin(), logs_.begin() + 100);
    }
}

std::vector<std::string> AgentSession::getLogs() {
    std::lock_guard<std::mutex> lock(log_mutex_);
    return logs_;
}

bool AgentSession::start(const Options& options) {
    if (state_.load() == SessionState::RUNNING || state_.load() == SessionState::DEPLOYING) {
        return false;
    }

    options_ = options;
    stopping_.store(false);
    setStatus(SessionState::DEPLOYING, "Preparing agent deployment...");

    session_thread_ = std::thread(&AgentSession::runBringup, this);
    return true;
}

void AgentSession::stop() {
    stopping_.store(true);

    // Unblock any socket operations immediately
    video_socket_.shutdownAndClose();
    control_socket_.shutdownAndClose();
    audio_socket_.shutdownAndClose();
    if (shell_socket_) shell_socket_->shutdownAndClose();

    if (session_thread_.joinable()) session_thread_.join();
    if (video_thread_.joinable()) video_thread_.join();
    if (log_thread_.joinable()) log_thread_.join();

    decoder_.close();

    if (!socket_name_.empty()) {
        adb_.reverseRemove(serial_, socket_name_);
        socket_name_.clear();
    }

    setStatus(SessionState::STOPPED, "Mirroring stopped");
}

void AgentSession::runBringup() {
    std::string agent_dir = findAgentDirectory();
    if (agent_dir.empty()) {
        setStatus(SessionState::FAILED, "Agent binaries not found (run tools/build-agent.sh)");
        return;
    }

    setStatus(SessionState::DEPLOYING, "Querying device properties...");
    std::string abi = adb_.getProp(serial_, "ro.product.cpu.abi");
    std::string sdk_str = adb_.getProp(serial_, "ro.build.version.sdk");
    int sdk = std::atoi(sdk_str.c_str());

    if (abi.empty() || sdk <= 0) {
        setStatus(SessionState::FAILED, "Failed to inspect device properties via ADB");
        return;
    }

    if (sdk < 26) {
        setStatus(SessionState::FAILED, "Device API " + sdk_str + " too old (minimum API 26)");
        return;
    }

    // Deploy binaries if needed
    setStatus(SessionState::DEPLOYING, "Pushing agent binaries...");
    std::string jar_local = agent_dir + "/screen-sharing-agent.jar";
    std::string so_local = agent_dir + "/" + abi + "/libscreen-sharing-agent.so";

    if (!fileExists(so_local)) {
        setStatus(SessionState::FAILED, "Native library for ABI " + abi + " not found");
        return;
    }

    std::string remote_base = "/data/local/tmp/.studio";
    adb_.shell(serial_, "mkdir -p " + remote_base);
    if (!adb_.pushFile(serial_, jar_local, remote_base + "/screen-sharing-agent.jar", 0644)) {
        setStatus(SessionState::FAILED, "Failed to push agent jar");
        return;
    }
    if (!adb_.pushFile(serial_, so_local, remote_base + "/libscreen-sharing-agent.so", 0755)) {
        setStatus(SessionState::FAILED, "Failed to push agent native library");
        return;
    }
    adb_.shell(serial_, "chown shell:shell " + remote_base + " " + remote_base + "/*");

    // Open listener on loopback
    setStatus(SessionState::DEPLOYING, "Setting up reverse tunnel...");
    TCPListener listener;
    if (!listener.open(0)) {
        setStatus(SessionState::FAILED, "Failed to open loopback TCP listener");
        return;
    }

    uint16_t port = listener.getPort();
    socket_name_ = "screen-sharing-agent-" + std::to_string(port);
    if (!adb_.reverse(serial_, socket_name_, port)) {
        setStatus(SessionState::FAILED, "Failed to setup adb reverse tunnel");
        return;
    }

    // Launch agent via app_process
    setStatus(SessionState::DEPLOYING, "Launching screen-sharing agent...");
    std::ostringstream cmd;
    cmd << "CLASSPATH=" << remote_base << "/screen-sharing-agent.jar"
        << " app_process " << remote_base
        << " com.android.tools.screensharing.Main"
        << " --socket=" << socket_name_
        << " --max_size=" << options_.max_w << "," << options_.max_h
        << " --flags=1"
        << " --codec=" << options_.codec
        << " --log=info";

    shell_socket_ = adb_.shellStream(serial_, cmd.str());
    if (!shell_socket_) {
        setStatus(SessionState::FAILED, "Failed to spawn agent process on device");
        return;
    }

    log_thread_ = std::thread(&AgentSession::runLogLoop, this);

    // Accept channels
    setStatus(SessionState::DEPLOYING, "Waiting for agent channels...");
    int expected_channels = (sdk >= 31) ? 3 : 2;
    for (int i = 0; i < expected_channels; ++i) {
        TCPSocket sock;
        // Poll in short slices so stop() is honoured while we wait for the agent.
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
        bool accepted = false;
        while (!stopping_.load() && std::chrono::steady_clock::now() < deadline) {
            if (listener.accept(sock, 250)) { accepted = true; break; }
        }
        if (!accepted) {
            setStatus(stopping_.load() ? SessionState::STOPPED : SessionState::FAILED,
                      stopping_.load() ? "Mirroring stopped" : "Timeout waiting for agent connections");
            return;
        }

        uint8_t marker = 0;
        if (!sock.readFully(&marker, 1)) {
            setStatus(SessionState::FAILED, "Failed to read channel marker");
            return;
        }

        if (marker == 'V') {
            video_socket_ = std::move(sock);
        } else if (marker == 'C') {
            control_socket_ = std::move(sock);
            control_socket_.setNoDelay(true);
        } else if (marker == 'A') {
            audio_socket_ = std::move(sock);
        }
    }

    if (!video_socket_.isValid() || !control_socket_.isValid()) {
        setStatus(SessionState::FAILED, "Did not receive both video and control channels");
        return;
    }

    // Remove reverse forward now that connections are active
    adb_.reverseRemove(serial_, socket_name_);
    listener.close();

    // Read 20-byte video channel header (codec name)
    char channel_hdr[21] = {0};
    if (!video_socket_.readFully(channel_hdr, 20)) {
        setStatus(SessionState::FAILED, "Failed to read 20-byte video channel header");
        return;
    }

    std::string codec_name(channel_hdr);
    while (!codec_name.empty() && (codec_name.back() == ' ' || codec_name.back() == '\0')) {
        codec_name.pop_back();
    }
    addLog("Agent video codec: " + codec_name);

    if (!decoder_.init(codec_name.empty() ? "h264" : codec_name, options_.decoder)) {
        setStatus(SessionState::FAILED, "Failed to initialize FFmpeg " + codec_name + " video decoder");
        return;
    }

    video_thread_ = std::thread(&AgentSession::runVideoLoop, this);
    setStatus(SessionState::RUNNING, "Mirroring active");
}

void AgentSession::runVideoLoop() {
    std::vector<uint8_t> header_buf(VideoPacketHeader::HEADER_SIZE);
    std::vector<uint8_t> payload_buf;

    while (!stopping_.load()) {
        if (!video_socket_.readFully(header_buf.data(), VideoPacketHeader::HEADER_SIZE)) {
            break;
        }

        VideoPacketHeader header;
        if (!VideoPacketHeader::parse(header_buf.data(), header_buf.size(), header)) {
            continue;
        }

        if (header.packetSize < 0 || header.packetSize > 20 * 1024 * 1024) {
            std::cerr << "AgentSession: Invalid video packet size " << header.packetSize << "\n";
            break;
        }

        size_t pkt_sz = static_cast<size_t>(header.packetSize);
        // Add 64 bytes padding required by FFmpeg bitstream SIMD reader
        payload_buf.resize(pkt_sz + 64);
        if (!video_socket_.readFully(payload_buf.data(), pkt_sz)) {
            break;
        }
        std::memset(payload_buf.data() + pkt_sz, 0, 64);

        decoder_.decode(payload_buf.data(), pkt_sz, header);
    }

    if (!stopping_.load()) {
        setStatus(SessionState::STOPPED, "Video stream ended");
    }
}

void AgentSession::runLogLoop() {
    if (!shell_socket_) return;
    char buf[1024];
    std::string line_accum;

    while (!stopping_.load()) {
        ssize_t n = shell_socket_->read(buf, sizeof(buf) - 1);
        if (n <= 0) break;
        buf[n] = '\0';
        line_accum += buf;

        size_t pos = 0;
        while ((pos = line_accum.find('\n')) != std::string::npos) {
            std::string line = line_accum.substr(0, pos);
            line_accum.erase(0, pos + 1);
            while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
            if (!line.empty()) {
                addLog("[Agent] " + line);
            }
        }
    }
}

void AgentSession::sendTouch(int x, int y, int action) {
    if (!control_socket_.isValid()) return;
    Pointer p;
    p.x = x;
    p.y = y;
    p.pointerId = 0;

    auto msg = ControlMessages::motionEvent({p}, action, 0, 0, 0, false);
    std::lock_guard<std::mutex> lock(control_mutex_);
    control_socket_.writeAll(msg.data(), msg.size());
}

void AgentSession::sendScroll(int x, int y, float hscroll, float vscroll) {
    if (!control_socket_.isValid()) return;
    Pointer p;
    p.x = x;
    p.y = y;
    p.pointerId = 0;
    p.axisValues[MotionAxis::HSCROLL] = hscroll;
    p.axisValues[MotionAxis::VSCROLL] = vscroll;
    auto msg = ControlMessages::motionEvent({p}, MotionAction::SCROLL, 0, 0, 0, true);
    std::lock_guard<std::mutex> lock(control_mutex_);
    control_socket_.writeAll(msg.data(), msg.size());
}

void AgentSession::sendKey(int keycode, int action) {
    if (!control_socket_.isValid()) return;
    auto msg = ControlMessages::keyEvent(action, keycode, 0);
    std::lock_guard<std::mutex> lock(control_mutex_);
    control_socket_.writeAll(msg.data(), msg.size());
}

void AgentSession::sendText(const std::string& text) {
    if (!control_socket_.isValid()) return;
    auto msg = ControlMessages::textInput(text);
    std::lock_guard<std::mutex> lock(control_mutex_);
    control_socket_.writeAll(msg.data(), msg.size());
}

void AgentSession::setOrientation(int quadrants) {
    if (!control_socket_.isValid()) return;
    auto msg = ControlMessages::setDeviceOrientation(quadrants);
    std::lock_guard<std::mutex> lock(control_mutex_);
    control_socket_.writeAll(msg.data(), msg.size());
}

void AgentSession::wakeOrPower(bool power) {
    if (power) {
        sendKey(AndroidKey::POWER);
    } else {
        sendKey(AndroidKey::WAKEUP);
    }
}

} // namespace rplayhub
