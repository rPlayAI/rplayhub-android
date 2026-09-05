#pragma once

#include "net/tcp_socket.h"
#include "adb/adb_client.h"
#include "session/agent_session.h"
#include "session/app_catalog.h"
#include "session/emulator_launcher.h"
#include "util/async_jobs.h"
#include "ui/display_window.h"
#include "ui/twin_view.h"
#include <deque>
#include <set>
#include "imgui.h"

#include <SDL2/SDL.h>
#include <vector>
#include <string>
#include <memory>
#include <chrono>
#include <map>

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
    // Inspector tab to open with: 0=Info, 1=Apps, 2=Files, 3=Logcat.
    void setInspectorTab(int tab) { inspector_tab_ = tab; }
    // Agent / decoder settings used for every mirror session started from the UI.
    void setSessionOptions(const AgentSession::Options& o) { session_options_ = o; }
    void setClipboardSyncDefault(bool on) { clipboard_sync_ = on; }
    // Once the mirror is up: open Desktop Mode, and/or an app on a virtual display of its own.
    void setStartupDesktop(bool on) { startup_desktop_ = on; }
    void setStartupApp(const std::string& package) { startup_app_ = package; }
    void setStartupPopOut(bool on) { startup_pop_out_ = on; }
    void setStartupTwin(bool on) { startup_twin_ = on; }

    bool init();
    void run();
    void cleanup();

private:
    bool auto_mirror_ = false;
    float scale_ = 0.0f;
    float menu_h_ = 0.0f;                // height of the menu bar this frame
    std::string dump_frame_path_;
    std::chrono::steady_clock::time_point dump_settled_at_;
    std::string preferred_serial_;
    int frame_count_ = 0;
    bool stats_ = false;
    AgentSession::Options session_options_;
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
    uint64_t frames_shown_ = 0;          // texture uploads, for the Info tab

    void buildFonts();
    void ensureGlyphs(const std::string& utf8);
    std::set<ImWchar> extra_codepoints_;
    bool fonts_dirty_ = false;

    // Font hierarchy
    ImFont* font_regular_ = nullptr;
    ImFont* font_medium_ = nullptr;
    ImFont* font_bold_ = nullptr;
    ImFont* font_title_ = nullptr;
    ImFont* font_caption_ = nullptr;

    // adb round trips run on worker threads; results land on the UI thread via jobs_.pump().
    AsyncJobs jobs_;
    AdbClient adb_;
    std::vector<AdbDevice> devices_;
    int selected_device_idx_ = -1;       // index into devices_, recomputed from selected_serial_
    std::string selected_serial_;        // survives the list reordering between polls
    bool devices_poll_inflight_ = false;
    std::chrono::steady_clock::time_point last_device_poll_;
    std::chrono::steady_clock::time_point auto_mirror_deadline_;

    // Per-device properties, fetched once per device off the UI thread.
    struct DeviceInfo {
        std::map<std::string, std::string> props;
        int battery = -1;
        bool loaded = false;
        bool loading = false;
    };
    std::map<std::string, DeviceInfo> device_info_;

    std::unique_ptr<AgentSession> session_;
    bool session_active_ = false;
    std::string session_serial_;
    bool user_stopped_ = false;          // stop came from the user, not from the stream ending
    int reconnect_attempts_ = 0;
    bool reconnect_pending_ = false;
    std::chrono::steady_clock::time_point reconnect_at_;
    std::chrono::steady_clock::time_point session_started_;
    bool connect_inflight_ = false;
    std::chrono::steady_clock::time_point recording_started_;

    // Virtual displays (Desktop Mode, app windows) and the bare phone window.
    struct PendingDisplay {
        std::string package;   // empty = Desktop Mode
        bool decorated = false;
    };
    std::vector<std::unique_ptr<DisplayWindow>> display_windows_;
    std::map<int32_t, DecodedFrame> display_frames_;   // newest frame per virtual display
    std::deque<PendingDisplay> pending_displays_;
    int display_windows_opened_ = 0;
    bool startup_desktop_ = false;
    std::string startup_app_;
    bool startup_pop_out_ = false;
    bool startup_requests_sent_ = false;
    bool main_pinned_ = false;

    // Emulators (AVDs) in the sidebar
    std::vector<Avd> avds_;
    std::map<std::string, std::string> avds_running_;   // name -> serial
    std::chrono::steady_clock::time_point last_avd_poll_;
    bool avd_poll_inflight_ = false;
    std::string selected_avd_;
    std::set<std::string> avd_starting_;                // names launched, not yet listed by adb
    std::map<std::string, std::string> emulator_names_; // adb serial -> AVD name, asked once per serial

    // The 3D twin
    TwinView twin_;
    bool twin_mode_ = false;
    SDL_Texture* back_texture_ = nullptr;
    bool back_texture_tried_ = false;
    bool startup_twin_ = false;

    // Clipboard sync (both ways, on by default): device changes land on the host clipboard,
    // host changes are pushed on a one-second poll (SDL has no reliable clipboard event on X11).
    bool clipboard_sync_ = true;
    std::string last_clipboard_text_;
    std::chrono::steady_clock::time_point last_clipboard_poll_;
    bool clipboard_started_ = false;

    // UI state
    char search_filter_[128] = {0};
    int inspector_tab_ = 1; // 0=Info, 1=Apps, 2=Files, 3=Logcat
    char connect_ip_buf_[128] = "192.168.1.100:5555";
    bool show_connect_popup_ = false;
    std::string connect_status_msg_;

    // Apps tab state
    struct AppRow {
        std::string id;
        std::string label;              // launcher label, empty until AppLabel answers
        SDL_Texture* icon = nullptr;    // owned by app_icons_
    };
    std::vector<AppRow> apps_;
    std::map<std::string, SDL_Texture*> app_icons_;   // "serial|package" -> texture
    char app_filter_[128] = {0};
    bool show_system_apps_ = false;
    int packages_gen_ = 0;               // bumps per request so a stale reply is dropped
    bool packages_loading_ = false;
    bool app_labels_loading_ = false;
    std::string apps_status_;            // transient: "Installing x.apk...", "Exported ..."
    std::string pending_uninstall_;      // package awaiting confirmation
    bool open_uninstall_popup_ = false;

    // Files tab state
    std::vector<DirEntry> remote_entries_;
    std::string current_remote_path_ = "/sdcard/Download";
    int files_gen_ = 0;
    bool files_loading_ = false;
    bool files_error_ = false;
    std::string pending_delete_;         // remote path awaiting confirmation
    bool open_delete_popup_ = false;

    // Touch & input tracking
    bool is_touch_active_ = false;
    int last_touch_x_ = 0, last_touch_y_ = 0;
    ImVec2 last_mouse_pos_{0, 0};

    // Notification toast
    std::string toast_message_;
    std::chrono::steady_clock::time_point toast_expiry_;

    void showToast(const std::string& msg, int seconds = 3);
    void pollDevices();
    void applyDeviceList(const std::vector<AdbDevice>& list);
    void selectDevice(int idx);
    void loadDeviceInfo(const std::string& serial);
    const DeviceInfo* infoFor(const std::string& serial) const;
    void refreshPackages(const std::string& serial);
    void fetchAppLabels(const std::string& serial, std::vector<std::string> ids, int gen);
    void refreshFiles(const std::string& serial);
    void navigateTo(const std::string& serial, const std::string& path);
    void pullToDownloads(const std::string& serial, const std::string& remote_path);
    void runShellAsync(const std::string& serial, const std::string& command, const std::string& toast);
    void installApk(const std::string& serial, const std::string& local_path);
    void pickAndInstallApk(const std::string& serial);
    void exportApk(const std::string& serial, const std::string& package);
    void handleDroppedFile(const std::string& path);
    static std::string downloadsDir();

    void startMirroring(int device_idx);
    void stopMirroring();
    void restartSession();
    void maintainSession();
    void takeScreenshot();
    void pollEmulators();
    void startEmulator(const Avd& avd);
    void shutdownEmulator(const std::string& serial);
    void renderEmulatorRows(float width);
    void pumpAgentEvents();
    void openDesktopMode();
    void openAppOnVirtualDisplay(const std::string& package);
    void openFrontAppOnVirtualDisplay();
    void openPhoneWindow();
    void togglePinOnTop();
    void openDisplayWindow(const AgentSession::DisplayDescriptor& d, const PendingDisplay& req);
    void closeDisplayWindows();
    void renderDisplayWindows();
    bool routeEventToDisplayWindows(const SDL_Event& e);
    void pollHostClipboard();
    void setClipboardSync(bool on);
    void toggleRecording();
    static std::string mediaDir(const char* subdir);
    static std::string timestampName(const std::string& model, const char* ext);

    // Render components
    void renderMenuBar();
    void renderLeftSidebar(float width, float height);
    void renderCenterStage(float start_x, float width, float height);
    void renderRightInspector(float width, float height);

    void renderPhoneMockup(ImVec2 center, ImVec2 max_size);
    void renderLiveMirror(ImVec2 origin, ImVec2 size, const DecodedFrame& frame);
    void uploadLiveTexture(const DecodedFrame& frame);
    void renderTwin(ImVec2 origin, ImVec2 size, const DecodedFrame& frame);
    void loadBackTexture();
    void renderControlStrip(ImVec2 pos, float width);

    void handleTouchInput(ImVec2 img_pos, ImVec2 img_size, int dev_w, int dev_h, int quadrants);
    void handleKeyboardInput();
};

} // namespace rplayhub
