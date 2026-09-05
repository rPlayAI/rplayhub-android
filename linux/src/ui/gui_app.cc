#include "gui_app.h"
#include "theme.h"
#include "icons.h"
#include "protocol/control_messages.h"

#include "imgui.h"
#include "backends/imgui_impl_sdl2.h"
#include "backends/imgui_impl_sdlrenderer2.h"

#include <iostream>
#include <sstream>
#include <iomanip>
#include <algorithm>
#include <cmath>
#include <unistd.h>

namespace rplayhub {

GuiApp::GuiApp(bool auto_mirror, float scale)
    : auto_mirror_(auto_mirror), scale_(scale) {}

GuiApp::~GuiApp() {
    cleanup();
}

bool GuiApp::init() {
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER | SDL_INIT_GAMECONTROLLER) != 0) {
        std::cerr << "Error: SDL_Init: " << SDL_GetError() << "\n";
        return false;
    }

    // Auto-detect UI scale if not explicitly set
    if (scale_ <= 0.01f) {
        const char* env_scale = std::getenv("RPLAYHUB_SCALE");
        if (env_scale && *env_scale) {
            scale_ = std::atof(env_scale);
        }
    }
    if (scale_ <= 0.01f) {
        SDL_DisplayMode dm;
        if (SDL_GetCurrentDisplayMode(0, &dm) == 0) {
            if (dm.w >= 3000 || dm.h >= 1800) {
                scale_ = 1.5f; // 3456x1948 or 4K/6K display
            } else if (dm.w >= 2400 || dm.h >= 1400) {
                scale_ = 1.3f;
            } else {
                scale_ = 1.15f;
            }
        } else {
            scale_ = 1.35f;
        }
    }

    int win_w = static_cast<int>(1350.0f * scale_);
    int win_h = static_cast<int>(840.0f * scale_);
    SDL_DisplayMode dm;
    if (SDL_GetCurrentDisplayMode(0, &dm) == 0) {
        win_w = std::min(win_w, dm.w - 80);
        win_h = std::min(win_h, dm.h - 80);
    }

    SDL_WindowFlags window_flags = (SDL_WindowFlags)(SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
    window_ = SDL_CreateWindow(
        "rPlayHub Android",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        win_w, win_h,
        window_flags
    );

    if (!window_) {
        std::cerr << "Error: SDL_CreateWindow: " << SDL_GetError() << "\n";
        return false;
    }

    renderer_ = SDL_CreateRenderer(window_, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!renderer_) {
        renderer_ = SDL_CreateRenderer(window_, -1, 0);
    }
    if (!renderer_) {
        std::cerr << "Error: SDL_CreateRenderer: " << SDL_GetError() << "\n";
        return false;
    }

    // Setup ImGui context
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;

    // Load the Inter font family. The TTFs ship in linux/fonts; look next to the
    // executable first (build dir -> ../fonts) so the client is not tied to a
    // particular working directory, then the usual cwd-relative spots, then
    // system fonts. Falling back to ImGui's built-in 13 px bitmap font gives
    // blurry, upscaled text, so say so on stderr.
    std::string exe_dir;
    {
        char buf[4096];
        ssize_t n = ::readlink("/proc/self/exe", buf, sizeof(buf) - 1);
        if (n > 0) {
            buf[n] = '\0';
            std::string exe(buf);
            size_t slash = exe.rfind('/');
            if (slash != std::string::npos) exe_dir = exe.substr(0, slash);
        }
    }
    auto find_font = [&exe_dir](const std::string& font_name,
                                const std::vector<std::string>& system_fallbacks) -> std::string {
        std::vector<std::string> candidates;
        if (!exe_dir.empty()) {
            candidates.push_back(exe_dir + "/../fonts/" + font_name);
            candidates.push_back(exe_dir + "/fonts/" + font_name);
            candidates.push_back(exe_dir + "/../share/rplayhub-android/fonts/" + font_name);
        }
        candidates.push_back("fonts/" + font_name);
        candidates.push_back("linux/fonts/" + font_name);
        candidates.push_back("../fonts/" + font_name);
        candidates.push_back("../../fonts/" + font_name);
        candidates.insert(candidates.end(), system_fallbacks.begin(), system_fallbacks.end());
        for (const auto& path : candidates) {
            if (::access(path.c_str(), R_OK) == 0) return path;
        }
        return "";
    };

    std::string regular_path = find_font("Inter-Regular.ttf", {
        "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"});
    std::string medium_path = find_font("Inter-Medium.ttf", {
        "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Medium.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Medium.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"});
    std::string bold_path = find_font("Inter-SemiBold.ttf", {
        "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Bold.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-SemiBold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"});
    if (regular_path.empty()) {
        std::cerr << "Warning: no TrueType font found (looked for linux/fonts/Inter-*.ttf next to the "
                     "executable and in the working directory); using ImGui's bitmap font\n";
    }

    float base_reg = 16.0f * scale_;
    float base_cap = 13.5f * scale_;
    float base_med = 16.0f * scale_;
    float base_bold = 16.5f * scale_;
    float base_title = 20.5f * scale_;

    // Latin plus General Punctuation, so the em dash / bullet in status text render.
    static const ImWchar glyph_ranges[] = { 0x0020, 0x00FF, 0x2000, 0x206F, 0 };

    if (!regular_path.empty()) {
        font_regular_ = io.Fonts->AddFontFromFileTTF(regular_path.c_str(), base_reg, nullptr, glyph_ranges);
        font_caption_ = io.Fonts->AddFontFromFileTTF(regular_path.c_str(), base_cap, nullptr, glyph_ranges);
        if (!medium_path.empty()) {
            font_medium_ = io.Fonts->AddFontFromFileTTF(medium_path.c_str(), base_med, nullptr, glyph_ranges);
        } else {
            font_medium_ = font_regular_;
        }
        if (!bold_path.empty()) {
            font_bold_ = io.Fonts->AddFontFromFileTTF(bold_path.c_str(), base_bold, nullptr, glyph_ranges);
            font_title_ = io.Fonts->AddFontFromFileTTF(bold_path.c_str(), base_title, nullptr, glyph_ranges);
        } else {
            font_bold_ = font_regular_;
            font_title_ = font_regular_;
        }
    } else {
        io.Fonts->AddFontDefault();
    }

    // Setup Dear ImGui style scaled
    Theme::applyMacStyle(scale_);

    // Setup Platform/Renderer backends
    ImGui_ImplSDL2_InitForSDLRenderer(window_, renderer_);
    ImGui_ImplSDLRenderer2_Init(renderer_);

    pollDevices();
    last_device_poll_ = std::chrono::steady_clock::now();

    if (auto_mirror_) {
        int idx = -1;
        for (int i = 0; i < static_cast<int>(devices_.size()); ++i) {
            if (preferred_serial_.empty() ? devices_[i].isReady()
                                          : devices_[i].serial == preferred_serial_) {
                idx = i;
                break;
            }
        }
        if (idx >= 0) {
            selected_device_idx_ = idx;
            last_inspected_serial_.clear(); // force the inspector onto this device
            startMirroring(idx);
        } else {
            std::cerr << "--mirror: no " << (preferred_serial_.empty() ? "ready device" : "device " + preferred_serial_)
                      << " in `adb devices`\n";
        }
        auto_mirror_ = false;
    }

    return true;
}

void GuiApp::cleanup() {
    stopMirroring();

    if (video_texture_) {
        SDL_DestroyTexture(video_texture_);
        video_texture_ = nullptr;
    }

    ImGui_ImplSDLRenderer2_Shutdown();
    ImGui_ImplSDL2_Shutdown();
    ImGui::DestroyContext();

    if (renderer_) {
        SDL_DestroyRenderer(renderer_);
        renderer_ = nullptr;
    }
    if (window_) {
        SDL_DestroyWindow(window_);
        window_ = nullptr;
    }
    SDL_Quit();
}

void GuiApp::showToast(const std::string& msg, int seconds) {
    toast_message_ = msg;
    toast_expiry_ = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
}

void GuiApp::pollDevices() {
    std::vector<AdbDevice> list;
    if (adb_.getDevices(list)) {
        devices_ = list;
        if (selected_device_idx_ >= static_cast<int>(devices_.size())) {
            selected_device_idx_ = devices_.empty() ? -1 : 0;
        } else if (selected_device_idx_ < 0 && !devices_.empty()) {
            selected_device_idx_ = 0;
        }

        if (selected_device_idx_ >= 0 && selected_device_idx_ < static_cast<int>(devices_.size())) {
            const auto& dev = devices_[selected_device_idx_];
            if (dev.serial != last_inspected_serial_) {
                last_inspected_serial_ = dev.serial;
                refreshPackages(dev.serial);
                refreshFiles(dev.serial);
                battery_level_ = adb_.getBatteryLevel(dev.serial);
            }
        }
    }
}

void GuiApp::refreshPackages(const std::string& serial) {
    packages_ = adb_.getPackages(serial, !show_system_apps_);
}

void GuiApp::refreshFiles(const std::string& serial) {
    std::string raw = adb_.shell(serial, "ls -1 " + current_remote_path_);
    remote_files_.clear();
    std::istringstream stream(raw);
    std::string line;
    while (std::getline(stream, line)) {
        while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) line.pop_back();
        if (!line.empty()) remote_files_.push_back(line);
    }
}

void GuiApp::startMirroring(int device_idx) {
    if (device_idx < 0 || device_idx >= static_cast<int>(devices_.size())) return;
    const auto& dev = devices_[device_idx];
    if (!dev.isReady()) {
        showToast("Device is not ready: " + dev.state);
        return;
    }

    if (session_active_ && session_ && session_->getSerial() == dev.serial) {
        showToast("Already mirroring " + dev.displayName());
        return;
    }

    stopMirroring();

    session_ = std::make_unique<AgentSession>(dev.serial);
    session_->start(1080, 2400);
    session_active_ = true;
    showToast("Connecting to " + dev.displayName() + "...");
}

void GuiApp::stopMirroring() {
    if (session_) {
        session_->stop();
        session_.reset();
    }
    session_active_ = false;
}

void GuiApp::run() {
    bool done = false;

    while (!done) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            ImGui_ImplSDL2_ProcessEvent(&event);
            if (event.type == SDL_QUIT) {
                done = true;
            }
            if (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_CLOSE
                && event.window.windowID == SDL_GetWindowID(window_)) {
                done = true;
            }
        }

        // Periodic ADB poll
        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::seconds>(now - last_device_poll_).count() >= 3) {
            pollDevices();
            last_device_poll_ = now;
        }

        // Start the Dear ImGui frame
        ImGui_ImplSDLRenderer2_NewFrame();
        ImGui_ImplSDL2_NewFrame();
        ImGui::NewFrame();

        int win_w, win_h;
        SDL_GetWindowSize(window_, &win_w, &win_h);

        // Scaled sizes matching macOS GUI
        float sidebar_w = 260.0f * scale_;
        float inspector_w = 320.0f * scale_;
        float stage_w = static_cast<float>(win_w) - sidebar_w - inspector_w;
        if (stage_w < 360.0f * scale_) stage_w = 360.0f * scale_;
        float main_h = static_cast<float>(win_h);

        // Render the three panels
        renderLeftSidebar(sidebar_w, main_h);
        renderCenterStage(sidebar_w, stage_w, main_h);
        renderRightInspector(inspector_w, main_h);

        // Toast message overlay
        if (!toast_message_.empty() && std::chrono::steady_clock::now() < toast_expiry_) {
            ImGui::SetNextWindowPos(ImVec2(win_w * 0.5f - 150.0f, win_h - 60.0f));
            ImGui::SetNextWindowSize(ImVec2(300.0f, 40.0f));
            ImGuiWindowFlags toast_flags = ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoNav;
            ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.1f, 0.1f, 0.12f, 0.90f));
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.0f, 1.0f, 1.0f, 1.0f));
            ImGui::Begin("##Toast", nullptr, toast_flags);
            ImGui::TextUnformatted(toast_message_.c_str());
            ImGui::End();
            ImGui::PopStyleColor(2);
        }

        // Rendering
        ImGui::Render();
        SDL_SetRenderDrawColor(renderer_, 247, 247, 250, 255);
        SDL_RenderClear(renderer_);
        ImGui_ImplSDLRenderer2_RenderDrawData(ImGui::GetDrawData(), renderer_);

        frame_count_++;
        // Dump once the UI has settled and, if a mirror was requested, once the
        // first video frame has been shown (or the session gave up).
        bool mirror_settled = !session_ || session_->getDecoder().hasFrame() ||
                              session_->getState() == SessionState::FAILED;
        if (!dump_frame_path_.empty() && frame_count_ >= 30 && mirror_settled) {
            SDL_Surface* sshot = SDL_CreateRGBSurfaceWithFormat(0, win_w, win_h, 32, SDL_PIXELFORMAT_ARGB8888);
            if (sshot) {
                if (SDL_RenderReadPixels(renderer_, NULL, SDL_PIXELFORMAT_ARGB8888, sshot->pixels, sshot->pitch) == 0) {
                    SDL_SaveBMP(sshot, dump_frame_path_.c_str());
                    std::cout << "Dumped frame to " << dump_frame_path_ << "\n";
                }
                SDL_FreeSurface(sshot);
            }
            dump_frame_path_.clear();
        }

        SDL_RenderPresent(renderer_);

        if (stats_) {
            auto t = std::chrono::steady_clock::now();
            double dt = std::chrono::duration<double>(t - stats_last_).count();
            if (dt >= 5.0) {
                uint64_t decoded = session_ ? session_->getDecoder().framesDecoded() : 0;
                if (stats_last_.time_since_epoch().count() != 0) {
                    std::cerr << "stats: decoded " << std::fixed << std::setprecision(1)
                              << (decoded - stats_decoded_last_) / dt << " fps, rendered "
                              << (frame_count_ - stats_rendered_last_) / dt << " fps, texture "
                              << tex_w_ << "x" << tex_h_ << "\n";
                }
                stats_last_ = t;
                stats_decoded_last_ = decoded;
                stats_rendered_last_ = frame_count_;
            }
        }
    }
}

// ----------------------------------------------------------------------------
// LEFT SIDEBAR (Device list, search, status, connect)
// ----------------------------------------------------------------------------
void GuiApp::renderLeftSidebar(float width, float height) {
    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(ImVec2(width, height));
    ImGuiWindowFlags flags = ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                             ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoCollapse;

    ImGui::PushStyleColor(ImGuiCol_WindowBg, Theme::ColorBgSidebar);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(12.0f * scale_, 14.0f * scale_));
    ImGui::Begin("##Sidebar", nullptr, flags);

    // Header: Traffic Light Dots + Action Buttons (+ and reload)
    ImDrawList* draw_list = ImGui::GetWindowDrawList();
    ImVec2 cursor = ImGui::GetCursorScreenPos();
    float dot_radius = 5.5f * scale_;
    float dot_spacing = 16.0f * scale_;
    draw_list->AddCircleFilled(ImVec2(cursor.x + 8.0f * scale_, cursor.y + 11.0f * scale_), dot_radius, IM_COL32(255, 95, 87, 255));
    draw_list->AddCircleFilled(ImVec2(cursor.x + 8.0f * scale_ + dot_spacing, cursor.y + 11.0f * scale_), dot_radius, IM_COL32(254, 188, 46, 255));
    draw_list->AddCircleFilled(ImVec2(cursor.x + 8.0f * scale_ + dot_spacing * 2, cursor.y + 11.0f * scale_), dot_radius, IM_COL32(40, 200, 64, 255));

    ImGui::SetCursorPosX(width - 98.0f * scale_);
    ImVec2 top_btn_sz(24.0f * scale_, 22.0f * scale_);
    if (IconButton("##AddIp", Icons::drawPlus, top_btn_sz, "Connect to Device via IP")) {
        show_connect_popup_ = true;
    }
    ImGui::SameLine();
    if (IconButton("##Refresh", Icons::drawListMenu, top_btn_sz, "Refresh device list")) {
        pollDevices();
        showToast("Refreshed device list");
    }
    ImGui::SameLine();
    if (IconButton("##SidebarToggle", Icons::drawSidebarToggle, top_btn_sz, "Toggle Sidebar")) {
        showToast("Sidebar toggled");
    }

    ImGui::Spacing();
    ImGui::Spacing();

    // Connect IP Popup Modal
    if (show_connect_popup_) {
        ImGui::OpenPopup("Connect Network Device");
    }
    if (ImGui::BeginPopupModal("Connect Network Device", &show_connect_popup_, ImGuiWindowFlags_AlwaysAutoResize)) {
        ImGui::Text("Enter Device IP:Port:");
        ImGui::InputText("##IP", connect_ip_buf_, sizeof(connect_ip_buf_));
        if (!connect_status_msg_.empty()) {
            ImGui::TextColored(ImVec4(0.8f, 0.2f, 0.2f, 1.0f), "%s", connect_status_msg_.c_str());
        }
        if (ImGui::Button("Connect", ImVec2(100 * scale_, 0))) {
            std::string msg;
            if (adb_.connectNetwork(connect_ip_buf_, msg)) {
                showToast("Connected: " + msg);
                show_connect_popup_ = false;
                pollDevices();
            } else {
                connect_status_msg_ = msg;
            }
        }
        ImGui::SameLine();
        if (ImGui::Button("Cancel", ImVec2(80 * scale_, 0))) {
            show_connect_popup_ = false;
        }
        ImGui::EndPopup();
    }

    // Pill-shaped Search Bar with Search Icon
    ImVec2 search_pos = ImGui::GetCursorScreenPos();
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 12.0f * scale_);
    ImGui::PushItemWidth(width - 24.0f * scale_);
    ImGui::InputTextWithHint("##Search", "      Search", search_filter_, sizeof(search_filter_));
    ImGui::PopItemWidth();
    ImGui::PopStyleVar();
    Icons::drawSearch(draw_list, ImVec2(search_pos.x + 8.0f * scale_, search_pos.y + 7.0f * scale_), 16.0f * scale_, IM_COL32(140, 140, 145, 255));

    ImGui::Spacing();
    if (font_caption_) ImGui::PushFont(font_caption_);
    ImGui::TextColored(Theme::ColorTextSecondary, "AVAILABLE");
    if (font_caption_) ImGui::PopFont();
    ImGui::Spacing();

    // Device Cards List
    std::string search_query = search_filter_;
    std::transform(search_query.begin(), search_query.end(), search_query.begin(), ::tolower);

    for (int i = 0; i < static_cast<int>(devices_.size()); ++i) {
        const auto& dev = devices_[i];
        std::string display_title = dev.displayName();
        std::string lower_title = display_title;
        std::transform(lower_title.begin(), lower_title.end(), lower_title.begin(), ::tolower);

        if (!search_query.empty() && lower_title.find(search_query) == std::string::npos &&
            dev.serial.find(search_query) == std::string::npos) {
            continue;
        }

        bool is_selected = (selected_device_idx_ == i);
        bool is_mirroring = (session_active_ && session_ && session_->getSerial() == dev.serial);

        ImGui::PushID(i);
        ImVec2 card_pos = ImGui::GetCursorScreenPos();
        float card_w = width - 24.0f * scale_;
        float card_h = 50.0f * scale_;

        // Custom Card Drawing
        ImU32 bg_color = is_selected ? IM_COL32(232, 242, 255, 255) : IM_COL32(255, 255, 255, 255);
        ImU32 border_color = is_selected ? IM_COL32(0, 122, 255, 180) : IM_COL32(225, 225, 230, 200);
        draw_list->AddRectFilled(card_pos, ImVec2(card_pos.x + card_w, card_pos.y + card_h), bg_color, 8.0f * scale_);
        draw_list->AddRect(card_pos, ImVec2(card_pos.x + card_w, card_pos.y + card_h), border_color, 8.0f * scale_, 0, is_selected ? 1.5f : 1.0f);

        // Status Dot
        ImU32 status_col = dev.isReady() ? IM_COL32(52, 199, 89, 255) :
                           (dev.state == "unauthorized" ? IM_COL32(255, 204, 0, 255) : IM_COL32(255, 59, 48, 255));
        draw_list->AddCircleFilled(ImVec2(card_pos.x + 13.0f * scale_, card_pos.y + card_h * 0.5f), 5.0f * scale_, status_col);

        // Phone Icon
        Icons::drawPhone(draw_list, ImVec2(card_pos.x + 24.0f * scale_, card_pos.y + (card_h - 22.0f * scale_) * 0.5f), 22.0f * scale_,
                         is_selected ? IM_COL32(0, 122, 255, 255) : IM_COL32(100, 100, 105, 255));

        // Device Title & Subtitle
        std::string sub = dev.serial;
        if (dev.serial.find(":") != std::string::npos) sub = dev.serial;

        ImGui::SetCursorScreenPos(ImVec2(card_pos.x + 48.0f * scale_, card_pos.y + 6.0f * scale_));
        if (font_bold_) ImGui::PushFont(font_bold_);
        ImGui::TextColored(Theme::ColorTextPrimary, "%s", display_title.c_str());
        if (font_bold_) ImGui::PopFont();

        ImGui::SetCursorScreenPos(ImVec2(card_pos.x + 48.0f * scale_, card_pos.y + 26.0f * scale_));
        if (font_caption_) ImGui::PushFont(font_caption_);
        ImGui::TextColored(Theme::ColorTextSecondary, "%s", sub.c_str());
        if (font_caption_) ImGui::PopFont();

        // Invisible button to catch clicks
        ImGui::SetCursorScreenPos(card_pos);
        if (ImGui::InvisibleButton("##CardBtn", ImVec2(card_w, card_h))) {
            selected_device_idx_ = i;
            last_inspected_serial_ = dev.serial;
            refreshPackages(dev.serial);
            refreshFiles(dev.serial);
            battery_level_ = adb_.getBatteryLevel(dev.serial);
        }

        // Double click to start mirroring
        if (ImGui::IsItemHovered() && ImGui::IsMouseDoubleClicked(ImGuiMouseButton_Left)) {
            startMirroring(i);
        }

        // Right-click Context Menu with Icons (Exact match with macOS screenshot!)
        if (ImGui::BeginPopupContextItem("DeviceContextMenu")) {
            selected_device_idx_ = i;
            if (is_mirroring) {
                if (MenuItemWithIcon("Stop Screen Mirroring", nullptr, Icons::drawScreen, scale_)) {
                    stopMirroring();
                }
            } else {
                if (MenuItemWithIcon("Start Screen Mirroring", nullptr, Icons::drawScreen, scale_)) {
                    startMirroring(i);
                }
            }
            if (MenuItemWithIcon("Desktop Mode", nullptr, Icons::drawScreen, scale_)) {
                showToast("Desktop Mode triggered");
            }
            if (MenuItemWithIcon("Copy Serial", nullptr, Icons::drawCopy, scale_)) {
                ImGui::SetClipboardText(dev.serial.c_str());
                showToast("Copied serial: " + dev.serial);
            }
            if (MenuItemWithIcon("Disconnect", nullptr, Icons::drawDisconnect, scale_)) {
                adb_.disconnectNetwork(dev.serial);
                pollDevices();
            }
            ImGui::Separator();
            if (MenuItemWithIcon("Take Screenshot", nullptr, Icons::drawCamera, scale_)) {
                std::string path = "/tmp/screenshot_" + dev.serial + ".png";
                if (adb_.takeScreenshot(dev.serial, path)) {
                    showToast("Screenshot saved to " + path);
                }
            }
            if (MenuItemWithIcon("Record Screen", nullptr, Icons::drawRecord, scale_)) {
                showToast("Recording started...");
            }
            ImGui::Separator();
            if (MenuItemWithIcon("Back", nullptr, Icons::drawBack, scale_)) {
                if (session_) session_->sendKey(AndroidKey::BACK);
            }
            if (MenuItemWithIcon("Home", nullptr, Icons::drawHome, scale_)) {
                if (session_) session_->sendKey(AndroidKey::HOME);
            }
            if (MenuItemWithIcon("Recents", nullptr, Icons::drawRecents, scale_)) {
                if (session_) session_->sendKey(AndroidKey::APP_SWITCH);
            }
            if (MenuItemWithIcon("Rotate", nullptr, Icons::drawRotate, scale_)) {
                if (session_) session_->setOrientation(-1);
            }
            ImGui::Separator();
            if (MenuItemWithIcon("Wake", nullptr, Icons::drawSun, scale_)) {
                if (session_) session_->wakeOrPower(false);
            }
            if (MenuItemWithIcon("Power Button", nullptr, Icons::drawPower, scale_)) {
                if (session_) session_->wakeOrPower(true);
            }
            ImGui::Separator();
            if (MenuItemWithIcon("View in 3D", nullptr, Icons::drawCube, scale_)) {
                showToast("3D Device Twin active");
            }
            ImGui::Separator();
            if (MenuItemWithIcon("Open in New Window", nullptr, Icons::drawWindow, scale_)) {
                showToast("Opened in new window");
            }
            if (MenuItemWithIcon("Open in New Tab", nullptr, Icons::drawPlus, scale_)) {
                showToast("Opened in new tab");
            }
            if (MenuItemWithIcon("Pin Window on Top", nullptr, Icons::drawPin, scale_)) {
                showToast("Pinned on top");
            }
            ImGui::Separator();
            if (MenuItemWithIcon("Reconnect", nullptr, Icons::drawRefresh, scale_)) {
                startMirroring(i);
            }
            ImGui::EndPopup();
        }

        ImGui::SetCursorScreenPos(ImVec2(card_pos.x, card_pos.y + card_h + 8.0f * scale_));
        ImGui::PopID();
    }

    if (devices_.empty()) {
        ImGui::Spacing();
        ImGui::TextColored(Theme::ColorTextSecondary, "No devices found");
        ImGui::TextColored(Theme::ColorTextTertiary, "Plug in USB or + connect IP");
    }

    // Bottom status bar matching macOS "adb server 0029 — no devices"
    ImGui::SetCursorPos(ImVec2(12.0f * scale_, height - 30.0f * scale_));
    std::ostringstream status_txt;
    if (devices_.empty()) {
        status_txt << "adb server 5037 — no devices";
    } else {
        status_txt << "adb server 5037 — " << devices_.size() << (devices_.size() == 1 ? " device" : " devices");
    }
    if (font_caption_) ImGui::PushFont(font_caption_);
    ImGui::TextColored(Theme::ColorTextTertiary, "%s", status_txt.str().c_str());
    if (font_caption_) ImGui::PopFont();

    ImGui::End();
    ImGui::PopStyleVar();
    ImGui::PopStyleColor();
}

// ----------------------------------------------------------------------------
// CENTER STAGE (Top header, Phone Bezel + Screen, Bottom Control Strip)
// ----------------------------------------------------------------------------
void GuiApp::renderCenterStage(float start_x, float width, float height) {
    ImGui::SetNextWindowPos(ImVec2(start_x, 0));
    ImGui::SetNextWindowSize(ImVec2(width, height));
    ImGuiWindowFlags flags = ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                             ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoCollapse;

    ImGui::PushStyleColor(ImGuiCol_WindowBg, Theme::ColorBgStage);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(16.0f * scale_, 12.0f * scale_));
    ImGui::Begin("##CenterStage", nullptr, flags);

    // Top Header Pill: "No device" or selected device name (matches macOS screenshot top bar)
    std::string header_title = "No device";
    if (selected_device_idx_ >= 0 && selected_device_idx_ < static_cast<int>(devices_.size())) {
        header_title = devices_[selected_device_idx_].displayName();
    }
    ImDrawList* draw_list = ImGui::GetWindowDrawList();
    ImVec2 pill_pos = ImGui::GetCursorScreenPos();
    pill_pos.x += 12.0f * scale_;
    pill_pos.y += 2.0f * scale_;

    ImVec2 title_sz = font_medium_ ? font_medium_->CalcTextSizeA(14.0f * scale_, FLT_MAX, 0.0f, header_title.c_str())
                                   : ImGui::CalcTextSize(header_title.c_str());
    float pill_pad_x = 14.0f * scale_;
    float pill_w = title_sz.x + pill_pad_x * 2.0f;
    float pill_h = 26.0f * scale_;

    draw_list->AddRectFilled(pill_pos, ImVec2(pill_pos.x + pill_w, pill_pos.y + pill_h),
                             IM_COL32(245, 245, 247, 255), pill_h * 0.5f);

    float text_y = pill_pos.y + (pill_h - title_sz.y) * 0.5f;
    if (font_medium_) {
        draw_list->AddText(font_medium_, 14.0f * scale_,
                           ImVec2(pill_pos.x + pill_pad_x, text_y),
                           IM_COL32(28, 28, 30, 255), header_title.c_str());
    } else {
        draw_list->AddText(ImVec2(pill_pos.x + pill_pad_x, text_y),
                           IM_COL32(28, 28, 30, 255), header_title.c_str());
    }

    // Phone & Stage Area
    float available_h = height - 90.0f * scale_;
    float available_w = width - 30.0f * scale_;

    DecodedFrame frame;
    bool has_frame = (session_ && session_->getDecoder().getLatestFrame(frame));

    if (session_active_ && has_frame) {
        renderLiveMirror(ImVec2(start_x + 15.0f * scale_, 42.0f * scale_), ImVec2(available_w, available_h), frame);
    } else {
        renderPhoneMockup(ImVec2(start_x + width * 0.5f, 42.0f * scale_ + available_h * 0.44f), ImVec2(available_w, available_h));
    }

    // Bottom Navigation Control Strip
    renderControlStrip(ImVec2(start_x, height - 52.0f * scale_), width);

    ImGui::End();
    ImGui::PopStyleVar();
    ImGui::PopStyleColor();
}

// Phone Mockup when idle (matches macOS gui-default.png and gui-focused.png)
void GuiApp::renderPhoneMockup(ImVec2 center, ImVec2 max_size) {
    ImDrawList* draw_list = ImGui::GetWindowDrawList();

    // Phone dimensions matching macOS ratio (approx 120pt x 289pt)
    float phone_w = std::min(max_size.x * 0.42f, 195.0f * scale_);
    float phone_h = phone_w * 2.41f;
    if (phone_h > max_size.y * 0.60f) {
        phone_h = max_size.y * 0.60f;
        phone_w = phone_h / 2.41f;
    }

    // Centered in upper-mid section of center stage
    float phone_cy = center.y - 48.0f * scale_;
    ImVec2 top_left(center.x - phone_w * 0.5f, phone_cy - phone_h * 0.5f);
    ImVec2 bottom_right(center.x + phone_w * 0.5f, phone_cy + phone_h * 0.5f);

    // Outer Phone Chassis (black body with rounded corners)
    draw_list->AddRectFilled(top_left, bottom_right, IM_COL32(10, 10, 14, 255), 18.0f * scale_);
    draw_list->AddRect(top_left, bottom_right, IM_COL32(28, 28, 34, 255), 18.0f * scale_, 0, 1.5f * scale_);

    // Inner Display Area (dark navy/slate background matching macOS gui-default)
    float bezel = 4.0f * scale_;
    ImVec2 screen_tl(top_left.x + bezel, top_left.y + bezel);
    ImVec2 screen_br(bottom_right.x - bezel, bottom_right.y - bezel);
    draw_list->AddRectFilled(screen_tl, screen_br, IM_COL32(45, 52, 68, 255), 14.0f * scale_);

    // Camera punch hole at top center
    draw_list->AddCircleFilled(ImVec2(center.x, screen_tl.y + 10.0f * scale_), 3.5f * scale_, IM_COL32(10, 10, 12, 255));

    // Below the phone: Status text ("No device selected" or device name)
    std::string device_label = "No device selected";
    if (selected_device_idx_ >= 0 && selected_device_idx_ < static_cast<int>(devices_.size())) {
        device_label = devices_[selected_device_idx_].displayName();
    }

    float text_y = bottom_right.y + 18.0f * scale_;
    ImVec2 text_sz = font_bold_ ? font_bold_->CalcTextSizeA(15.5f * scale_, FLT_MAX, 0.0f, device_label.c_str())
                                : ImGui::CalcTextSize(device_label.c_str());
    if (font_bold_) {
        draw_list->AddText(font_bold_, 15.5f * scale_,
                           ImVec2(center.x - text_sz.x * 0.5f, text_y),
                           IM_COL32(28, 28, 30, 255), device_label.c_str());
    } else {
        draw_list->AddText(ImVec2(center.x - text_sz.x * 0.5f, text_y),
                           IM_COL32(28, 28, 30, 255), device_label.c_str());
    }

    // Below text: "View Screen" Pill Button with Screen Sharing Icon
    float btn_w = 146.0f * scale_;
    float btn_h = 35.0f * scale_;
    float btn_x = center.x - btn_w * 0.5f;
    float btn_y = text_y + text_sz.y + 14.0f * scale_;

    ImGui::SetCursorScreenPos(ImVec2(btn_x, btn_y));
    bool clicked = ImGui::InvisibleButton("##ViewScreenBtn", ImVec2(btn_w, btn_h));
    bool hovered = ImGui::IsItemHovered();
    bool active = ImGui::IsItemActive();

    // Default vs Focused styling (exact match to gui-default.png and gui-focused.png)
    // Focused/Hovered: vibrant purple-blue #5B6EF5
    // Default: light gray #E3E3E8
    ImU32 btn_bg = (hovered || active) ? IM_COL32(91, 110, 245, 255) : IM_COL32(227, 227, 232, 255);
    ImU32 fg_col = (hovered || active) ? IM_COL32(255, 255, 255, 255) : IM_COL32(28, 28, 30, 255);
    if (active) btn_bg = IM_COL32(75, 95, 230, 255);

    draw_list->AddRectFilled(ImVec2(btn_x, btn_y), ImVec2(btn_x + btn_w, btn_y + btn_h),
                             btn_bg, btn_h * 0.5f);

    float icon_sz = 17.0f * scale_;
    float gap = 8.0f * scale_;
    const char* label = "View Screen";
    ImVec2 label_sz = font_medium_ ? font_medium_->CalcTextSizeA(14.5f * scale_, FLT_MAX, 0.0f, label)
                                   : ImGui::CalcTextSize(label);
    float total_content_w = icon_sz + gap + label_sz.x;
    float content_x = btn_x + (btn_w - total_content_w) * 0.5f;

    Icons::drawViewScreen(draw_list, ImVec2(content_x, btn_y + (btn_h - icon_sz) * 0.5f),
                          icon_sz, fg_col, btn_bg);

    float label_y = btn_y + (btn_h - label_sz.y) * 0.5f;
    if (font_medium_) {
        draw_list->AddText(font_medium_, 14.5f * scale_,
                           ImVec2(content_x + icon_sz + gap, label_y),
                           fg_col, label);
    } else {
        draw_list->AddText(ImVec2(content_x + icon_sz + gap, label_y),
                           fg_col, label);
    }

    if (clicked) {
        if (selected_device_idx_ >= 0) {
            startMirroring(selected_device_idx_);
        } else {
            showToast("Please select a device first");
        }
    }
}

// Live Mirrored Display inside Bezel
void GuiApp::renderLiveMirror(ImVec2 origin, ImVec2 size, const DecodedFrame& frame) {
    if (frame.rgba.empty()) return;

    // Update SDL texture
    if (!video_texture_ || tex_w_ != frame.width || tex_h_ != frame.height) {
        if (video_texture_) SDL_DestroyTexture(video_texture_);
        video_texture_ = SDL_CreateTexture(renderer_, SDL_PIXELFORMAT_RGBA32,
                                           SDL_TEXTUREACCESS_STREAMING, frame.width, frame.height);
        tex_w_ = frame.width;
        tex_h_ = frame.height;
    }

    SDL_UpdateTexture(video_texture_, nullptr, frame.rgba.data(), frame.width * 4);

    // Calculate aspect fit inside center stage
    int rot_w = (frame.displayOrientation % 2 == 1) ? frame.displayHeight : frame.displayWidth;
    int rot_h = (frame.displayOrientation % 2 == 1) ? frame.displayWidth : frame.displayHeight;
    if (rot_w <= 0 || rot_h <= 0) {
        rot_w = frame.width;
        rot_h = frame.height;
    }

    float aspect = static_cast<float>(rot_w) / static_cast<float>(rot_h);
    float target_h = size.y - 20.0f * scale_;
    float target_w = target_h * aspect;

    if (target_w > size.x - 20.0f * scale_) {
        target_w = size.x - 20.0f * scale_;
        target_h = target_w / aspect;
    }

    float pos_x = origin.x + (size.x - target_w) * 0.5f;
    float pos_y = origin.y + (size.y - target_h) * 0.5f;

    ImDrawList* draw_list = ImGui::GetWindowDrawList();

    // Black Phone Bezel Surround (~12px margin scaled)
    float bezel = 12.0f * scale_;
    ImVec2 bezel_tl(pos_x - bezel, pos_y - bezel);
    ImVec2 bezel_br(pos_x + target_w + bezel, pos_y + target_h + bezel);
    draw_list->AddRectFilled(bezel_tl, bezel_br, IM_COL32(18, 18, 22, 255), 28.0f * scale_);
    draw_list->AddRect(bezel_tl, bezel_br, IM_COL32(55, 55, 62, 255), 28.0f * scale_, 0, 1.5f * scale_);

    // Live Video Image with rounded corners matching phone screen
    draw_list->AddImageRounded((ImTextureID)video_texture_,
                               ImVec2(pos_x, pos_y),
                               ImVec2(pos_x + target_w, pos_y + target_h),
                               ImVec2(0, 0), ImVec2(1, 1),
                               IM_COL32_WHITE, 20.0f * scale_);

    // Punch Hole Camera Cutout at top center
    draw_list->AddCircleFilled(ImVec2(pos_x + target_w * 0.5f, pos_y + 14.0f), 5.0f, IM_COL32(0, 0, 0, 255));

    // Handle mouse touch events on the mirrored screen
    handleTouchInput(ImVec2(pos_x, pos_y), ImVec2(target_w, target_h),
                     frame.displayWidth, frame.displayHeight, frame.displayOrientation);
    handleKeyboardInput();
}

void GuiApp::handleTouchInput(ImVec2 img_pos, ImVec2 img_size, int dev_w, int dev_h, int quadrants) {
    if (!session_ || dev_w <= 0 || dev_h <= 0) return;

    ImVec2 mouse_pos = ImGui::GetMousePos();
    bool inside = (mouse_pos.x >= img_pos.x && mouse_pos.x <= img_pos.x + img_size.x &&
                   mouse_pos.y >= img_pos.y && mouse_pos.y <= img_pos.y + img_size.y);

    auto map_coords = [&](ImVec2 pos) -> std::pair<int, int> {
        float fx = std::clamp((pos.x - img_pos.x) / img_size.x, 0.0f, 1.0f);
        float fy = std::clamp((pos.y - img_pos.y) / img_size.y, 0.0f, 1.0f);

        float nx = fx, ny = fy;
        switch (quadrants) {
            case 1: nx = 1.0f - fy; ny = fx; break;
            case 2: nx = 1.0f - fx; ny = 1.0f - fy; break;
            case 3: nx = fy; ny = 1.0f - fx; break;
            default: nx = fx; ny = fy; break;
        }
        return { static_cast<int>(nx * dev_w), static_cast<int>(ny * dev_h) };
    };

    // Mouse button down
    if (inside && ImGui::IsMouseClicked(ImGuiMouseButton_Left)) {
        is_touch_active_ = true;
        auto [dx, dy] = map_coords(mouse_pos);
        session_->sendTouch(dx, dy, MotionAction::DOWN);
        last_mouse_pos_ = mouse_pos;
    }
    // Mouse drag
    else if (is_touch_active_ && ImGui::IsMouseDragging(ImGuiMouseButton_Left, 0.5f)) {
        auto [dx, dy] = map_coords(mouse_pos);
        session_->sendTouch(dx, dy, MotionAction::MOVE);
        last_mouse_pos_ = mouse_pos;
    }
    // Mouse button up
    else if (is_touch_active_ && ImGui::IsMouseReleased(ImGuiMouseButton_Left)) {
        is_touch_active_ = false;
        auto [dx, dy] = map_coords(mouse_pos);
        session_->sendTouch(dx, dy, MotionAction::UP);
    }

    // Right-click = Back button
    if (inside && ImGui::IsMouseClicked(ImGuiMouseButton_Right)) {
        session_->sendKey(AndroidKey::BACK);
    }

    // Mouse wheel scrolling
    float wheel = ImGui::GetIO().MouseWheel;
    if (inside && std::abs(wheel) > 0.01f) {
        auto [dx, dy] = map_coords(mouse_pos);
        session_->sendTouch(dx, dy, MotionAction::MOVE);
    }
}

void GuiApp::handleKeyboardInput() {
    if (!session_) return;
    ImGuiIO& io = ImGui::GetIO();

    if (ImGui::IsKeyPressed(ImGuiKey_Backspace)) session_->sendKey(AndroidKey::DEL);
    if (ImGui::IsKeyPressed(ImGuiKey_Enter) || ImGui::IsKeyPressed(ImGuiKey_KeypadEnter)) session_->sendKey(AndroidKey::ENTER);
    if (ImGui::IsKeyPressed(ImGuiKey_Escape)) session_->sendKey(AndroidKey::BACK);
    if (ImGui::IsKeyPressed(ImGuiKey_Tab)) session_->sendKey(AndroidKey::TAB);
    if (ImGui::IsKeyPressed(ImGuiKey_Home)) session_->sendKey(AndroidKey::HOME);
    if (ImGui::IsKeyPressed(ImGuiKey_UpArrow)) session_->sendKey(AndroidKey::DPAD_UP);
    if (ImGui::IsKeyPressed(ImGuiKey_DownArrow)) session_->sendKey(AndroidKey::DPAD_DOWN);
    if (ImGui::IsKeyPressed(ImGuiKey_LeftArrow)) session_->sendKey(AndroidKey::DPAD_LEFT);
    if (ImGui::IsKeyPressed(ImGuiKey_RightArrow)) session_->sendKey(AndroidKey::DPAD_RIGHT);

    for (int i = 0; i < io.InputQueueCharacters.Size; ++i) {
        ImWchar c = io.InputQueueCharacters[i];
        if (c >= 32) {
            std::string s;
            if (c < 0x80) {
                s.push_back(static_cast<char>(c));
            } else {
                s.push_back(static_cast<char>(0xC0 | ((c >> 6) & 0x1F)));
                s.push_back(static_cast<char>(0x80 | (c & 0x3F)));
            }
            session_->sendText(s);
        }
    }
}

// Bottom Navigation Control Strip
void GuiApp::renderControlStrip(ImVec2 pos, float width) {
    ImDrawList* draw_list = ImGui::GetWindowDrawList();

    // Top hairline separator
    draw_list->AddLine(pos, ImVec2(pos.x + width, pos.y), IM_COL32(230, 230, 235, 255), 1.0f);

    struct ActionBtn {
        const char* id;
        std::function<void(ImDrawList*, ImVec2, float, ImU32)> draw_icon;
        const char* tooltip;
        std::function<void()> action;
    };

    std::vector<ActionBtn> buttons = {
        { "##Back", Icons::drawBack, "Back (Esc)", [this]() { if (session_) session_->sendKey(AndroidKey::BACK); } },
        { "##Home", Icons::drawHome, "Home", [this]() { if (session_) session_->sendKey(AndroidKey::HOME); } },
        { "##Recents", Icons::drawRecents, "Overview / Recents", [this]() { if (session_) session_->sendKey(AndroidKey::APP_SWITCH); } },
        { "##VolDown", Icons::drawVolumeDown, "Volume Down", [this]() { if (session_) session_->sendKey(AndroidKey::VOLUME_DOWN); } },
        { "##VolUp", Icons::drawVolumeUp, "Volume Up", [this]() { if (session_) session_->sendKey(AndroidKey::VOLUME_UP); } },
        { "##Power", Icons::drawPower, "Power Button", [this]() { if (session_) session_->sendKey(AndroidKey::POWER); } },
        { "##Rotate", Icons::drawRotate, "Rotate Screen", [this]() { if (session_) session_->setOrientation(-1); } },
        { "##Camera", Icons::drawCamera, "Take Screenshot", [this]() {
            if (selected_device_idx_ >= 0) {
                std::string path = "/tmp/screenshot.png";
                if (adb_.takeScreenshot(devices_[selected_device_idx_].serial, path)) {
                    showToast("Saved " + path);
                }
            }
        }},
        { "##Record", Icons::drawRecord, "Record Screen", [this]() { showToast("Record toggled"); } }
    };

    float btn_w = 38.0f * scale_;
    float btn_h = 34.0f * scale_;
    float spacing = 44.0f * scale_; // Matches ~44pt spacing from macOS screenshot
    float total_w = (buttons.size() - 1) * spacing + btn_w;
    float start_x = pos.x + (width - total_w) * 0.5f;

    for (size_t i = 0; i < buttons.size(); ++i) {
        ImGui::SetCursorScreenPos(ImVec2(start_x + i * spacing, pos.y + 8.0f * scale_));
        if (FlatNavButton(buttons[i].id, buttons[i].draw_icon, ImVec2(btn_w, btn_h), buttons[i].tooltip, scale_)) {
            buttons[i].action();
        }
    }
}

// ----------------------------------------------------------------------------
// RIGHT INSPECTOR PANE (Info, Apps, Files, Logcat)
// ----------------------------------------------------------------------------
void GuiApp::renderRightInspector(float width, float height) {
    float start_x = ImGui::GetIO().DisplaySize.x - width;
    ImGui::SetNextWindowPos(ImVec2(start_x, 0));
    ImGui::SetNextWindowSize(ImVec2(width, height));
    ImGuiWindowFlags flags = ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                             ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoCollapse;

    ImGui::PushStyleColor(ImGuiCol_WindowBg, Theme::ColorBgInspector);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(12.0f * scale_, 14.0f * scale_));
    ImGui::Begin("##Inspector", nullptr, flags);

    // Top Tool Icons
    ImVec2 top_btn_sz(26.0f * scale_, 24.0f * scale_);
    ImGui::SetCursorPosX(width - 96.0f * scale_);
    if (IconButton("##Settings", Icons::drawSettings, top_btn_sz, "Device Settings", inspector_tab_ == 0)) {
        inspector_tab_ = 0;
    }

    ImGui::SameLine();
    if (IconButton("##Logcat", Icons::drawLogcat, top_btn_sz, "Agent Logcat", inspector_tab_ == 3)) {
        inspector_tab_ = 3;
    }

    ImGui::SameLine();
    if (IconButton("##Info", Icons::drawInfo, top_btn_sz, "Device Info", inspector_tab_ == 0)) {
        inspector_tab_ = 0;
    }

    ImGui::Spacing();

    // Segmented Pill Tabs: Info | Apps | Files
    const char* tabs[] = { "Info", "Apps", "Files" };
    float tab_w = (width - 24.0f * scale_) / 3.0f;

    ImDrawList* draw_list = ImGui::GetWindowDrawList();
    ImVec2 tab_bar_pos = ImGui::GetCursorScreenPos();
    draw_list->AddRectFilled(tab_bar_pos, ImVec2(tab_bar_pos.x + width - 24.0f * scale_, tab_bar_pos.y + 32.0f * scale_),
                             IM_COL32(230, 230, 235, 255), 16.0f * scale_);

    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 14.0f * scale_);
    for (int i = 0; i < 3; ++i) {
        bool active = (inspector_tab_ == i);
        if (active) {
            ImGui::PushStyleColor(ImGuiCol_Button, Theme::ColorAccent);
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1, 1, 1, 1));
        } else {
            ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0, 0, 0, 0));
            ImGui::PushStyleColor(ImGuiCol_Text, Theme::ColorTextPrimary);
        }

        if (i > 0) ImGui::SameLine(12.0f * scale_ + i * tab_w, 0);
        else ImGui::SetCursorPosX(12.0f * scale_);

        if (font_medium_) ImGui::PushFont(font_medium_);
        if (ImGui::Button(tabs[i], ImVec2(tab_w - 2.0f, 30.0f * scale_))) {
            inspector_tab_ = i;
        }
        if (font_medium_) ImGui::PopFont();

        ImGui::PopStyleColor(2);
    }
    ImGui::PopStyleVar();

    ImGui::Spacing();
    ImGui::Separator();
    ImGui::Spacing();

    std::string current_serial = (selected_device_idx_ >= 0 && selected_device_idx_ < static_cast<int>(devices_.size()))
                                 ? devices_[selected_device_idx_].serial : "";

    // TAB 0: INFO
    if (inspector_tab_ == 0) {
        if (current_serial.empty()) {
            ImGui::TextColored(Theme::ColorTextSecondary, "No device selected");
        } else {
            ImGui::TextColored(Theme::ColorTextSecondary, "Device Properties");
            ImGui::Spacing();
            auto row = [](const char* label, const std::string& value) {
                ImGui::TextColored(Theme::ColorTextSecondary, "%s:", label);
                ImGui::SameLine(120.0f);
                ImGui::TextColored(Theme::ColorTextPrimary, "%s", value.c_str());
            };

            row("Model", adb_.getProp(current_serial, "ro.product.model"));
            row("Manufacturer", adb_.getProp(current_serial, "ro.product.manufacturer"));
            row("Android", adb_.getProp(current_serial, "ro.build.version.release"));
            row("SDK API", adb_.getProp(current_serial, "ro.build.version.sdk"));
            row("CPU ABI", adb_.getProp(current_serial, "ro.product.cpu.abi"));
            row("Serial", current_serial);

            std::string bat_str = (battery_level_ >= 0) ? (std::to_string(battery_level_) + "%") : "Charging";
            row("Battery", bat_str);
        }
    }
    // TAB 1: APPS (Exact layout as macOS screenshot!)
    else if (inspector_tab_ == 1) {
        if (current_serial.empty()) {
            ImGui::TextColored(Theme::ColorTextSecondary, "No device selected");
        } else {
            // Scrollable Packages List
            float list_h = height - 170.0f;
            ImGui::BeginChild("##AppList", ImVec2(width - 24.0f, list_h), false);

            std::string q = app_filter_;
            std::transform(q.begin(), q.end(), q.begin(), ::tolower);

            int matched_count = 0;
            for (size_t i = 0; i < packages_.size(); ++i) {
                const auto& pkg = packages_[i];
                std::string lower_pkg = pkg;
                std::transform(lower_pkg.begin(), lower_pkg.end(), lower_pkg.begin(), ::tolower);
                if (!q.empty() && lower_pkg.find(q) == std::string::npos) continue;

                matched_count++;
                // Derive human readable name (e.g. com.google.android.apps.bard -> Bard / Gemini)
                std::string short_name = pkg;
                size_t last_dot = pkg.rfind('.');
                if (last_dot != std::string::npos && last_dot + 1 < pkg.size()) {
                    short_name = pkg.substr(last_dot + 1);
                    if (!short_name.empty()) short_name[0] = std::toupper(short_name[0]);
                }

                // App item row: squircle icon badge + App name + (com.package.name)
                ImGui::PushID(static_cast<int>(i));
                ImVec2 row_pos = ImGui::GetCursorScreenPos();
                float row_w = width - 24.0f * scale_;
                float row_h = 30.0f * scale_;

                std::string selectable_id = "##app_row_" + std::to_string(i);
                if (ImGui::Selectable(selectable_id.c_str(), false, ImGuiSelectableFlags_AllowDoubleClick, ImVec2(row_w, row_h))) {
                    if (ImGui::IsMouseDoubleClicked(ImGuiMouseButton_Left)) {
                        // Launch app via monkey
                        adb_.shell(current_serial, "monkey -p " + pkg + " -c android.intent.category.LAUNCHER 1");
                        showToast("Launched " + short_name);
                    }
                }

                // Draw App Icon Badge (squircle tile with letter/color)
                float badge_size = 22.0f * scale_;
                Icons::drawAppBadge(draw_list, ImVec2(row_pos.x + 2.0f * scale_, row_pos.y + (row_h - badge_size) * 0.5f),
                                   badge_size, short_name, pkg, font_bold_);

                // Draw App Title & Package Name with Font Hierarchy
                float font_bold_size = 15.5f * scale_;
                float font_cap_size = 12.5f * scale_;
                float title_w = 0.0f;
                if (font_bold_) {
                    draw_list->AddText(font_bold_, font_bold_size, ImVec2(row_pos.x + 30.0f * scale_, row_pos.y + 3.5f * scale_),
                                       IM_COL32(28, 28, 30, 255), short_name.c_str());
                    title_w = font_bold_->CalcTextSizeA(font_bold_size, FLT_MAX, 0.0f, short_name.c_str()).x;
                } else {
                    draw_list->AddText(ImVec2(row_pos.x + 30.0f * scale_, row_pos.y + 3.5f * scale_),
                                       IM_COL32(28, 28, 30, 255), short_name.c_str());
                    title_w = ImGui::CalcTextSize(short_name.c_str()).x;
                }

                std::string pkg_paren = " (" + pkg + ")";
                if (font_caption_) {
                    draw_list->AddText(font_caption_, font_cap_size, ImVec2(row_pos.x + 30.0f * scale_ + title_w + 6.0f * scale_, row_pos.y + 5.5f * scale_),
                                       IM_COL32(142, 142, 147, 255), pkg_paren.c_str());
                } else {
                    draw_list->AddText(ImVec2(row_pos.x + 30.0f * scale_ + title_w + 6.0f * scale_, row_pos.y + 5.5f * scale_),
                                       IM_COL32(142, 142, 147, 255), pkg_paren.c_str());
                }

                // Context Menu with Icons
                if (ImGui::BeginPopupContextItem()) {
                    if (MenuItemWithIcon("Launch App", nullptr, Icons::drawScreen, scale_)) {
                        adb_.shell(current_serial, "monkey -p " + pkg + " -c android.intent.category.LAUNCHER 1");
                        showToast("Launched " + short_name);
                    }
                    if (MenuItemWithIcon("Force Stop", nullptr, Icons::drawDisconnect, scale_)) {
                        adb_.shell(current_serial, "am force-stop " + pkg);
                        showToast("Stopped " + short_name);
                    }
                    if (MenuItemWithIcon("Uninstall", nullptr, Icons::drawDisconnect, scale_)) {
                        adb_.shell(current_serial, "pm uninstall " + pkg);
                        refreshPackages(current_serial);
                    }
                    ImGui::EndPopup();
                }

                ImGui::PopID();
            }

            ImGui::EndChild();

            // Bottom Apps Controls
            ImGui::SetCursorPosY(height - 80.0f * scale_);
            std::ostringstream pkg_cnt;
            pkg_cnt << matched_count << " packages";
            if (font_caption_) ImGui::PushFont(font_caption_);
            ImGui::TextColored(Theme::ColorTextSecondary, "%s", pkg_cnt.str().c_str());
            if (font_caption_) ImGui::PopFont();

            if (ImGui::Checkbox("System apps", &show_system_apps_)) {
                refreshPackages(current_serial);
            }
            ImGui::SameLine(width - 135.0f * scale_);
            if (ImGui::Button("Install APK...", ImVec2(110.0f * scale_, 24.0f * scale_))) {
                showToast("Drop APK file or use terminal");
            }

            // Bottom filter bar with Search Icon
            ImVec2 filter_pos = ImGui::GetCursorScreenPos();
            ImGui::PushItemWidth(width - 24.0f * scale_);
            ImGui::InputTextWithHint("##AppFilter", "      Filter", app_filter_, sizeof(app_filter_));
            ImGui::PopItemWidth();
            Icons::drawSearch(draw_list, ImVec2(filter_pos.x + 8.0f * scale_, filter_pos.y + 7.0f * scale_), 15.0f * scale_, IM_COL32(140, 140, 145, 255));
        }
    }
    // TAB 2: FILES
    else if (inspector_tab_ == 2) {
        if (current_serial.empty()) {
            ImGui::TextColored(Theme::ColorTextSecondary, "No device selected");
        } else {
            ImGui::TextColored(Theme::ColorTextSecondary, "%s", current_remote_path_.c_str());
            ImGui::SameLine(width - 55.0f * scale_);
            if (IconButton("##RefFiles", Icons::drawRefresh, ImVec2(26.0f * scale_, 24.0f * scale_), "Refresh directory")) {
                refreshFiles(current_serial);
            }

            float list_h = height - 160.0f * scale_;
            ImGui::BeginChild("##FileList", ImVec2(width - 24.0f * scale_, list_h), false);
            for (size_t i = 0; i < remote_files_.size(); ++i) {
                const auto& file = remote_files_[i];
                ImGui::PushID(static_cast<int>(i));
                ImVec2 row_pos = ImGui::GetCursorScreenPos();
                float row_h = 26.0f * scale_;

                ImGui::Selectable(("##file_" + std::to_string(i)).c_str(), false, 0, ImVec2(width - 24.0f * scale_, row_h));

                bool is_apk = (file.rfind(".apk") != std::string::npos);
                bool is_img = (file.rfind(".png") != std::string::npos || file.rfind(".jpg") != std::string::npos);
                bool is_dir = (file.find('.') == std::string::npos);

                float icon_sz = 18.0f * scale_;
                if (is_apk) {
                    draw_list->AddRectFilled(ImVec2(row_pos.x + 2.0f * scale_, row_pos.y + 2.0f * scale_),
                                            ImVec2(row_pos.x + 2.0f * scale_ + icon_sz, row_pos.y + 2.0f * scale_ + icon_sz),
                                            IM_COL32(52, 199, 89, 255), 4.0f * scale_);
                    draw_list->AddText(ImVec2(row_pos.x + 5.0f * scale_, row_pos.y + 2.0f * scale_),
                                      IM_COL32(255, 255, 255, 255), "A");
                } else if (is_dir) {
                    Icons::drawFolder(draw_list, ImVec2(row_pos.x + 2.0f * scale_, row_pos.y + 2.0f * scale_), icon_sz, IM_COL32(0, 122, 255, 255));
                } else if (is_img) {
                    Icons::drawCamera(draw_list, ImVec2(row_pos.x + 2.0f * scale_, row_pos.y + 2.0f * scale_), icon_sz, IM_COL32(175, 82, 222, 255));
                } else {
                    Icons::drawFile(draw_list, ImVec2(row_pos.x + 2.0f * scale_, row_pos.y + 2.0f * scale_), icon_sz, IM_COL32(140, 140, 145, 255));
                }

                draw_list->AddText(ImVec2(row_pos.x + 28.0f * scale_, row_pos.y + 4.0f * scale_),
                                   IM_COL32(30, 30, 34, 255), file.c_str());

                ImGui::PopID();
            }
            ImGui::EndChild();

            if (ImGui::Button("Refresh Files", ImVec2(width - 24.0f * scale_, 26.0f * scale_))) {
                refreshFiles(current_serial);
            }
        }
    }
    // TAB 3: LOGCAT
    else if (inspector_tab_ == 3) {
        ImGui::TextColored(Theme::ColorTextSecondary, "Session Logs");
        float list_h = height - 100.0f;
        ImGui::BeginChild("##LogList", ImVec2(width - 24.0f, list_h), true);
        if (session_) {
            auto logs = session_->getLogs();
            for (const auto& l : logs) {
                ImGui::TextUnformatted(l.c_str());
            }
        } else {
            ImGui::TextColored(Theme::ColorTextSecondary, "No active session");
        }
        ImGui::EndChild();
    }

    ImGui::End();
    ImGui::PopStyleVar();
    ImGui::PopStyleColor();
}

} // namespace rplayhub
