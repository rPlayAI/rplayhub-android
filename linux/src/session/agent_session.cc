#include "agent_session.h"
#include <algorithm>
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
    if (verbose_) std::cerr << line << "\n";
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
    if (logcat_socket_) logcat_socket_->shutdownAndClose();

    if (session_thread_.joinable()) session_thread_.join();
    if (video_thread_.joinable()) video_thread_.join();
    if (log_thread_.joinable()) log_thread_.join();
    if (logcat_thread_.joinable()) logcat_thread_.join();
    if (control_thread_.joinable()) control_thread_.join();
    if (audio_player_) {
        audio_player_->stop();
        audio_player_.reset();
    }
    audio_enabled_.store(false);

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
    // RPLAYHUB_AUDIO_SUBMIX=2: capture device audio with an AudioRecord on REMOTE_SUBMIX
    // (scrcpy's route; rPlayHub's patch in the agent's audio_streamer.cc). Upstream's API 34+
    // AudioPolicy loopback yields silence on recent Pixels.
    std::ostringstream cmd;
    cmd << "RPLAYHUB_AUDIO_SUBMIX=2 CLASSPATH=" << remote_base << "/screen-sharing-agent.jar"
        << " app_process " << remote_base
        << " com.android.tools.screensharing.Main"
        << " --socket=" << socket_name_
        << " --max_size=" << options_.max_w << "," << options_.max_h
        << " --flags=" << (1 | (options_.turn_screen_off ? 2 : 0))
        << " --codec=" << options_.codec
        << " --log=" << (std::getenv("RPLAYHUB_AGENT_LOG") ? std::getenv("RPLAYHUB_AGENT_LOG") : "info");

    shell_socket_ = adb_.shellStream(serial_, cmd.str());
    if (!shell_socket_) {
        setStatus(SessionState::FAILED, "Failed to spawn agent process on device");
        return;
    }

    log_thread_ = std::thread(&AgentSession::runLogLoop, this);

    // The agent logs to logcat under studio.screen.sharing, not to the stdout of its shell
    // (which only ever carries app_process's own complaints), so tail that tag from now on.
    logcat_socket_ = adb_.shellStream(serial_, "logcat -v brief -T 1 studio.screen.sharing:V '*:S'");
    if (logcat_socket_) logcat_thread_ = std::thread(&AgentSession::runLogcatLoop, this);

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
    {
        std::lock_guard<std::mutex> lock(status_mutex_);
        codec_name_ = codec_name.empty() ? "h264" : codec_name;
    }

    if (!decoder_.init(codec_name.empty() ? "h264" : codec_name, options_.decoder)) {
        setStatus(SessionState::FAILED, "Failed to initialize FFmpeg " + codec_name + " video decoder");
        return;
    }

    video_thread_ = std::thread(&AgentSession::runVideoLoop, this);
    control_thread_ = std::thread(&AgentSession::runControlLoop, this);
    setStatus(SessionState::RUNNING, "Mirroring active");
    if (options_.audio) setAudioForwarding(true);
}

void AgentSession::sendControl(const std::vector<uint8_t>& msg) {
    if (!control_socket_.isValid()) return;
    std::lock_guard<std::mutex> lock(control_mutex_);
    control_socket_.writeAll(msg.data(), msg.size());
}

void AgentSession::pushEvent(AgentEvent ev) {
    std::lock_guard<std::mutex> lock(events_mutex_);
    events_.push_back(std::move(ev));
    if (events_.size() > 256) events_.erase(events_.begin(), events_.begin() + 128);
}

std::vector<AgentSession::AgentEvent> AgentSession::takeEvents() {
    std::lock_guard<std::mutex> lock(events_mutex_);
    std::vector<AgentEvent> out;
    out.swap(events_);
    return out;
}

// The agent's side of the control channel. Nothing is length-prefixed, so every message type
// the agent can send unprompted is decoded field by field; after an unknown type the stream
// can no longer be framed, so the loop drains and discards, which keeps the agent's writer
// unblocked. Message layouts: refs/studio/.../control_messages.cc.
void AgentSession::runControlLoop() {
    auto read_varint = [&](uint32_t& out) -> bool {
        out = 0;
        for (int shift = 0; shift < 35; shift += 7) {
            uint8_t b;
            if (!control_socket_.readFully(&b, 1)) return false;
            out |= static_cast<uint32_t>(b & 0x7F) << shift;
            if ((b & 0x80) == 0) return true;
        }
        return false;
    };
    auto read_i32 = [&](int32_t& out) -> bool {
        uint32_t u;
        if (!read_varint(u)) return false;
        out = static_cast<int32_t>(u);
        return true;
    };
    auto read_bytes = [&](std::string& out) -> bool {
        uint32_t len;
        if (!read_varint(len) || len > (1u << 24)) return false;
        out.resize(len);
        return len == 0 || control_socket_.readFully(out.data(), len);
    };

    while (!stopping_.load()) {
        uint32_t type;
        if (!read_varint(type)) {
            if (!stopping_.load()) addLog("[Agent] control channel closed");
            break;
        }
        if (verbose_) std::cerr << "control: message type " << type << "\n";
        bool ok = true;
        switch (type) {
        case 21: {   // ErrorResponse: request id, message
            int32_t req; std::string msg;
            ok = read_i32(req) && read_bytes(msg);
            if (ok) {
                addLog("[Agent] error response: " + msg);
                AgentEvent ev; ev.kind = AgentEvent::ERROR_RESPONSE; ev.text = msg;
                pushEvent(std::move(ev));
            }
            break;
        }
        case 22: {   // DisplayConfigurationResponse: request id, count, (id, w, h, rotation, type)*
            int32_t req, count;
            ok = read_i32(req) && read_i32(count);
            AgentEvent ev; ev.kind = AgentEvent::DISPLAYS;
            for (int32_t i = 0; ok && i < std::min(count, 64); ++i) {
                DisplayDescriptor d;
                ok = read_i32(d.id) && read_i32(d.width) && read_i32(d.height) && read_i32(d.rotation) && read_i32(d.type);
                if (ok) ev.displays.push_back(d);
            }
            if (ok) pushEvent(std::move(ev));
            break;
        }
        case 23: {   // ClipboardChangedNotification: text
            AgentEvent ev; ev.kind = AgentEvent::CLIPBOARD_CHANGED;
            ok = read_bytes(ev.text);
            if (ok) pushEvent(std::move(ev));
            break;
        }
        case 24: {   // SupportedDeviceStatesNotification
            uint32_t count;
            ok = read_varint(count);
            for (uint32_t i = 0; ok && i < count && i < 64; ++i) {
                int32_t id, sys, phys; std::string name;
                ok = read_i32(id) && read_bytes(name) && read_i32(sys) && read_i32(phys);
            }
            int32_t current;
            ok = ok && read_i32(current);
            break;
        }
        case 25: { int32_t state; ok = read_i32(state); break; }   // DeviceStateNotification
        case 26: {   // DisplayAddedOrChangedNotification: id, w, h, rotation, type, env w, env h
            AgentEvent ev; ev.kind = AgentEvent::DISPLAY_ADDED_OR_CHANGED;
            int32_t env_w, env_h;
            ok = read_i32(ev.display.id) && read_i32(ev.display.width) && read_i32(ev.display.height) &&
                 read_i32(ev.display.rotation) && read_i32(ev.display.type) && read_i32(env_w) && read_i32(env_h);
            if (ok) pushEvent(std::move(ev));
            break;
        }
        case 27: {   // DisplayRemovedNotification: id
            AgentEvent ev; ev.kind = AgentEvent::DISPLAY_REMOVED;
            ok = read_i32(ev.display.id);
            if (ok) pushEvent(std::move(ev));
            break;
        }
        case 28: { uint8_t f[4]; ok = control_socket_.readFully(f, 4); break; }   // XrPassthroughCoefficientChanged (fixed32)
        case 29: case 30: { int32_t v; ok = read_i32(v); break; }                // XrEnvironmentChanged / XrInputUnavailable
        default:
            addLog("[Agent] control channel: unknown message type " + std::to_string(type) + "; draining");
            ok = false;
            break;
        }
        if (!ok) {
            if (!stopping_.load()) addLog("[Agent] control channel: could not parse message type " + std::to_string(type) + "; draining");
            char sink[4096];
            while (!stopping_.load() && control_socket_.read(sink, sizeof(sink)) > 0) {}
            break;
        }
    }
}

void AgentSession::syncClipboard(const std::string& host_text) {
    sendControl(ControlMessages::startClipboardSync(262144, host_text));
}

void AgentSession::stopClipboardSync() {
    sendControl(ControlMessages::stopClipboardSync());
}

void AgentSession::setDisplayPaused(bool paused) {
    if (paused) sendControl(ControlMessages::stopVideoStream(0));
    else sendControl(ControlMessages::startVideoStream(0, options_.max_w, options_.max_h));
    display_paused_.store(paused);
}

void AgentSession::requestDisplayConfiguration() {
    sendControl(ControlMessages::displayConfigurationRequest(1));
}

void AgentSession::setAudioForwarding(bool enabled) {
    if (!control_socket_.isValid()) return;
    if (enabled) {
        if (!audio_socket_.isValid()) {
            addLog("Audio: no audio channel (device below API 31)");
            return;
        }
        if (!audio_player_) {
            audio_player_ = std::make_unique<AudioPlayer>(audio_socket_);
            audio_player_->start();
        }
        audio_player_->setPlaying(true);
        auto msg = ControlMessages::startAudioStream();
        std::lock_guard<std::mutex> lock(control_mutex_);
        control_socket_.writeAll(msg.data(), msg.size());
    } else {
        auto msg = ControlMessages::stopAudioStream();
        {
            std::lock_guard<std::mutex> lock(control_mutex_);
            control_socket_.writeAll(msg.data(), msg.size());
        }
        if (audio_player_) audio_player_->setPlaying(false);
    }
    audio_enabled_.store(enabled);
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

        recorder_.write(payload_buf.data(), pkt_sz, header);
        decoder_.decode(payload_buf.data(), pkt_sz, header);
    }

    if (!stopping_.load()) {
        setStatus(SessionState::STOPPED, "Video stream ended");
    }
}

void AgentSession::runLogcatLoop() {
    char buf[4096];
    std::string line_accum;
    while (!stopping_.load() && logcat_socket_) {
        ssize_t n = logcat_socket_->read(buf, sizeof(buf) - 1);
        if (n <= 0) break;
        line_accum.append(buf, n);
        size_t pos = 0;
        while ((pos = line_accum.find('\n')) != std::string::npos) {
            std::string line = line_accum.substr(0, pos);
            line_accum.erase(0, pos + 1);
            while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
            // brief format: "D/studio.screen.sharing( 1234): message" -> "D: message"
            size_t tag = line.find("studio.screen.sharing(");
            size_t colon = tag == std::string::npos ? std::string::npos : line.find("): ", tag);
            if (tag != std::string::npos && colon != std::string::npos && tag >= 2) {
                line = line.substr(0, 1) + ": " + line.substr(colon + 3);
            }
            if (!line.empty() && line.rfind("--------- beginning", 0) != 0) addLog("[Agent] " + line);
        }
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

std::string AgentSession::getCodecName() const {
    std::lock_guard<std::mutex> lock(status_mutex_);
    return codec_name_;
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

void AgentSession::requestKeyframe() {
    if (!control_socket_.isValid()) return;
    auto stop = ControlMessages::stopVideoStream(0);
    auto start = ControlMessages::startVideoStream(0, options_.max_w, options_.max_h);
    std::lock_guard<std::mutex> lock(control_mutex_);
    control_socket_.writeAll(stop.data(), stop.size());
    control_socket_.writeAll(start.data(), start.size());
}

void AgentSession::wakeOrPower(bool power) {
    if (power) {
        sendKey(AndroidKey::POWER);
    } else {
        sendKey(AndroidKey::WAKEUP);
    }
}

} // namespace rplayhub
