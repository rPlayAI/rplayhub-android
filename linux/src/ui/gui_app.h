#pragma once

#include "net/tcp_socket.h"
#include "adb/adb_client.h"
#include "session/agent_session.h"
#include "imgui.h"

#include <SDL2/SDL.h>
#include <vector>
#include <string>
#include <memory>
#include <chrono>

namespace rplayhub {

class GuiApp {
public:
    explicit GuiApp(bool auto_mirror = false, float scale = 0.0f);
    ~GuiApp();

    void setDumpFrame(const std::string& path) { dump_frame_path_ = path; }
    // Serial (or ip:port) of the device --mirror should pick; empty = first ready device.
    void setPreferredSerial(const std::string& serial) { preferred_serial_ = serial; }
    // Print decoded/rendered frame rates to stderr every few seconds.
    void setStats(bool on) { stats_ = on; }

    bool init();
    void run();
    void cleanup();

private:
    bool auto_mirror_ = false;
    float scale_ = 0.0f;
    std::string dump_frame_path_;
    std::string preferred_serial_;
    int frame_count_ = 0;
    bool stats_ = false;
    std::chrono::steady_clock::time_point stats_last_;
    uint64_t stats_decoded_last_ = 0;
    int stats_rendered_last_ = 0;

    SDL_Window* window_ = nullptr;
    SDL_Renderer* renderer_ = nullptr;
    SDL_Texture* video_texture_ = nullptr;
    int tex_w_ = 0;
    int tex_h_ = 0;
    FrameFormat tex_format_ = FrameFormat::NONE;
    DecodedFrame live_frame_;          // newest decoded frame, refreshed only when the decoder has a new one
    bool texture_dirty_ = false;

    // Font hierarchy
    ImFont* font_regular_ = nullptr;
    ImFont* font_medium_ = nullptr;
    ImFont* font_bold_ = nullptr;
    ImFont* font_title_ = nullptr;
    ImFont* font_caption_ = nullptr;

    AdbClient adb_;
    std::vector<AdbDevice> devices_;
    int selected_device_idx_ = -1;
    std::chrono::steady_clock::time_point last_device_poll_;

    std::unique_ptr<AgentSession> session_;
    bool session_active_ = false;

    // UI state
    char search_filter_[128] = {0};
    int inspector_tab_ = 1; // 0=Info, 1=Apps, 2=Files, 3=Logcat
    char connect_ip_buf_[128] = "192.168.1.100:5555";
    bool show_connect_popup_ = false;
    std::string connect_status_msg_;

    // Apps tab state
    std::vector<std::string> packages_;
    char app_filter_[128] = {0};
    bool show_system_apps_ = false;
    std::string last_inspected_serial_;
    int battery_level_ = -1;

    // Files tab state
    std::vector<std::string> remote_files_;
    std::string current_remote_path_ = "/sdcard/Download";

    // Touch & input tracking
    bool is_touch_active_ = false;
    ImVec2 last_mouse_pos_{0, 0};

    // Notification toast
    std::string toast_message_;
    std::chrono::steady_clock::time_point toast_expiry_;

    void showToast(const std::string& msg, int seconds = 3);
    void pollDevices();
    void refreshPackages(const std::string& serial);
    void refreshFiles(const std::string& serial);

    void startMirroring(int device_idx);
    void stopMirroring();

    // Render components
    void renderLeftSidebar(float width, float height);
    void renderCenterStage(float start_x, float width, float height);
    void renderRightInspector(float width, float height);

    void renderPhoneMockup(ImVec2 center, ImVec2 max_size);
    void renderLiveMirror(ImVec2 origin, ImVec2 size, const DecodedFrame& frame);
    void renderControlStrip(ImVec2 pos, float width);

    void handleTouchInput(ImVec2 img_pos, ImVec2 img_size, int dev_w, int dev_h, int quadrants);
    void handleKeyboardInput();
};

} // namespace rplayhub
