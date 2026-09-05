#include "gui_app.h"
#include "theme.h"
#include "icons.h"
#include "protocol/control_messages.h"
#include "util/png_decode.h"

#include "imgui.h"
#include "backends/imgui_impl_sdl2.h"
#include "backends/imgui_impl_sdlrenderer2.h"
#include "imgui_internal.h"   // ImTextCharFromUtf8

#include <iostream>
#include <sstream>
#include <iomanip>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <csignal>
#include <ctime>
#include <sys/stat.h>
#include <atomic>
#include <unistd.h>
#include <sys/wait.h>

namespace {
std::atomic<bool> g_quit_requested{false};
void onQuitSignal(int) { g_quit_requested.store(true); }
} // namespace

namespace rplayhub {

GuiApp::GuiApp(bool auto_mirror, float scale)
    : auto_mirror_(auto_mirror), scale_(scale) {}

GuiApp::~GuiApp() {
    cleanup();
}

bool GuiApp::init() {
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_TIMER | SDL_INIT_GAMECONTROLLER) != 0) {
        std::cerr << "Error: SDL_Init: " << SDL_GetError() << "\n";
        return false;
    }
    // Ctrl-C in the terminal or a SIGTERM ends the run loop cleanly (session torn down,
    // adb reverse removed) instead of leaving the agent running on the phone.
    std::signal(SIGINT, onQuitSignal);
    std::signal(SIGTERM, onQuitSignal);

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
    {
        SDL_RendererInfo info;
        if (SDL_GetRendererInfo(renderer_, &info) == 0) {
            std::cerr << "SDL renderer: " << info.name
                      << ((info.flags & SDL_RENDERER_ACCELERATED) ? " (accelerated)" : " (SOFTWARE - expect high CPU)")
                      << ", video driver " << SDL_GetCurrentVideoDriver() << "\n";
        }
    }

    // Setup ImGui context
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;

    buildFonts();

    // Setup Dear ImGui style scaled
    Theme::applyMacStyle(scale_);

    // Setup Platform/Renderer backends
    ImGui_ImplSDL2_InitForSDLRenderer(window_, renderer_);
    ImGui_ImplSDLRenderer2_Init(renderer_);

    last_device_poll_ = std::chrono::steady_clock::now();
    auto_mirror_deadline_ = last_device_poll_ + std::chrono::seconds(20);
    pollDevices();
    pollEmulators();

    return true;
}

// Load the Inter font family (plus a CJK face and any extra codepoints the device's labels
// needed) into a fresh atlas. Called at start and again whenever a label shows a glyph the
// atlas lacks: ImGui 1.91 bakes its atlas up front, so covering every script the device may use
// means rebuilding it with exactly the codepoints seen, between frames.
void GuiApp::buildFonts() {
    ImGuiIO& io = ImGui::GetIO();
    io.Fonts->Clear();
    font_regular_ = font_medium_ = font_bold_ = font_title_ = font_caption_ = nullptr;

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

    // Latin plus General Punctuation (the em dash / bullet in status text), plus every codepoint
    // a label has asked for since the last build.
    static ImVector<ImWchar> base_ranges;
    base_ranges.clear();
    {
        ImFontGlyphRangesBuilder b;
        static const ImWchar latin[] = { 0x0020, 0x00FF, 0x2000, 0x206F, 0 };
        b.AddRanges(latin);
        for (ImWchar c : extra_codepoints_) b.AddChar(c);
        b.BuildRanges(&base_ranges);
    }
    const ImWchar* glyph_ranges = base_ranges.Data;

    // App labels come in the device's languages: merge a CJK face (common Simplified Chinese,
    // Hiragana, Katakana, Hangul syllables) into the label fonts when the system has one.
    std::string cjk_path;
    int cjk_face = 0;
    for (const auto& [path, face] : std::vector<std::pair<std::string, int>>{
             {"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", 2},   // JP, KR, SC, TC
             {"/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf", 0},
             {"/usr/share/fonts/truetype/wqy/wqy-microhei.ttc", 0}}) {
        if (::access(path.c_str(), R_OK) == 0) { cjk_path = path; cjk_face = face; break; }
    }
    static ImVector<ImWchar> cjk_ranges;
    cjk_ranges.clear();
    if (!cjk_path.empty()) {
        ImFontGlyphRangesBuilder b;
        b.AddRanges(io.Fonts->GetGlyphRangesChineseSimplifiedCommon());
        static const ImWchar extra[] = { 0x3040, 0x30FF, 0xAC00, 0xD7A3, 0 };   // kana, Hangul
        b.AddRanges(extra);
        for (ImWchar c : extra_codepoints_) b.AddChar(c);
        b.BuildRanges(&cjk_ranges);
    }
    auto merge_cjk = [&](float px) {
        if (cjk_path.empty()) return;
        ImFontConfig cfg;
        cfg.MergeMode = true;
        cfg.FontNo = cjk_face;
        cfg.OversampleH = 1;   // keeps the atlas within reach of small GPUs
        io.Fonts->AddFontFromFileTTF(cjk_path.c_str(), px, &cfg, cjk_ranges.Data);
    };

    if (!regular_path.empty()) {
        font_regular_ = io.Fonts->AddFontFromFileTTF(regular_path.c_str(), base_reg, nullptr, glyph_ranges);
        merge_cjk(base_reg);
        font_caption_ = io.Fonts->AddFontFromFileTTF(regular_path.c_str(), base_cap, nullptr, glyph_ranges);
        merge_cjk(base_cap);
        if (!medium_path.empty()) {
            font_medium_ = io.Fonts->AddFontFromFileTTF(medium_path.c_str(), base_med, nullptr, glyph_ranges);
            merge_cjk(base_med);
        } else {
            font_medium_ = font_regular_;
        }
        if (!bold_path.empty()) {
            font_bold_ = io.Fonts->AddFontFromFileTTF(bold_path.c_str(), base_bold, nullptr, glyph_ranges);
            merge_cjk(base_bold);
            font_title_ = io.Fonts->AddFontFromFileTTF(bold_path.c_str(), base_title, nullptr, glyph_ranges);
        } else {
            font_bold_ = font_regular_;
            font_title_ = font_regular_;
        }
    } else {
        io.Fonts->AddFontDefault();
    }

    fonts_dirty_ = false;
}

void GuiApp::cleanup() {
    stopMirroring();
    display_windows_.clear();
    jobs_.shutdown();
    stopMirroring();

    if (video_texture_) {
        SDL_DestroyTexture(video_texture_);
        video_texture_ = nullptr;
    }
    if (back_texture_) { SDL_DestroyTexture(back_texture_); back_texture_ = nullptr; }
    for (auto& [key, tex] : app_icons_) {
        if (tex) SDL_DestroyTexture(tex);
    }
    app_icons_.clear();

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
    if (devices_poll_inflight_) return;
    devices_poll_inflight_ = true;
    struct Result { bool ok = false; std::vector<AdbDevice> list; };
    jobs_.run<Result>(
        [this] { Result r; r.ok = adb_.getDevices(r.list); return r; },
        [this](Result r) {
            devices_poll_inflight_ = false;
            if (r.ok) applyDeviceList(r.list);
        });
}

void GuiApp::applyDeviceList(const std::vector<AdbDevice>& list) {
    devices_ = list;
    for (const auto& d : devices_) ensureGlyphs(d.displayName());

    // Re-find the selection by serial: adb reorders the list as devices come and go.
    selected_device_idx_ = -1;
    for (int i = 0; i < static_cast<int>(devices_.size()); ++i) {
        if (devices_[i].serial == selected_serial_) selected_device_idx_ = i;
    }
    if (selected_device_idx_ < 0) {
        selected_serial_.clear();
        if (!devices_.empty()) selectDevice(0);
    }

    if (auto_mirror_) {
        int idx = -1;
        for (int i = 0; i < static_cast<int>(devices_.size()); ++i) {
            if (preferred_serial_.empty() ? devices_[i].isReady()
                                          : devices_[i].serial == preferred_serial_) {
                idx = i;
                break;
            }
        }
        if (idx >= 0 && devices_[idx].isReady()) {
            auto_mirror_ = false;
            selectDevice(idx);
            startMirroring(idx);
        } else if (std::chrono::steady_clock::now() > auto_mirror_deadline_) {
            auto_mirror_ = false;
            std::cerr << "--mirror: no " << (preferred_serial_.empty() ? "ready device" : "device " + preferred_serial_)
                      << " in `adb devices`\n";
        }
    }
}

void GuiApp::selectDevice(int idx) {
    if (idx < 0 || idx >= static_cast<int>(devices_.size())) return;
    selected_device_idx_ = idx;
    const std::string serial = devices_[idx].serial;
    bool changed = (serial != selected_serial_);
    selected_serial_ = serial;
    if (changed) {
        loadDeviceInfo(serial);
        refreshPackages(serial);
        refreshFiles(serial);
    }
}

void GuiApp::loadDeviceInfo(const std::string& serial) {
    DeviceInfo& info = device_info_[serial];
    if (info.loading) return;
    info.loading = true;
    jobs_.run<DeviceInfo>(
        [this, serial] {
            DeviceInfo r;
            // One `getprop` for everything: "[ro.product.model]: [Pixel 9a]" per line.
            std::istringstream stream(adb_.shell(serial, "getprop"));
            std::string line;
            while (std::getline(stream, line)) {
                size_t k0 = line.find('['), k1 = line.find("]: [");
                if (k0 == std::string::npos || k1 == std::string::npos) continue;
                size_t v1 = line.rfind(']');
                if (v1 == std::string::npos || v1 <= k1 + 3) continue;
                r.props[line.substr(k0 + 1, k1 - k0 - 1)] = line.substr(k1 + 4, v1 - k1 - 4);
            }
            r.battery = adb_.getBatteryLevel(serial);
            r.loaded = !r.props.empty();
            return r;
        },
        [this, serial](DeviceInfo r) {
            r.loading = false;
            device_info_[serial] = std::move(r);
        });
}

const GuiApp::DeviceInfo* GuiApp::infoFor(const std::string& serial) const {
    auto it = device_info_.find(serial);
    return (it != device_info_.end() && it->second.loaded) ? &it->second : nullptr;
}

void GuiApp::refreshPackages(const std::string& serial) {
    int gen = ++packages_gen_;
    packages_loading_ = true;
    bool third_party_only = !show_system_apps_;
    jobs_.run<std::vector<std::string>>(
        [this, serial, third_party_only] { return adb_.getPackages(serial, third_party_only); },
        [this, serial, gen](std::vector<std::string> pkgs) {
            if (gen != packages_gen_) return;      // a newer request superseded this one
            packages_loading_ = false;
            if (serial != selected_serial_) return;
            apps_.clear();
            for (const auto& id : pkgs) {
                AppRow row;
                row.id = id;
                auto it = app_icons_.find(serial + "|" + id);
                if (it != app_icons_.end()) row.icon = it->second;
                apps_.push_back(std::move(row));
            }
            fetchAppLabels(serial, std::move(pkgs), gen);
        });
}

// Labels and icons arrive a beat after the list: one AppLabel round trip on a worker,
// PNGs decoded there, textures created here.
void GuiApp::fetchAppLabels(const std::string& serial, std::vector<std::string> ids, int gen) {
    if (ids.empty()) return;
    app_labels_loading_ = true;
    jobs_.run<std::vector<AppEntry>>(
        [this, serial, ids] { return AppCatalog::fetch(adb_, serial, ids); },
        [this, serial, gen](std::vector<AppEntry> entries) {
            app_labels_loading_ = false;
            if (gen != packages_gen_ || serial != selected_serial_) return;
            std::map<std::string, const AppEntry*> by_id;
            for (const auto& e : entries) by_id[e.id] = &e;
            for (auto& row : apps_) {
                auto it = by_id.find(row.id);
                if (it == by_id.end()) continue;
                const AppEntry& e = *it->second;
                row.label = e.label;
                ensureGlyphs(row.label);
                if (!row.icon && e.icon.valid()) {
                    SDL_Texture* tex = SDL_CreateTexture(renderer_, SDL_PIXELFORMAT_RGBA32,
                                                         SDL_TEXTUREACCESS_STATIC, e.icon.width, e.icon.height);
                    if (tex) {
                        SDL_UpdateTexture(tex, nullptr, e.icon.rgba.data(), e.icon.width * 4);
                        SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND);
                        SDL_SetTextureScaleMode(tex, SDL_ScaleModeLinear);
                        app_icons_[serial + "|" + row.id] = tex;
                        row.icon = tex;
                    }
                }
            }
        });
}

void GuiApp::runShellAsync(const std::string& serial, const std::string& command, const std::string& toast) {
    jobs_.run([this, serial, command] { adb_.shell(serial, command); },
              [this, toast] { if (!toast.empty()) showToast(toast); });
}

std::string GuiApp::downloadsDir() {
    const char* home = std::getenv("HOME");
    std::string dir = std::string(home ? home : ".") + "/Downloads";
    if (::access(dir.c_str(), W_OK) != 0) dir = home ? home : ".";
    return dir;
}

void GuiApp::installApk(const std::string& serial, const std::string& local_path) {
    std::string name = local_path.substr(local_path.rfind('/') + 1);
    apps_status_ = "Installing " + name + "...";
    showToast(apps_status_, 30);
    struct Result { bool ok = false; std::string err; };
    jobs_.run<Result>(
        [this, serial, local_path] { Result r; r.ok = adb_.installApk(serial, local_path, r.err); return r; },
        [this, serial, name](Result r) {
            apps_status_.clear();
            if (r.ok) {
                showToast("Installed " + name);
                if (serial == selected_serial_) refreshPackages(serial);
            } else {
                showToast("Install failed: " + r.err, 8);
                std::cerr << "install " << name << ": " << r.err << "\n";
            }
        });
}

// No file dialog in ImGui: use the desktop's (zenity on GNOME, kdialog on KDE), on a worker so
// the UI keeps running. Without either, dropping an APK on the window still works.
void GuiApp::pickAndInstallApk(const std::string& serial) {
    jobs_.run<std::string>(
        [] {
            const char* cmds[] = {
                "zenity --file-selection --title='Install APK' --file-filter='APK | *.apk' 2>/dev/null",
                "kdialog --getopenfilename . '*.apk' 2>/dev/null",
            };
            for (const char* cmd : cmds) {
                FILE* fp = popen(cmd, "r");
                if (!fp) continue;
                char buf[4096] = {0};
                std::string out;
                while (fgets(buf, sizeof(buf), fp)) out += buf;
                int rc = pclose(fp);
                if (rc == 0) {
                    while (!out.empty() && (out.back() == '\n' || out.back() == '\r')) out.pop_back();
                    return out;
                }
                if (WIFEXITED(rc) && WEXITSTATUS(rc) == 1) return std::string();   // cancelled
            }
            return std::string("!nodialog");
        },
        [this, serial](std::string path) {
            if (path == "!nodialog") showToast("No file dialog available: drop an .apk onto the window", 6);
            else if (!path.empty()) installApk(serial, path);
        });
}

void GuiApp::exportApk(const std::string& serial, const std::string& package) {
    std::string dest = downloadsDir() + "/" + package + ".apk";
    showToast("Exporting " + package + "...", 30);
    struct Result { bool ok = false; std::string err; };
    jobs_.run<Result>(
        [this, serial, package, dest] {
            Result r;
            std::string paths = adb_.shell(serial, "pm path " + package);
            std::string base;
            std::istringstream stream(paths);
            std::string line;
            while (std::getline(stream, line)) {
                if (line.rfind("package:", 0) == 0) { base = line.substr(8); break; }
            }
            while (!base.empty() && (base.back() == '\r' || base.back() == '\n')) base.pop_back();
            if (base.empty()) { r.err = "pm path returned nothing"; return r; }
            r.ok = adb_.pullFile(serial, base, dest, &r.err);
            return r;
        },
        [this, dest](Result r) {
            if (r.ok) showToast("Saved " + dest, 6);
            else showToast("Export failed: " + r.err, 8);
        });
}

// A file dropped on the window: an APK installs, anything else is pushed to the Files tab's folder.
void GuiApp::handleDroppedFile(const std::string& path) {
    if (selected_serial_.empty()) {
        showToast("Select a device first");
        return;
    }
    std::string name = path.substr(path.rfind('/') + 1);
    std::string lower = name;
    std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
    if (lower.size() > 4 && lower.compare(lower.size() - 4, 4, ".apk") == 0) {
        installApk(selected_serial_, path);
        return;
    }
    std::string serial = selected_serial_;
    std::string remote = current_remote_path_ + "/" + name;
    showToast("Sending " + name + "...", 30);
    jobs_.run<bool>(
        [this, serial, path, remote] { return adb_.pushFile(serial, path, remote, 0644); },
        [this, serial, name, remote](bool ok) {
            showToast(ok ? "Sent " + name + " to " + remote : "Send failed: " + name, 6);
            if (ok && serial == selected_serial_) refreshFiles(serial);
        });
}

void GuiApp::refreshFiles(const std::string& serial) {
    int gen = ++files_gen_;
    files_loading_ = true;
    std::string path = current_remote_path_;
    struct Result { bool ok = false; std::vector<DirEntry> entries; };
    jobs_.run<Result>(
        [this, serial, path] { Result r; r.ok = adb_.listDirectory(serial, path, r.entries); return r; },
        [this, serial, gen](Result r) {
            if (gen != files_gen_) return;
            files_loading_ = false;
            if (serial != selected_serial_) return;
            files_error_ = !r.ok;
            remote_entries_ = std::move(r.entries);
            for (const auto& e : remote_entries_) ensureGlyphs(e.name);
        });
}

void GuiApp::navigateTo(const std::string& serial, const std::string& path) {
    std::string p = path.empty() ? "/" : path;
    while (p.size() > 1 && p.back() == '/') p.pop_back();
    current_remote_path_ = p;
    remote_entries_.clear();
    refreshFiles(serial);
}

void GuiApp::pullToDownloads(const std::string& serial, const std::string& remote_path) {
    std::string name = remote_path.substr(remote_path.rfind('/') + 1);
    std::string dest = downloadsDir() + "/" + name;
    showToast("Pulling " + name + "...", 30);
    struct Result { bool ok = false; std::string err; };
    jobs_.run<Result>(
        [this, serial, remote_path, dest] { Result r; r.ok = adb_.pullFile(serial, remote_path, dest, &r.err); return r; },
        [this, dest, name](Result r) {
            showToast(r.ok ? "Saved to " + dest : "Pull failed: " + name + " (" + r.err + ")", 6);
        });
}

void GuiApp::startMirroring(int device_idx) {
    if (device_idx < 0 || device_idx >= static_cast<int>(devices_.size())) return;
    const auto& dev = devices_[device_idx];
    if (!dev.isReady()) {
        showToast("Device is not ready: " + dev.state);
        return;
    }

    if (session_active_ && session_ && session_->getSerial() == dev.serial &&
        session_->getState() != SessionState::STOPPED && session_->getState() != SessionState::FAILED) {
        showToast("Already mirroring " + dev.displayName());
        return;
    }

    stopMirroring();

    session_serial_ = dev.serial;
    user_stopped_ = false;
    reconnect_attempts_ = 0;
    reconnect_pending_ = false;
    session_ = std::make_unique<AgentSession>(dev.serial);
    session_->start(session_options_);
    session_started_ = std::chrono::steady_clock::now();
    session_active_ = true;
    clipboard_started_ = false;
    startup_requests_sent_ = false;
    showToast("Connecting to " + dev.displayName() + "...");
}

void GuiApp::stopMirroring() {
    user_stopped_ = true;
    reconnect_pending_ = false;
    closeDisplayWindows();
    if (session_) {
        session_->stop();
        session_.reset();
    }
    session_active_ = false;
    live_frame_ = DecodedFrame();
    texture_dirty_ = false;
}

// Bring the same device back after the stream died; the last frame stays on screen meanwhile.
void GuiApp::restartSession() {
    closeDisplayWindows();   // virtual displays die with the previous agent
    if (session_) session_->stop();
    session_ = std::make_unique<AgentSession>(session_serial_);
    session_->start(session_options_);
    session_started_ = std::chrono::steady_clock::now();
    session_active_ = true;
    clipboard_started_ = false;
}

std::string GuiApp::mediaDir(const char* subdir) {
    const char* home = std::getenv("HOME");
    std::string base = home ? home : ".";
    std::string dir = base + "/" + subdir;
    if (::access(dir.c_str(), W_OK) == 0) return dir;
    if (::mkdir(dir.c_str(), 0755) == 0) return dir;
    return base;
}

std::string GuiApp::timestampName(const std::string& model, const char* ext) {
    std::time_t t = std::time(nullptr);
    char stamp[32];
    std::strftime(stamp, sizeof(stamp), "%Y-%m-%d_%H-%M-%S", std::localtime(&t));
    std::string name = model.empty() ? "Android" : model;
    for (char& c : name) if (c == ' ' || c == '/') c = '_';
    return "rPlayHub_" + name + "_" + stamp + ext;
}

// The device's own screenshot (screencap over exec-out) to ~/Pictures.
void GuiApp::takeScreenshot() {
    if (selected_serial_.empty()) {
        showToast("Select a device first");
        return;
    }
    std::string serial = selected_serial_;
    std::string model = (selected_device_idx_ >= 0) ? devices_[selected_device_idx_].model : "";
    std::string dest = mediaDir("Pictures") + "/" + timestampName(model, ".png");
    struct Result { bool ok = false; std::string err; };
    jobs_.run<Result>(
        [this, serial, dest] {
            Result r;
            std::vector<uint8_t> png;
            if (!adb_.execOut(serial, "screencap -p", png) || png.size() < 8 || png[1] != 'P') {
                r.err = "screencap failed";
                return r;
            }
            FILE* fp = fopen(dest.c_str(), "wb");
            if (!fp) { r.err = "cannot write " + dest; return r; }
            r.ok = fwrite(png.data(), 1, png.size(), fp) == png.size();
            fclose(fp);
            return r;
        },
        [this, dest](Result r) {
            showToast(r.ok ? "Screenshot saved to " + dest : "Screenshot failed: " + r.err, 6);
        });
}

// Ask for the next quadrant explicitly. -1 would hand control back to the device's own
// sensor, which is a different command (Follow Device Rotation in the Device menu).
void GuiApp::rotateDevice() {
    if (!session_ || session_->getState() != SessionState::RUNNING) return;
    int next = (live_frame_.displayOrientation + 1) % 4;
    session_->setOrientation(next);
}

// Host-side recording of the mirror stream to ~/Videos, started and stopped from the same button.
void GuiApp::toggleRecording() {
    if (!session_ || session_->getState() != SessionState::RUNNING) {
        showToast("Start mirroring first");
        return;
    }
    StreamRecorder& rec = session_->getRecorder();
    if (rec.isRecording()) {
        std::string path = rec.path();
        bool kept = rec.stop();
        showToast(kept ? "Recording saved to " + path : "Recording discarded: no frames arrived", 6);
        return;
    }
    std::string model = (selected_device_idx_ >= 0) ? devices_[selected_device_idx_].model : "";
    std::string dest = mediaDir("Videos") + "/" + timestampName(model, ".mp4");
    int w = live_frame_.width, h = live_frame_.height;
    if (!rec.start(dest, session_->getCodecName(), w, h)) {
        showToast("Recording failed: " + rec.error(), 8);
        return;
    }
    recording_started_ = std::chrono::steady_clock::now();
    session_->requestKeyframe();
    showToast("Recording to " + dest, 4);
}

// Device-side notifications, drained on the UI thread once per frame.
void GuiApp::pumpAgentEvents() {
    if (!session_) return;
    for (const auto& ev : session_->takeEvents()) {
        switch (ev.kind) {
        case AgentSession::AgentEvent::CLIPBOARD_CHANGED:
            if (clipboard_sync_ && !ev.text.empty() && ev.text != last_clipboard_text_) {
                last_clipboard_text_ = ev.text;
                ensureGlyphs(ev.text.substr(0, 200));
                SDL_SetClipboardText(ev.text.c_str());
                std::cerr << "clipboard: " << ev.text.size() << " chars from the device\n";
                showToast("Clipboard: " + std::to_string(ev.text.size()) + " chars from the device", 2);
            }
            break;
        case AgentSession::AgentEvent::ERROR_RESPONSE:
            showToast("Agent: " + ev.text, 6);
            break;
        case AgentSession::AgentEvent::NEW_DISPLAY_STREAM:
            // A display we asked for announces itself by its first packet; requests are
            // answered in the order they were made.
            if (!pending_displays_.empty()) {
                PendingDisplay req = pending_displays_.front();
                pending_displays_.pop_front();
                openDisplayWindow(ev.display, req);
            } else {
                std::cerr << "display " << ev.display.id << " started streaming without a request; ignoring\n";
            }
            break;
        case AgentSession::AgentEvent::DISPLAY_REMOVED:
            for (auto it = display_windows_.begin(); it != display_windows_.end(); ++it) {
                if ((*it)->displayId() == ev.display.id) {
                    session_->forgetDisplay(ev.display.id);
                    display_windows_.erase(it);
                    break;
                }
            }
            break;
        default:
            break;
        }
    }
}

void GuiApp::pollHostClipboard() {
    if (!session_ || session_->getState() != SessionState::RUNNING) {
        clipboard_started_ = false;
        return;
    }
    if (!clipboard_sync_) return;
    auto now = std::chrono::steady_clock::now();
    if (clipboard_started_ && now - last_clipboard_poll_ < std::chrono::seconds(1)) return;
    last_clipboard_poll_ = now;

    std::string text;
    if (SDL_HasClipboardText()) {
        char* t = SDL_GetClipboardText();
        if (t) { text = t; SDL_free(t); }
    }
    if (!clipboard_started_) {
        // First message of the session: sets the device clipboard and subscribes to its changes.
        clipboard_started_ = true;
        last_clipboard_text_ = text;
        session_->syncClipboard(text);
        return;
    }
    if (text.empty() || text == last_clipboard_text_) return;
    last_clipboard_text_ = text;
    session_->syncClipboard(text);
    std::cerr << "clipboard: " << text.size() << " chars to the device\n";
}

void GuiApp::setClipboardSync(bool on) {
    clipboard_sync_ = on;
    if (!on && session_) {
        session_->stopClipboardSync();
        clipboard_started_ = false;
    }
}

// Any text the device hands us (labels, file names) may use a script the atlas lacks. Note
// the missing codepoints; the atlas is rebuilt with them before the next frame.
void GuiApp::ensureGlyphs(const std::string& utf8) {
    if (!font_regular_) return;
    const char* p = utf8.c_str();
    const char* end = p + utf8.size();
    while (p < end) {
        unsigned int c = 0;
        int n = ImTextCharFromUtf8(&c, p, end);
        if (n <= 0) break;
        p += n;
        if (c < 0x80 || c == 0xFFFD) continue;
        if (font_regular_->FindGlyphNoFallback(static_cast<ImWchar>(c))) continue;
        if (extra_codepoints_.insert(static_cast<ImWchar>(c)).second) fonts_dirty_ = true;
    }
}

// ---- menu bar: the Mac client's Device / View / Window menus ----

void GuiApp::renderMenuBar() {
    menu_h_ = 0.0f;
    if (!ImGui::BeginMainMenuBar()) return;
    menu_h_ = ImGui::GetFrameHeight();

    const bool have_device = selected_device_idx_ >= 0 && selected_device_idx_ < static_cast<int>(devices_.size());
    const bool live = session_ && session_->getState() == SessionState::RUNNING;
    const bool mirroring_selected = have_device && session_active_ && session_ && session_serial_ == devices_[selected_device_idx_].serial;

    if (ImGui::BeginMenu("Device")) {
        if (mirroring_selected) {
            if (ImGui::MenuItem("Stop Screen Mirroring")) stopMirroring();
        } else if (ImGui::MenuItem("Start Screen Mirroring", nullptr, false, have_device)) {
            startMirroring(selected_device_idx_);
        }
        if (ImGui::MenuItem("Reconnect", nullptr, false, have_device)) startMirroring(selected_device_idx_);
        ImGui::Separator();
        if (ImGui::MenuItem("Desktop Mode", "Ctrl+D", false, live)) openDesktopMode();
        if (ImGui::MenuItem("Open Front App on Virtual Display", nullptr, false, live)) openFrontAppOnVirtualDisplay();
        ImGui::Separator();
        if (ImGui::MenuItem("Take Screenshot", nullptr, false, have_device)) takeScreenshot();
        bool recording = session_ && session_->getRecorder().isRecording();
        if (ImGui::MenuItem(recording ? "Stop Recording" : "Record Screen", nullptr, false, live)) toggleRecording();
        ImGui::Separator();
        if (ImGui::MenuItem("Back", nullptr, false, live)) session_->sendKey(AndroidKey::BACK);
        if (ImGui::MenuItem("Home", nullptr, false, live)) session_->sendKey(AndroidKey::HOME);
        if (ImGui::MenuItem("Recents", nullptr, false, live)) session_->sendKey(AndroidKey::APP_SWITCH);
        if (ImGui::MenuItem("Rotate", nullptr, false, live)) rotateDevice();
        if (ImGui::MenuItem("Follow Device Rotation", nullptr, false, live)) session_->setOrientation(-1);
        if (ImGui::MenuItem("Wake", nullptr, false, live)) session_->wakeOrPower(false);
        if (ImGui::MenuItem("Power Button", nullptr, false, live)) session_->wakeOrPower(true);
        ImGui::Separator();
        bool paused = live && session_->isDisplayPaused();
        if (ImGui::MenuItem(paused ? "Resume Display" : "Pause Display", nullptr, false, live)) session_->setDisplayPaused(!paused);
        if (ImGui::MenuItem("Turn Screen Off While Mirroring", nullptr, session_options_.turn_screen_off)) {
            session_options_.turn_screen_off = !session_options_.turn_screen_off;
            if (live) showToast("Applies when mirroring is restarted (Reconnect)", 5);
        }
        bool audio_on = live ? session_->isAudioForwarding() : session_options_.audio;
        if (ImGui::MenuItem("Forward Audio", nullptr, audio_on)) {
            session_options_.audio = !audio_on;
            if (live) session_->setAudioForwarding(session_options_.audio);
        }
        if (ImGui::MenuItem("Synchronize Clipboard", nullptr, clipboard_sync_)) setClipboardSync(!clipboard_sync_);
        ImGui::Separator();
        if (ImGui::MenuItem("Connect to Device over Network...")) show_connect_popup_ = true;
        if (ImGui::MenuItem("Refresh Devices")) { pollDevices(); pollEmulators(); }
        ImGui::Separator();
        if (ImGui::MenuItem("Quit", "Ctrl+Q")) g_quit_requested.store(true);
        ImGui::EndMenu();
    }

    if (ImGui::BeginMenu("View")) {
        if (ImGui::MenuItem("View Screen in 3D", nullptr, twin_mode_, true)) {
            twin_mode_ = !twin_mode_;
            if (twin_mode_ && live && !session_->hasSensorChannel()) {
                showToast("This agent offers no orientation channel; the twin will not turn", 6);
            }
        }
        if (ImGui::MenuItem("Set Facing Me", "R", false, twin_mode_)) twin_.recenter();
        ImGui::Separator();
        const char* tabs[] = { "Info", "Apps", "Files", "Logcat" };
        for (int t = 0; t < 4; ++t) {
            if (ImGui::MenuItem(tabs[t], nullptr, inspector_tab_ == t)) inspector_tab_ = t;
        }
        ImGui::EndMenu();
    }

    if (ImGui::BeginMenu("Window")) {
        if (ImGui::MenuItem("Open Screen in New Window", nullptr, false, live)) openPhoneWindow();
        if (ImGui::MenuItem("Pin Window on Top", nullptr, display_windows_.empty() ? main_pinned_ : display_windows_.back()->pinned())) togglePinOnTop();
        if (ImGui::MenuItem("Close Virtual Displays", nullptr, false, !display_windows_.empty())) closeDisplayWindows();
        ImGui::EndMenu();
    }

    if (ImGui::BeginMenu("Help")) {
        if (ImGui::MenuItem("About rPlayHub Android")) {
            showToast("rPlayHub Android for Linux: SDL2 + FFmpeg + Dear ImGui. github.com/rPlayAI/rplayhub-android", 8);
        }
        ImGui::EndMenu();
    }

    // Keyboard shortcuts for the menu
    ImGuiIO& io = ImGui::GetIO();
    if (io.KeyCtrl && ImGui::IsKeyPressed(ImGuiKey_D) && live) openDesktopMode();

    ImGui::EndMainMenuBar();
}

// ---- emulators ----

void GuiApp::pollEmulators() {
    if (avd_poll_inflight_) return;
    avd_poll_inflight_ = true;
    // Serials adb lists that we have not yet matched to an AVD: ask their consoles.
    std::vector<std::string> unknown;
    for (const auto& d : devices_) {
        if (d.isEmulator() && !emulator_names_.count(d.serial)) unknown.push_back(d.serial);
    }
    struct Result { std::vector<Avd> avds; std::map<std::string, std::string> running, names; };
    jobs_.run<Result>(
        [unknown] {
            Result r;
            r.avds = EmulatorLauncher::list();
            r.running = EmulatorLauncher::running();
            for (const auto& serial : unknown) r.names[serial] = EmulatorLauncher::avdNameOf(serial);
            return r;
        },
        [this](Result r) {
            avd_poll_inflight_ = false;
            avds_ = std::move(r.avds);
            for (auto& [serial, name] : r.names) if (!name.empty()) emulator_names_[serial] = name;
            avds_running_ = std::move(r.running);
            for (const auto& d : devices_) {
                auto it = emulator_names_.find(d.serial);
                if (it != emulator_names_.end()) avds_running_[it->second] = d.serial;
            }
            for (auto it = emulator_names_.begin(); it != emulator_names_.end();) {
                bool listed = false;
                for (const auto& d : devices_) if (d.serial == it->first) listed = true;
                it = listed ? std::next(it) : emulator_names_.erase(it);   // gone: forget it
            }
            for (auto it = avd_starting_.begin(); it != avd_starting_.end();) {
                it = avds_running_.count(*it) ? avd_starting_.erase(it) : std::next(it);
            }
        });
}

void GuiApp::startEmulator(const Avd& avd) {
    if (avds_running_.count(avd.name) || avd_starting_.count(avd.name)) {
        showToast(avd.display_name + " is already running");
        return;
    }
    avd_starting_.insert(avd.name);
    showToast("Starting " + avd.display_name + "... (a cold boot can take a minute or more)", 8);
    struct Result { std::string serial, err; };
    jobs_.run<Result>(
        [avd] { Result r; r.serial = EmulatorLauncher::launch(avd, &r.err); return r; },
        [this, avd](Result r) {
            if (r.serial.empty()) {
                avd_starting_.erase(avd.name);
                showToast("Could not start " + avd.display_name + ": " + r.err, 8);
            }
        });
}

void GuiApp::shutdownEmulator(const std::string& serial) {
    if (session_ && session_serial_ == serial) stopMirroring();
    jobs_.run<std::string>(
        [serial] { std::string err; EmulatorLauncher::shutdown(serial, &err); return err; },
        [this, serial](std::string err) {
            showToast(err.empty() ? "Shutting down " + serial : "Shutdown failed: " + err, 6);
            pollDevices();
            pollEmulators();
        });
}

// The sidebar's EMULATORS section: one row per AVD, running ones mirror like any device.
void GuiApp::renderEmulatorRows(float width) {
    if (avds_.empty()) return;
    ImGui::Spacing();
    if (font_caption_) ImGui::PushFont(font_caption_);
    ImGui::TextColored(Theme::ColorTextSecondary, "EMULATORS");
    if (font_caption_) ImGui::PopFont();
    ImGui::Spacing();
    ImDrawList* draw_list = ImGui::GetWindowDrawList();

    for (size_t i = 0; i < avds_.size(); ++i) {
        const Avd& avd = avds_[i];
        auto run_it = avds_running_.find(avd.name);
        std::string serial = run_it != avds_running_.end() ? run_it->second : "";
        int dev_idx = -1;
        for (int d = 0; d < static_cast<int>(devices_.size()); ++d) {
            if (!serial.empty() && devices_[d].serial == serial) dev_idx = d;
        }
        bool booting = avd_starting_.count(avd.name) || (!serial.empty() && dev_idx < 0);
        bool ready = dev_idx >= 0 && devices_[dev_idx].isReady();
        bool is_selected = (selected_avd_ == avd.name) || (ready && selected_device_idx_ == dev_idx);
        bool is_mirroring = ready && session_active_ && session_ && session_->getSerial() == serial;

        ImGui::PushID(static_cast<int>(1000 + i));
        ImVec2 card_pos = ImGui::GetCursorScreenPos();
        float card_w = width - 24.0f * scale_;
        float card_h = 50.0f * scale_;
        ImU32 bg_color = is_selected ? IM_COL32(232, 242, 255, 255) : IM_COL32(255, 255, 255, 255);
        ImU32 border_color = is_selected ? IM_COL32(0, 122, 255, 180) : IM_COL32(225, 225, 230, 200);
        draw_list->AddRectFilled(card_pos, ImVec2(card_pos.x + card_w, card_pos.y + card_h), bg_color, 8.0f * scale_);
        draw_list->AddRect(card_pos, ImVec2(card_pos.x + card_w, card_pos.y + card_h), border_color, 8.0f * scale_);

        ImU32 dot = ready ? IM_COL32(52, 199, 89, 255) : booting ? IM_COL32(255, 204, 0, 255) : IM_COL32(180, 180, 185, 255);
        draw_list->AddCircleFilled(ImVec2(card_pos.x + 14.0f * scale_, card_pos.y + card_h * 0.5f), 4.5f * scale_, dot);
        Icons::drawScreen(draw_list, ImVec2(card_pos.x + 26.0f * scale_, card_pos.y + 15.0f * scale_), 20.0f * scale_, IM_COL32(120, 120, 128, 255));

        std::string title = avd.display_name;
        std::string sub = booting ? "starting..." : ready ? serial : "stopped";
        if (!avd.api_level.empty()) sub += (sub.empty() ? "" : " · API ") + avd.api_level;
        if (!avd.abi.empty()) sub += " · " + avd.abi;
        if (font_medium_) ImGui::PushFont(font_medium_);
        draw_list->AddText(ImVec2(card_pos.x + 52.0f * scale_, card_pos.y + 8.0f * scale_), IM_COL32(28, 28, 30, 255), title.c_str());
        if (font_medium_) ImGui::PopFont();
        if (font_caption_) {
            draw_list->AddText(font_caption_, 12.0f * scale_, ImVec2(card_pos.x + 52.0f * scale_, card_pos.y + 28.0f * scale_),
                               IM_COL32(142, 142, 147, 255), sub.c_str());
        }

        ImGui::SetCursorScreenPos(card_pos);
        if (ImGui::InvisibleButton("##AvdBtn", ImVec2(card_w, card_h))) {
            selected_avd_ = avd.name;
            if (ready) selectDevice(dev_idx);
        }
        if (ImGui::IsItemHovered() && ImGui::IsMouseDoubleClicked(ImGuiMouseButton_Left)) {
            if (ready) { selectDevice(dev_idx); startMirroring(dev_idx); }
            else if (!booting) startEmulator(avd);
        }
        if (ImGui::BeginPopupContextItem("AvdContextMenu")) {
            selected_avd_ = avd.name;
            if (ready) {
                if (is_mirroring) {
                    if (MenuItemWithIcon("Stop Screen Mirroring", nullptr, Icons::drawScreen, scale_)) stopMirroring();
                } else if (MenuItemWithIcon("Start Screen Mirroring", nullptr, Icons::drawScreen, scale_)) {
                    selectDevice(dev_idx);
                    startMirroring(dev_idx);
                }
                ImGui::Separator();
            }
            if (!serial.empty() || booting) {
                if (MenuItemWithIcon("Shut Down Emulator", nullptr, Icons::drawPower, scale_)) {
                    if (!serial.empty()) shutdownEmulator(serial);
                }
            } else if (MenuItemWithIcon("Start", nullptr, Icons::drawPower, scale_)) {
                startEmulator(avd);
            }
            if (MenuItemWithIcon("Copy Serial", nullptr, Icons::drawCopy, scale_) && !serial.empty()) {
                ImGui::SetClipboardText(serial.c_str());
                showToast("Copied " + serial);
            }
            ImGui::EndPopup();
        }
        ImGui::SetCursorScreenPos(ImVec2(card_pos.x, card_pos.y + card_h + 8.0f * scale_));
        ImGui::PopID();
    }
}

// ---- virtual displays and the bare phone window ----

void GuiApp::openDesktopMode() {
    if (!session_ || session_->getState() != SessionState::RUNNING) {
        showToast("Start mirroring first");
        return;
    }
    for (auto& dw : display_windows_) {
        if (dw->decorated()) { SDL_RaiseWindow(SDL_GetWindowFromID(dw->windowId())); return; }   // one desktop is enough
    }
    session_->wakeOrPower(false);
    runShellAsync(session_serial_, "wm dismiss-keyguard", "");
    pending_displays_.push_back({"", true});
    session_->requestNewDisplay(1920, 1080, 240, true);
    showToast("Opening Android's desktop on a virtual display...", 4);
}

void GuiApp::openAppOnVirtualDisplay(const std::string& package) {
    if (!session_ || session_->getState() != SessionState::RUNNING) {
        showToast("Start mirroring first");
        return;
    }
    session_->wakeOrPower(false);
    pending_displays_.push_back({package, false});
    // Same display the Mac client asks for; ROTATES_WITH_CONTENT lets a portrait app turn it.
    session_->requestNewDisplay(1920, 1080, 240, false);
    showToast("Opening " + package + " on a virtual display...", 4);
}

void GuiApp::openFrontAppOnVirtualDisplay() {
    if (!session_ || session_->getState() != SessionState::RUNNING) {
        showToast("Start mirroring first");
        return;
    }
    std::string serial = session_serial_;
    jobs_.run<std::string>(
        [this, serial] { return adb_.frontPackage(serial); },
        [this, serial](std::string pkg) {
            if (pkg.empty() || pkg.find("launcher") != std::string::npos) {
                showToast("Open an app on the phone first, or use Desktop Mode for the whole desktop", 6);
                return;
            }
            if (serial == session_serial_) openAppOnVirtualDisplay(pkg);
        });
}

// The phone's own screen in a bare window: same frames as the stage, its own texture.
void GuiApp::openPhoneWindow() {
    if (session_ && live_frame_.empty() && session_->getDecoder().getLatestFrame(live_frame_)) {
        texture_dirty_ = true;   // asked before the stage pulled its first frame
    }
    if (!session_ || live_frame_.empty()) {
        showToast("Start mirroring first");
        return;
    }
    for (auto& dw : display_windows_) {
        if (dw->displayId() == 0) { SDL_RaiseWindow(SDL_GetWindowFromID(dw->windowId())); return; }
    }
    AgentSession::DisplayDescriptor d;
    d.id = 0;
    d.width = live_frame_.displayWidth;
    d.height = live_frame_.displayHeight;
    d.rotation = live_frame_.displayOrientation;
    openDisplayWindow(d, {"", false});
}

void GuiApp::togglePinOnTop() {
    // The newest pop-out window if there is one, else the main window.
    if (!display_windows_.empty()) {
        DisplayWindow& dw = *display_windows_.back();
        dw.setPinned(!dw.pinned());
        showToast(dw.pinned() ? "Window pinned on top" : "Window unpinned");
        return;
    }
    main_pinned_ = !main_pinned_;
    SDL_SetWindowAlwaysOnTop(window_, main_pinned_ ? SDL_TRUE : SDL_FALSE);
    showToast(main_pinned_ ? "Window pinned on top" : "Window unpinned");
}

void GuiApp::openDisplayWindow(const AgentSession::DisplayDescriptor& d, const PendingDisplay& req) {
    std::string device = (selected_device_idx_ >= 0) ? devices_[selected_device_idx_].displayName() : "Android";
    std::string title = req.decorated ? device + " Desktop"
                      : req.package.empty() ? device
                      : req.package.substr(req.package.rfind('.') + 1);
    if (!req.package.empty()) {
        for (const auto& row : apps_) if (row.id == req.package && !row.label.empty()) title = row.label;
    }

    // Size: fit the display's aspect into three quarters of the screen.
    SDL_DisplayMode dm{};
    SDL_GetCurrentDisplayMode(0, &dm);
    int dw_ = (d.rotation % 2 == 1) ? d.height : d.width;
    int dh_ = (d.rotation % 2 == 1) ? d.width : d.height;
    if (dw_ <= 0 || dh_ <= 0) { dw_ = 1080; dh_ = 2400; }
    float aspect = static_cast<float>(dw_) / dh_;
    int win_h = static_cast<int>((dm.h > 0 ? dm.h : 1080) * 0.75f);
    int win_w = static_cast<int>(win_h * aspect);
    int max_w = static_cast<int>((dm.w > 0 ? dm.w : 1920) * 0.75f);
    if (win_w > max_w) { win_w = max_w; win_h = static_cast<int>(win_w / aspect); }

    auto win = std::make_unique<DisplayWindow>(d.id, title, win_w, win_h, req.decorated);
    if (!win->valid()) {
        showToast("Could not open a window for display " + std::to_string(d.id), 6);
        if (d.id != 0) session_->destroyDisplay(d.id);
        return;
    }
    // Each new window steps down and right from the last, so they do not stack exactly.
    int step = (display_windows_opened_++ % 6) * 32;
    int wx, wy;
    SDL_GetWindowPosition(SDL_GetWindowFromID(win->windowId()), &wx, &wy);
    SDL_SetWindowPosition(SDL_GetWindowFromID(win->windowId()), wx + step, wy + step);
    win->setPackage(req.package);
    display_windows_.push_back(std::move(win));

    if (d.id != 0) {
        std::string serial = session_serial_;
        std::string pkg = req.package;
        int32_t id = d.id;
        jobs_.run<std::string>(
            [this, serial, pkg, id] {
                // The display mirrors the phone's keyguard when the phone sits locked; dismiss it.
                adb_.shell(serial, "wm dismiss-keyguard");
                std::string err;
                if (!pkg.empty() && !adb_.launchPackage(serial, pkg, id, &err)) return err;
                return std::string();
            },
            [this](std::string err) { if (!err.empty()) showToast("Launch failed: " + err, 8); });
        std::cerr << (req.package.empty() ? "desktop mode" : req.package) << " on display " << d.id
                  << " (" << d.width << "x" << d.height << ")\n";
    }
}

void GuiApp::closeDisplayWindows() {
    for (auto& dw : display_windows_) {
        if (session_ && dw->displayId() != 0) session_->destroyDisplay(dw->displayId());
    }
    display_windows_.clear();
    display_frames_.clear();
    pending_displays_.clear();
}

bool GuiApp::routeEventToDisplayWindows(const SDL_Event& e) {
    AgentSession* s = (session_ && session_->getState() == SessionState::RUNNING) ? session_.get() : nullptr;
    for (auto& dw : display_windows_) {
        if (dw->handleEvent(e, s)) return true;
    }
    return false;
}

void GuiApp::renderDisplayWindows() {
    if (display_windows_.empty()) return;
    bool any_focus = false;
    for (auto it = display_windows_.begin(); it != display_windows_.end();) {
        DisplayWindow& dw = **it;
        if (dw.closeRequested()) {
            // Closing the window closes the display; nothing is left running on the phone.
            if (session_ && dw.displayId() != 0) session_->destroyDisplay(dw.displayId());
            display_frames_.erase(dw.displayId());
            it = display_windows_.erase(it);
            continue;
        }
        if (dw.hasFocus()) any_focus = true;
        if (dw.displayId() == 0) {
            dw.render(live_frame_);
        } else {
            // One frame per window, pulled only when its decoder has a new one.
            DecodedFrame& mine = display_frames_[dw.displayId()];
            if (VideoDecoder* dec = session_ ? session_->decoderFor(dw.displayId()) : nullptr) {
                dec->getLatestFrame(mine, /*only_if_new=*/true);
            }
            dw.render(mine);
        }
        ++it;
    }
    // ImGui stops SDL text input whenever no ImGui field wants it; a focused display window needs it.
    if (any_focus && !SDL_IsTextInputActive()) SDL_StartTextInput();
}

// Called every frame. A session that ended on its own (USB unplugged, agent killed, adb
// restarted) is restarted with backoff once the device is listed as ready again; a session the
// user stopped stays stopped.
void GuiApp::maintainSession() {
    if (!session_ || user_stopped_) return;
    const auto now = std::chrono::steady_clock::now();
    const SessionState st = session_->getState();

    if (st == SessionState::RUNNING) {
        if (reconnect_attempts_ > 0 && now - session_started_ > std::chrono::seconds(10)) {
            reconnect_attempts_ = 0;   // stable again; forget the backoff
        }
        reconnect_pending_ = false;
        if (!startup_requests_sent_ && session_->getDecoder().hasFrame()) {
            startup_requests_sent_ = true;
            if (startup_desktop_) openDesktopMode();
            if (!startup_app_.empty()) openAppOnVirtualDisplay(startup_app_);
            if (startup_pop_out_) openPhoneWindow();
            if (startup_twin_) twin_mode_ = true;
        }
        return;
    }
    if (st != SessionState::STOPPED && st != SessionState::FAILED) return;

    if (!reconnect_pending_) {
        // A failure during bring-up (agent missing, adb refused) will not fix itself; a stream
        // that ended usually will. Bound both.
        const int max_attempts = (st == SessionState::FAILED) ? 4 : 30;
        if (reconnect_attempts_ >= max_attempts) {
            showToast(session_->getStatusMessage() + " (gave up reconnecting)", 6);
            std::cerr << "session: " << session_->getStatusMessage() << "; giving up after "
                      << reconnect_attempts_ << " attempts\n";
            user_stopped_ = true;
            session_active_ = false;
            return;
        }
        int delay_s = std::min(2 << std::min(reconnect_attempts_, 3), 15);
        reconnect_attempts_++;
        reconnect_pending_ = true;
        reconnect_at_ = now + std::chrono::seconds(delay_s);
        showToast(session_->getStatusMessage() + " - reconnecting in " + std::to_string(delay_s) + " s", delay_s);
        std::cerr << "session: " << session_->getStatusMessage() << "; reconnect " << reconnect_attempts_
                  << " in " << delay_s << " s\n";
        return;
    }
    if (now < reconnect_at_) return;

    bool ready = false;
    for (const auto& d : devices_) {
        if (d.serial == session_serial_ && d.isReady()) ready = true;
    }
    if (!ready) {
        reconnect_at_ = now + std::chrono::seconds(2);   // keep waiting for the device
        return;
    }
    reconnect_pending_ = false;
    restartSession();
}

void GuiApp::run() {
    bool done = false;

    while (!done) {
        const auto frame_start = std::chrono::steady_clock::now();
        jobs_.pump();
        if (g_quit_requested.load()) done = true;
        if (fonts_dirty_) {
            // Outside NewFrame/Render: rebuild the atlas with the codepoints labels asked for.
            buildFonts();
            ImGui_ImplSDLRenderer2_DestroyFontsTexture();
            ImGui_ImplSDLRenderer2_CreateFontsTexture();
        }

        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if ((event.type == SDL_MOUSEBUTTONDOWN || event.type == SDL_MOUSEBUTTONUP) && std::getenv("RPLAYHUB_INPUT_DEBUG")) {
                std::cerr << "sdl: button " << (event.type == SDL_MOUSEBUTTONDOWN ? "down" : "up") << " window "
                          << event.button.windowID << " (main " << SDL_GetWindowID(window_) << ") at "
                          << event.button.x << "," << event.button.y << "\n";
            }
            if (routeEventToDisplayWindows(event)) continue;
            ImGui_ImplSDL2_ProcessEvent(&event);
            if (event.type == SDL_QUIT) {
                done = true;
            }
            if (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_CLOSE
                && event.window.windowID == SDL_GetWindowID(window_)) {
                done = true;
            }
            if (event.type == SDL_DROPFILE && event.drop.file) {
                std::string path = event.drop.file;
                SDL_free(event.drop.file);
                handleDroppedFile(path);
            }
        }

        // Periodic ADB poll (off the UI thread)
        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::seconds>(now - last_device_poll_).count() >= 3) {
            pollDevices();
            pollEmulators();
            last_device_poll_ = now;
        }
        maintainSession();
        pumpAgentEvents();
        pollHostClipboard();

        // Start the Dear ImGui frame
        ImGui_ImplSDLRenderer2_NewFrame();
        ImGui_ImplSDL2_NewFrame();
        ImGui::NewFrame();

        int win_w, win_h;
        SDL_GetWindowSize(window_, &win_w, &win_h);

        if (ImGui::GetIO().KeyCtrl && ImGui::IsKeyPressed(ImGuiKey_Q)) done = true;

        // Scaled sizes matching macOS GUI
        float sidebar_w = 260.0f * scale_;
        float inspector_w = 320.0f * scale_;
        float stage_w = static_cast<float>(win_w) - sidebar_w - inspector_w;
        if (stage_w < 360.0f * scale_) stage_w = 360.0f * scale_;
        float main_h = static_cast<float>(win_h);

        // Menu bar, then the three panels below it
        renderMenuBar();
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
        if (!dump_frame_path_.empty() && mirror_settled && dump_settled_at_.time_since_epoch().count() == 0) {
            dump_settled_at_ = std::chrono::steady_clock::now();
        }
        if (!dump_frame_path_.empty() && frame_count_ >= 30 && mirror_settled &&
            std::chrono::steady_clock::now() - dump_settled_at_ > std::chrono::seconds(std::getenv("RPLAYHUB_DUMP_DELAY") ? std::atoi(std::getenv("RPLAYHUB_DUMP_DELAY")) : 4)) {
            SDL_Surface* sshot = SDL_CreateRGBSurfaceWithFormat(0, win_w, win_h, 32, SDL_PIXELFORMAT_ARGB8888);
            if (sshot) {
                if (SDL_RenderReadPixels(renderer_, NULL, SDL_PIXELFORMAT_ARGB8888, sshot->pixels, sshot->pitch) == 0) {
                    SDL_SaveBMP(sshot, dump_frame_path_.c_str());
                    std::cout << "Dumped frame to " << dump_frame_path_ << "\n";
                }
                SDL_FreeSurface(sshot);
            }
            for (auto& dw : display_windows_) {
                std::string path = dump_frame_path_ + ".display" + std::to_string(dw->displayId()) + ".bmp";
                if (dw->saveScreenshotBmp(path)) std::cout << "Dumped display window to " << path << "\n";
            }
            dump_frame_path_.clear();
        }

        SDL_RenderPresent(renderer_);
        renderDisplayWindows();

        // Without vsync (software renderer, hidden window) the loop would spin; cap it.
        {
            auto elapsed = std::chrono::steady_clock::now() - frame_start;
            auto floor_ms = (SDL_GetWindowFlags(window_) & SDL_WINDOW_MINIMIZED) ? 50 : 4;
            auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count();
            if (ms < floor_ms) SDL_Delay(static_cast<Uint32>(floor_ms - ms));
        }

        if (stats_) {
            auto t = std::chrono::steady_clock::now();
            double dt = std::chrono::duration<double>(t - stats_last_).count();
            if (dt >= 5.0) {
                uint64_t decoded = session_ ? session_->getDecoder().framesDecoded() : 0;
                if (decoded < stats_decoded_last_) stats_decoded_last_ = 0;   // decoder was recreated
                if (stats_last_.time_since_epoch().count() != 0) {
                    std::cerr << "stats: decoded " << std::fixed << std::setprecision(1)
                              << (decoded - stats_decoded_last_) / dt << " fps, rendered "
                              << (frame_count_ - stats_rendered_last_) / dt << " fps, texture "
                              << tex_w_ << "x" << tex_h_;
                    if (session_) std::cerr << ", gyro " << session_->orientationPackets() << " pkts";
                    if (session_ && session_->getAudioPlayer()) {
                        const AudioPlayer* ap = session_->getAudioPlayer();
                        std::cerr << ", audio " << ap->packetsReceived() << " pkts, peak "
                                  << std::setprecision(0) << ap->peakDb() << " dB, dropped " << ap->packetsDropped();
                    }
                    std::cerr << "\n";
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
    height -= menu_h_;
    ImGui::SetNextWindowPos(ImVec2(0, menu_h_));
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
        for (auto& [serial, info] : device_info_) info.loaded = false;   // re-read props too
        if (!selected_serial_.empty()) {
            loadDeviceInfo(selected_serial_);
            refreshPackages(selected_serial_);
            refreshFiles(selected_serial_);
        }
        showToast("Refreshing device list");
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
        if (connect_inflight_) ImGui::BeginDisabled();
        if (ImGui::Button(connect_inflight_ ? "Connecting..." : "Connect", ImVec2(100 * scale_, 0))) {
            connect_inflight_ = true;
            connect_status_msg_.clear();
            std::string address = connect_ip_buf_;
            struct Result { bool ok = false; std::string msg; };
            jobs_.run<Result>(
                [this, address] { Result r; r.ok = adb_.connectNetwork(address, r.msg); return r; },
                [this](Result r) {
                    connect_inflight_ = false;
                    if (r.ok) {
                        showToast("Connected: " + r.msg);
                        show_connect_popup_ = false;
                        pollDevices();
                    } else {
                        connect_status_msg_ = r.msg.empty() ? "Connection failed" : r.msg;
                    }
                });
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

    int listed_devices = 0;
    for (int i = 0; i < static_cast<int>(devices_.size()); ++i) {
        const auto& dev = devices_[i];
        if (dev.isEmulator() && !avds_.empty()) continue;   // shown under EMULATORS with its AVD
        listed_devices++;
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
            selectDevice(i);
        }

        // Double click to start mirroring
        if (ImGui::IsItemHovered() && ImGui::IsMouseDoubleClicked(ImGuiMouseButton_Left)) {
            startMirroring(i);
        }

        // Right-click Context Menu with Icons (Exact match with macOS screenshot!)
        if (ImGui::BeginPopupContextItem("DeviceContextMenu")) {
            selectDevice(i);
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
                if (!session_ || session_serial_ != dev.serial) startMirroring(i);
                startup_desktop_ = true;                 // fires once the mirror is up
                startup_requests_sent_ = false;
                if (session_ && session_serial_ == dev.serial && session_->getState() == SessionState::RUNNING) {
                    startup_desktop_ = false;
                    startup_requests_sent_ = true;
                    openDesktopMode();
                }
            }
            if (MenuItemWithIcon("Copy Serial", nullptr, Icons::drawCopy, scale_)) {
                ImGui::SetClipboardText(dev.serial.c_str());
                showToast("Copied serial: " + dev.serial);
            }
            if (MenuItemWithIcon("Disconnect", nullptr, Icons::drawDisconnect, scale_)) {
                std::string serial = dev.serial;
                if (session_ && session_serial_ == serial) stopMirroring();
                jobs_.run([this, serial] { adb_.disconnectNetwork(serial); },
                          [this] { pollDevices(); });
            }
            ImGui::Separator();
            {
                bool live = session_ && session_serial_ == dev.serial && session_->getState() == SessionState::RUNNING;
                bool paused = live && session_->isDisplayPaused();
                if (live && MenuItemWithIcon(paused ? "Resume Display" : "Pause Display", nullptr, Icons::drawScreen, scale_)) {
                    session_->setDisplayPaused(!paused);
                    showToast(paused ? "Display resumed" : "Display paused: no frames, no bandwidth");
                }
                if (ImGui::MenuItem("Synchronize Clipboard", nullptr, clipboard_sync_)) {
                    setClipboardSync(!clipboard_sync_);
                }
                if (ImGui::MenuItem("Turn Screen Off While Mirroring", nullptr, session_options_.turn_screen_off)) {
                    session_options_.turn_screen_off = !session_options_.turn_screen_off;
                    if (live) showToast("Applies when mirroring is restarted (Reconnect)", 5);
                }
            }
            {
                bool on = session_ && session_serial_ == dev.serial && session_->isAudioForwarding();
                bool live = session_ && session_serial_ == dev.serial && session_->getState() == SessionState::RUNNING;
                if (ImGui::MenuItem("Forward Audio", nullptr, on || (!live && session_options_.audio))) {
                    session_options_.audio = !(on || (!live && session_options_.audio));
                    if (live) {
                        if (!session_->hasAudioChannel()) showToast("No audio channel: the device is below Android 12");
                        session_->setAudioForwarding(session_options_.audio);
                    }
                }
            }
            ImGui::Separator();
            if (MenuItemWithIcon("Take Screenshot", nullptr, Icons::drawCamera, scale_)) {
                takeScreenshot();
            }
            bool recording = session_ && session_->getRecorder().isRecording();
            if (MenuItemWithIcon(recording ? "Stop Recording" : "Record Screen", nullptr, Icons::drawRecord, scale_)) {
                toggleRecording();
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
                rotateDevice();
            }
            ImGui::Separator();
            if (MenuItemWithIcon("Wake", nullptr, Icons::drawSun, scale_)) {
                if (session_) session_->wakeOrPower(false);
            }
            if (MenuItemWithIcon("Power Button", nullptr, Icons::drawPower, scale_)) {
                if (session_) session_->wakeOrPower(true);
            }
            ImGui::Separator();
            if (MenuItemWithIcon(twin_mode_ ? "View Flat" : "View in 3D", nullptr, Icons::drawCube, scale_)) {
                twin_mode_ = !twin_mode_;
                if (twin_mode_ && session_ && !session_->hasSensorChannel()) {
                    showToast("This agent offers no orientation channel; the twin will not turn", 6);
                }
            }
            ImGui::Separator();
            if (MenuItemWithIcon("Open Front App on Virtual Display", nullptr, Icons::drawWindow, scale_)) {
                openFrontAppOnVirtualDisplay();
            }
            if (MenuItemWithIcon("Open in New Window", nullptr, Icons::drawWindow, scale_)) {
                openPhoneWindow();
            }
            if (MenuItemWithIcon("Pin Window on Top", nullptr, Icons::drawPin, scale_)) {
                togglePinOnTop();
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

    if (listed_devices == 0) {
        ImGui::Spacing();
        ImGui::TextColored(Theme::ColorTextSecondary, "No devices found");
        ImGui::TextColored(Theme::ColorTextTertiary, "Plug in USB or + connect IP");
    }

    renderEmulatorRows(width);

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
    height -= menu_h_;
    ImGui::SetNextWindowPos(ImVec2(start_x, menu_h_));
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

    // Session status to the right of the pill: "Mirroring active", a failure, "reconnecting".
    if (session_ && font_caption_) {
        std::string status = session_->getStatusMessage();
        if (reconnect_pending_) status += " (reconnecting)";
        if (session_->isDisplayPaused()) status += " (paused)";
        SessionState st = session_->getState();
        ImU32 col = (st == SessionState::RUNNING) ? IM_COL32(52, 160, 90, 255)
                  : (st == SessionState::FAILED)  ? IM_COL32(200, 60, 60, 255)
                                                  : IM_COL32(120, 120, 128, 255);
        draw_list->AddText(font_caption_, 12.5f * scale_,
                           ImVec2(pill_pos.x + pill_w + 12.0f * scale_, pill_pos.y + 6.0f * scale_),
                           col, status.c_str());
    }

    // Phone & Stage Area
    float available_h = height - 90.0f * scale_;
    float available_w = width - 30.0f * scale_;

    // Pull a frame only when the decoder has a new one; the copy is a few MB.
    if (session_ && session_->getDecoder().getLatestFrame(live_frame_, /*only_if_new=*/true)) {
        texture_dirty_ = true;
    }
    bool has_frame = session_ && !live_frame_.empty();

    const float top = menu_h_ + 42.0f * scale_;
    if (session_active_ && has_frame && twin_mode_) {
        renderTwin(ImVec2(start_x + 15.0f * scale_, top), ImVec2(available_w, available_h), live_frame_);
    } else if (session_active_ && has_frame) {
        renderLiveMirror(ImVec2(start_x + 15.0f * scale_, top), ImVec2(available_w, available_h), live_frame_);
    } else {
        renderPhoneMockup(ImVec2(start_x + width * 0.5f, top + available_h * 0.44f), ImVec2(available_w, available_h));
    }

    // Bottom Navigation Control Strip
    renderControlStrip(ImVec2(start_x, menu_h_ + height - 52.0f * scale_), width);

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
// (Re)create the texture in the decoder's own layout and upload a new frame; SDL converts on the GPU.
void GuiApp::uploadLiveTexture(const DecodedFrame& frame) {
    if (frame.empty()) return;

    if (!video_texture_ || tex_w_ != frame.width || tex_h_ != frame.height || tex_format_ != frame.format) {
        if (video_texture_) SDL_DestroyTexture(video_texture_);
        Uint32 sdl_fmt = SDL_PIXELFORMAT_RGBA32;
        if (frame.format == FrameFormat::I420) sdl_fmt = SDL_PIXELFORMAT_IYUV;
        else if (frame.format == FrameFormat::NV12) sdl_fmt = SDL_PIXELFORMAT_NV12;
        video_texture_ = SDL_CreateTexture(renderer_, sdl_fmt, SDL_TEXTUREACCESS_STREAMING,
                                           frame.width, frame.height);
        if (!video_texture_) {
            std::cerr << "SDL_CreateTexture: " << SDL_GetError() << "\n";
            return;
        }
        tex_w_ = frame.width;
        tex_h_ = frame.height;
        tex_format_ = frame.format;
        texture_dirty_ = true;
    }

    if (texture_dirty_) {
        int rc = 0;
        switch (frame.format) {
        case FrameFormat::I420:
            rc = SDL_UpdateYUVTexture(video_texture_, nullptr,
                                      frame.planes[0].data(), frame.pitch[0],
                                      frame.planes[1].data(), frame.pitch[1],
                                      frame.planes[2].data(), frame.pitch[2]);
            break;
        case FrameFormat::NV12:
            rc = SDL_UpdateNVTexture(video_texture_, nullptr,
                                     frame.planes[0].data(), frame.pitch[0],
                                     frame.planes[1].data(), frame.pitch[1]);
            break;
        default:
            rc = SDL_UpdateTexture(video_texture_, nullptr, frame.planes[0].data(), frame.pitch[0]);
            break;
        }
        if (rc != 0) std::cerr << "SDL_Update*Texture: " << SDL_GetError() << "\n";
        texture_dirty_ = false;
        frames_shown_++;
    }
}

void GuiApp::renderLiveMirror(ImVec2 origin, ImVec2 size, const DecodedFrame& frame) {
    if (frame.empty()) return;
    uploadLiveTexture(frame);
    if (!video_texture_) return;

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

void GuiApp::loadBackTexture() {
    if (back_texture_tried_) return;
    back_texture_tried_ = true;
    std::string exe_dir;
    {
        char buf[4096];
        ssize_t n = ::readlink("/proc/self/exe", buf, sizeof(buf) - 1);
        if (n > 0) { buf[n] = '\0'; std::string e(buf); exe_dir = e.substr(0, e.rfind('/')); }
    }
    std::vector<std::string> candidates = {
        exe_dir + "/../../doc/pixel-backside-transparent.png", exe_dir + "/../doc/pixel-backside-transparent.png",
        exe_dir + "/../share/rplayhub-android/pixel-backside-transparent.png",
        "doc/pixel-backside-transparent.png", "../doc/pixel-backside-transparent.png",
    };
    for (const auto& path : candidates) {
        FILE* fp = fopen(path.c_str(), "rb");
        if (!fp) continue;
        std::vector<uint8_t> bytes;
        uint8_t buf[65536];
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) bytes.insert(bytes.end(), buf, buf + n);
        fclose(fp);
        RgbaImage img = decodePngToRgba(bytes.data(), bytes.size());
        if (!img.valid()) continue;
        removeLightBackground(img);
        back_texture_ = SDL_CreateTexture(renderer_, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STATIC, img.width, img.height);
        if (back_texture_) {
            SDL_UpdateTexture(back_texture_, nullptr, img.rgba.data(), img.width * 4);
            SDL_SetTextureScaleMode(back_texture_, SDL_ScaleModeLinear);
            SDL_SetTextureBlendMode(back_texture_, SDL_BLENDMODE_BLEND);
        }
        return;
    }
}

// The 3D twin in the stage: the phone turns as the real one turns; touches land through the
// rotated screen plane.
void GuiApp::renderTwin(ImVec2 origin, ImVec2 size, const DecodedFrame& frame) {
    uploadLiveTexture(frame);
    loadBackTexture();
    ImDrawList* draw_list = ImGui::GetWindowDrawList();

    // Backdrop
    draw_list->AddRectFilledMultiColor(origin, ImVec2(origin.x + size.x, origin.y + size.y),
                                       IM_COL32(58, 60, 70, 255), IM_COL32(58, 60, 70, 255),
                                       IM_COL32(22, 22, 28, 255), IM_COL32(22, 22, 28, 255));

    float q[4] = {0, 0, 0, 1};
    bool have = session_ && session_->latestOrientation(q);
    twin_.setOrientation({q[0], q[1], q[2], q[3]}, have);
    twin_.render(draw_list, origin, ImVec2(size.x, size.y - 44.0f * scale_), (ImTextureID)video_texture_,
                 (ImTextureID)back_texture_, frame.displayWidth, frame.displayHeight, frame.displayOrientation, scale_);

    // Touch through the plane
    ImVec2 mouse = ImGui::GetMousePos();
    bool over_stage = mouse.x >= origin.x && mouse.x <= origin.x + size.x && mouse.y >= origin.y && mouse.y <= origin.y + size.y - 44.0f * scale_;
    int dx, dy;
    if (session_ && over_stage && ImGui::IsMouseClicked(ImGuiMouseButton_Left) && twin_.hitTest(mouse, dx, dy)) {
        is_touch_active_ = true;
        session_->sendTouch(dx, dy, MotionAction::DOWN);
    } else if (session_ && is_touch_active_ && ImGui::IsMouseDragging(ImGuiMouseButton_Left, 0.5f)) {
        if (twin_.hitTest(mouse, dx, dy)) session_->sendTouch(dx, dy, MotionAction::MOVE);
    } else if (session_ && is_touch_active_ && ImGui::IsMouseReleased(ImGuiMouseButton_Left)) {
        is_touch_active_ = false;
        if (!twin_.hitTest(mouse, dx, dy)) { dx = last_touch_x_; dy = last_touch_y_; }
        session_->sendTouch(dx, dy, MotionAction::UP);
    }
    if (is_touch_active_ && twin_.hitTest(mouse, dx, dy)) { last_touch_x_ = dx; last_touch_y_ = dy; }
    if (session_ && over_stage && ImGui::IsMouseClicked(ImGuiMouseButton_Right)) session_->sendKey(AndroidKey::BACK);
    handleKeyboardInput();

    // Set Facing Me (R), and a hint until the reference is set
    ImVec2 btn_sz(190.0f * scale_, 30.0f * scale_);
    ImGui::SetCursorScreenPos(ImVec2(origin.x + (size.x - btn_sz.x) * 0.5f, origin.y + size.y - 38.0f * scale_));
    ImGui::PushStyleColor(ImGuiCol_Button, IM_COL32(38, 120, 242, 242));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, IM_COL32(58, 135, 250, 255));
    ImGui::PushStyleColor(ImGuiCol_Text, IM_COL32(255, 255, 255, 255));
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 9.0f * scale_);
    bool pressed = ImGui::Button(twin_.recentering() ? "Hold still..." : "Set Facing Me  (R)", btn_sz);
    ImGui::PopStyleVar();
    ImGui::PopStyleColor(3);
    if (pressed || (!ImGui::GetIO().WantTextInput && ImGui::IsKeyPressed(ImGuiKey_R))) twin_.recenter();

    const char* hint = nullptr;
    if (!session_ || !session_->hasSensorChannel()) hint = "No orientation channel from this agent";
    else if (!have) hint = "Waiting for the device's rotation sensor...";
    else if (!twin_.hasReference()) hint = "Hold the phone facing you and press Set Facing Me";
    if (hint && font_caption_) {
        ImVec2 ts = font_caption_->CalcTextSizeA(13.0f * scale_, FLT_MAX, 0.0f, hint);
        draw_list->AddText(font_caption_, 13.0f * scale_, ImVec2(origin.x + (size.x - ts.x) * 0.5f, origin.y + size.y - 62.0f * scale_),
                           IM_COL32(230, 230, 235, 220), hint);
    }
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

    // Mouse wheel = a scroll gesture at the pointer (vertical and horizontal)
    ImGuiIO& io = ImGui::GetIO();
    if (inside && (std::abs(io.MouseWheel) > 0.01f || std::abs(io.MouseWheelH) > 0.01f)) {
        auto [dx, dy] = map_coords(mouse_pos);
        session_->sendScroll(dx, dy, io.MouseWheelH, io.MouseWheel);
    }
}

void GuiApp::handleKeyboardInput() {
    if (!session_) return;
    ImGuiIO& io = ImGui::GetIO();
    // Typing into the search / filter boxes must not also type on the phone.
    if (io.WantTextInput) return;

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
        { "##Rotate", Icons::drawRotate, "Rotate Screen", [this]() { rotateDevice(); } },
        { "##Camera", Icons::drawCamera, "Take Screenshot", [this]() { takeScreenshot(); } },
        { "##Record", Icons::drawRecord, "Record Screen", [this]() { toggleRecording(); } }
    };
    bool recording = session_ && session_->getRecorder().isRecording();

    float btn_w = 38.0f * scale_;
    float btn_h = 34.0f * scale_;
    float spacing = 44.0f * scale_; // Matches ~44pt spacing from macOS screenshot
    float total_w = (buttons.size() - 1) * spacing + btn_w;
    float start_x = pos.x + (width - total_w) * 0.5f;

    for (size_t i = 0; i < buttons.size(); ++i) {
        ImGui::SetCursorScreenPos(ImVec2(start_x + i * spacing, pos.y + 8.0f * scale_));
        bool is_record = (i == buttons.size() - 1);
        if (is_record && recording) {
            // Red dot while recording, with the elapsed time and whether frames are flowing yet.
            ImVec2 c(start_x + i * spacing + btn_w * 0.5f, pos.y + 8.0f * scale_ + btn_h * 0.5f);
            draw_list->AddCircleFilled(c, 6.0f * scale_, IM_COL32(255, 59, 48, 255));
            if (FlatNavButton(buttons[i].id, [](ImDrawList*, ImVec2, float, ImU32) {}, ImVec2(btn_w, btn_h), "Stop Recording", scale_)) {
                buttons[i].action();
            }
            StreamRecorder& rec = session_->getRecorder();
            int secs = static_cast<int>(rec.seconds());
            char label[48];
            if (rec.hasStarted()) snprintf(label, sizeof(label), "REC %d:%02d", secs / 60, secs % 60);
            else snprintf(label, sizeof(label), "REC waiting for keyframe");
            if (font_caption_) {
                draw_list->AddText(font_caption_, 12.0f * scale_, ImVec2(c.x + 14.0f * scale_, c.y - 7.0f * scale_),
                                   IM_COL32(255, 59, 48, 255), label);
            }
            continue;
        }
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
    height -= menu_h_;
    ImGui::SetNextWindowPos(ImVec2(start_x, menu_h_));
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
            auto row = [this](const char* label, const std::string& value) {
                ImGui::TextColored(Theme::ColorTextSecondary, "%s:", label);
                ImGui::SameLine(110.0f * scale_);
                ImGui::TextColored(Theme::ColorTextPrimary, "%s", value.c_str());
            };

            const DeviceInfo* info = infoFor(current_serial);
            auto prop = [&](const char* key) -> std::string {
                if (!info) return "...";
                auto it = info->props.find(key);
                return it == info->props.end() ? "" : it->second;
            };
            row("Serial", current_serial);
            row("Model", prop("ro.product.model"));
            row("Manufacturer", prop("ro.product.manufacturer"));
            row("Device", prop("ro.product.device"));
            row("Android", prop("ro.build.version.release"));
            row("SDK API", prop("ro.build.version.sdk"));
            row("CPU ABI", prop("ro.product.cpu.abi"));
            row("Build", prop("ro.build.display.id"));
            row("Battery", !info ? "..." : (info->battery >= 0 ? std::to_string(info->battery) + "%" : "unknown"));

            if (session_ && session_serial_ == current_serial && session_->getState() == SessionState::RUNNING) {
                ImGui::Spacing();
                ImGui::TextColored(Theme::ColorTextSecondary, "Stream");
                ImGui::Spacing();
                auto st = session_->getStreamStats();
                char buf[64];
                row("Codec", session_->getCodecName());
                row("Packets", std::to_string(st.packets));
                snprintf(buf, sizeof(buf), "%.0f KiB", st.bytes / 1024.0);
                row("Bytes", buf);
                row("Decoded", std::to_string(session_->getDecoder().framesDecoded()));
                row("Shown", std::to_string(frames_shown_));
                row("Display", std::to_string(st.display_width) + "x" + std::to_string(st.display_height));
                row("Rotation", std::to_string(st.rotation));
                snprintf(buf, sizeof(buf), "%d kbps", st.bit_rate / 1000);
                row("Bitrate", buf);
                if (session_->hasSensorChannel()) {
                    snprintf(buf, sizeof(buf), "%llu pkts", (unsigned long long)session_->orientationPackets());
                    row("Gyro", buf);
                }
                if (const AudioPlayer* ap = session_->getAudioPlayer()) {
                    snprintf(buf, sizeof(buf), "%llu pkts, peak %.0f dB", (unsigned long long)ap->packetsReceived(), ap->peakDb());
                    row("Audio", buf);
                }
                if (session_->getRecorder().isRecording()) {
                    snprintf(buf, sizeof(buf), "%.0f s", session_->getRecorder().seconds());
                    row("Recording", buf);
                }
            }
        }
    }
    // TAB 1: APPS (Exact layout as macOS screenshot!)
    else if (inspector_tab_ == 1) {
        if (current_serial.empty()) {
            ImGui::TextColored(Theme::ColorTextSecondary, "No device selected");
        } else {
            // Scrollable app list: icon, launcher label, (package)
            float list_h = height - 175.0f * scale_;
            ImGui::BeginChild("##AppList", ImVec2(width - 24.0f * scale_, list_h), false);

            std::string q = app_filter_;
            std::transform(q.begin(), q.end(), q.begin(), ::tolower);

            int matched_count = 0;
            for (size_t i = 0; i < apps_.size(); ++i) {
                const AppRow& app = apps_[i];
                const std::string& pkg = app.id;
                std::string haystack = pkg + " " + app.label;
                std::transform(haystack.begin(), haystack.end(), haystack.begin(), ::tolower);
                if (!q.empty() && haystack.find(q) == std::string::npos) continue;

                matched_count++;
                // Title: the launcher label; until it arrives, the last package segment.
                std::string title = app.label;
                if (title.empty()) {
                    title = pkg;
                    size_t last_dot = pkg.rfind('.');
                    if (last_dot != std::string::npos && last_dot + 1 < pkg.size()) {
                        title = pkg.substr(last_dot + 1);
                        if (!title.empty()) title[0] = std::toupper(title[0]);
                    }
                }

                ImGui::PushID(static_cast<int>(i));
                ImVec2 row_pos = ImGui::GetCursorScreenPos();
                float row_w = width - 24.0f * scale_;
                float row_h = 30.0f * scale_;

                std::string selectable_id = "##app_row_" + std::to_string(i);
                if (ImGui::Selectable(selectable_id.c_str(), false, ImGuiSelectableFlags_AllowDoubleClick, ImVec2(row_w, row_h))) {
                    if (ImGui::IsMouseDoubleClicked(ImGuiMouseButton_Left)) {
                        runShellAsync(current_serial, "monkey -p " + pkg + " -c android.intent.category.LAUNCHER 1",
                                      "Launched " + title);
                    }
                }

                // Icon: the real launcher icon when the device gave us one, else a lettered tile.
                float badge_size = 22.0f * scale_;
                ImVec2 icon_tl(row_pos.x + 2.0f * scale_, row_pos.y + (row_h - badge_size) * 0.5f);
                if (app.icon) {
                    draw_list->AddImageRounded((ImTextureID)app.icon, icon_tl,
                                               ImVec2(icon_tl.x + badge_size, icon_tl.y + badge_size),
                                               ImVec2(0, 0), ImVec2(1, 1), IM_COL32_WHITE, 5.0f * scale_);
                } else {
                    Icons::drawAppBadge(draw_list, icon_tl, badge_size, title, pkg, font_bold_);
                }

                // Title & package name
                float font_bold_size = 15.5f * scale_;
                float font_cap_size = 12.5f * scale_;
                float title_w = 0.0f;
                if (font_bold_) {
                    draw_list->AddText(font_bold_, font_bold_size, ImVec2(row_pos.x + 30.0f * scale_, row_pos.y + 3.5f * scale_),
                                       IM_COL32(28, 28, 30, 255), title.c_str());
                    title_w = font_bold_->CalcTextSizeA(font_bold_size, FLT_MAX, 0.0f, title.c_str()).x;
                } else {
                    draw_list->AddText(ImVec2(row_pos.x + 30.0f * scale_, row_pos.y + 3.5f * scale_),
                                       IM_COL32(28, 28, 30, 255), title.c_str());
                    title_w = ImGui::CalcTextSize(title.c_str()).x;
                }

                std::string pkg_paren = " (" + pkg + ")";
                if (font_caption_) {
                    draw_list->AddText(font_caption_, font_cap_size, ImVec2(row_pos.x + 30.0f * scale_ + title_w + 6.0f * scale_, row_pos.y + 5.5f * scale_),
                                       IM_COL32(142, 142, 147, 255), pkg_paren.c_str());
                } else {
                    draw_list->AddText(ImVec2(row_pos.x + 30.0f * scale_ + title_w + 6.0f * scale_, row_pos.y + 5.5f * scale_),
                                       IM_COL32(142, 142, 147, 255), pkg_paren.c_str());
                }

                if (ImGui::BeginPopupContextItem()) {
                    if (MenuItemWithIcon("Launch", nullptr, Icons::drawScreen, scale_)) {
                        runShellAsync(current_serial, "monkey -p " + pkg + " -c android.intent.category.LAUNCHER 1",
                                      "Launched " + title);
                    }
                    if (MenuItemWithIcon("Force Stop", nullptr, Icons::drawPower, scale_)) {
                        runShellAsync(current_serial, "am force-stop " + pkg, "Stopped " + title);
                    }
                    if (MenuItemWithIcon("Open on Virtual Display", nullptr, Icons::drawWindow, scale_)) {
                        openAppOnVirtualDisplay(pkg);
                    }
                    ImGui::Separator();
                    if (MenuItemWithIcon("Export APK...", nullptr, Icons::drawFile, scale_)) {
                        exportApk(current_serial, pkg);
                    }
                    if (MenuItemWithIcon("Uninstall...", nullptr, Icons::drawDisconnect, scale_)) {
                        pending_uninstall_ = pkg;
                        open_uninstall_popup_ = true;
                    }
                    ImGui::EndPopup();
                }

                ImGui::PopID();
            }
            if (apps_.empty()) {
                ImGui::TextColored(Theme::ColorTextSecondary, packages_loading_ ? "Loading apps..." : "No apps");
            }

            ImGui::EndChild();

            // Uninstall confirmation
            if (open_uninstall_popup_) {
                ImGui::OpenPopup("Uninstall app?");
                open_uninstall_popup_ = false;
            }
            if (ImGui::BeginPopupModal("Uninstall app?", nullptr, ImGuiWindowFlags_AlwaysAutoResize)) {
                ImGui::Text("Uninstall %s from the device?", pending_uninstall_.c_str());
                ImGui::Spacing();
                if (ImGui::Button("Uninstall", ImVec2(110 * scale_, 0))) {
                    std::string serial = current_serial, pkg = pending_uninstall_;
                    jobs_.run<std::string>(
                        [this, serial, pkg] { return adb_.shell(serial, "pm uninstall " + pkg); },
                        [this, serial, pkg](std::string out) {
                            bool ok = out.find("Success") != std::string::npos;
                            showToast(ok ? "Uninstalled " + pkg : "Uninstall failed: " + out, 6);
                            if (serial == selected_serial_) refreshPackages(serial);
                        });
                    pending_uninstall_.clear();
                    ImGui::CloseCurrentPopup();
                }
                ImGui::SameLine();
                if (ImGui::Button("Cancel", ImVec2(90 * scale_, 0))) {
                    pending_uninstall_.clear();
                    ImGui::CloseCurrentPopup();
                }
                ImGui::EndPopup();
            }

            // Bottom Apps Controls
            ImGui::SetCursorPosY(height - 80.0f * scale_);
            std::ostringstream pkg_cnt;
            if (!apps_status_.empty()) pkg_cnt << apps_status_;
            else pkg_cnt << matched_count << " packages" << (app_labels_loading_ ? ", loading icons..." : "");
            if (font_caption_) ImGui::PushFont(font_caption_);
            ImGui::TextColored(Theme::ColorTextSecondary, "%s", pkg_cnt.str().c_str());
            if (font_caption_) ImGui::PopFont();

            if (ImGui::Checkbox("System apps", &show_system_apps_)) {
                refreshPackages(current_serial);
            }
            ImGui::SameLine(width - 135.0f * scale_);
            if (ImGui::Button("Install APK...", ImVec2(110.0f * scale_, 24.0f * scale_))) {
                pickAndInstallApk(current_serial);
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
            // Path bar: up, path, refresh
            ImVec2 btn_sz(26.0f * scale_, 24.0f * scale_);
            bool at_root = (current_remote_path_ == "/");
            if (at_root) ImGui::BeginDisabled();
            if (IconButton("##DirUp", Icons::drawBack, btn_sz, "Up one folder")) {
                std::string parent = current_remote_path_.substr(0, current_remote_path_.rfind('/'));
                navigateTo(current_serial, parent.empty() ? "/" : parent);
            }
            if (at_root) ImGui::EndDisabled();
            ImGui::SameLine();
            {
                // Show the tail of a long path; the full one is in the tooltip.
                float avail = width - 24.0f * scale_ - btn_sz.x * 2 - 24.0f * scale_;
                std::string shown = current_remote_path_;
                while (ImGui::CalcTextSize(shown.c_str()).x > avail && shown.size() > 4) shown = "..." + shown.substr(4);
                ImGui::AlignTextToFramePadding();
                ImGui::TextColored(Theme::ColorTextSecondary, "%s", shown.c_str());
                if (ImGui::IsItemHovered() && shown != current_remote_path_) ImGui::SetTooltip("%s", current_remote_path_.c_str());
            }
            ImGui::SameLine(width - 12.0f * scale_ - btn_sz.x);
            if (IconButton("##RefFiles", Icons::drawRefresh, btn_sz, "Refresh")) {
                refreshFiles(current_serial);
            }

            float list_h = height - 128.0f * scale_;
            ImGui::BeginChild("##FileList", ImVec2(width - 24.0f * scale_, list_h), false);
            float row_w = width - 24.0f * scale_;
            for (size_t i = 0; i < remote_entries_.size(); ++i) {
                const DirEntry& e = remote_entries_[i];
                ImGui::PushID(static_cast<int>(i));
                ImVec2 row_pos = ImGui::GetCursorScreenPos();
                float row_h = 26.0f * scale_;
                std::string full = (current_remote_path_ == "/" ? "" : current_remote_path_) + "/" + e.name;

                if (ImGui::Selectable("##file", false, ImGuiSelectableFlags_AllowDoubleClick, ImVec2(row_w, row_h))) {
                    if (ImGui::IsMouseDoubleClicked(ImGuiMouseButton_Left)) {
                        if (e.isDirectory || e.isLink) navigateTo(current_serial, full);
                        else pullToDownloads(current_serial, full);
                    }
                }

                std::string lower = e.name;
                std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
                auto ends = [&](const char* ext) {
                    size_t n = strlen(ext);
                    return lower.size() > n && lower.compare(lower.size() - n, n, ext) == 0;
                };
                bool is_apk = ends(".apk");
                bool is_img = ends(".png") || ends(".jpg") || ends(".jpeg") || ends(".webp") || ends(".gif") || ends(".heic");

                float icon_sz = 18.0f * scale_;
                ImVec2 icon_tl(row_pos.x + 2.0f * scale_, row_pos.y + (row_h - icon_sz) * 0.5f);
                if (e.isDirectory || e.isLink) {
                    Icons::drawFolder(draw_list, icon_tl, icon_sz, IM_COL32(0, 122, 255, 255));
                } else if (is_apk) {
                    draw_list->AddRectFilled(icon_tl, ImVec2(icon_tl.x + icon_sz, icon_tl.y + icon_sz), IM_COL32(52, 199, 89, 255), 4.0f * scale_);
                    draw_list->AddText(ImVec2(icon_tl.x + 4.0f * scale_, icon_tl.y + 1.0f * scale_), IM_COL32(255, 255, 255, 255), "A");
                } else if (is_img) {
                    Icons::drawCamera(draw_list, icon_tl, icon_sz, IM_COL32(175, 82, 222, 255));
                } else {
                    Icons::drawFile(draw_list, icon_tl, icon_sz, IM_COL32(140, 140, 145, 255));
                }

                // Name, then size right-aligned for files
                draw_list->AddText(ImVec2(row_pos.x + 28.0f * scale_, row_pos.y + 4.0f * scale_),
                                   IM_COL32(30, 30, 34, 255), e.name.c_str());
                if (!e.isDirectory && font_caption_) {
                    char size_buf[32];
                    if (e.size >= 1024LL * 1024 * 1024) snprintf(size_buf, sizeof(size_buf), "%.1f GB", e.size / 1073741824.0);
                    else if (e.size >= 1024 * 1024) snprintf(size_buf, sizeof(size_buf), "%.1f MB", e.size / 1048576.0);
                    else if (e.size >= 1024) snprintf(size_buf, sizeof(size_buf), "%lld KB", e.size / 1024);
                    else snprintf(size_buf, sizeof(size_buf), "%lld B", e.size);
                    float tw = font_caption_->CalcTextSizeA(12.0f * scale_, FLT_MAX, 0.0f, size_buf).x;
                    draw_list->AddText(font_caption_, 12.0f * scale_,
                                       ImVec2(row_pos.x + row_w - tw - 6.0f * scale_, row_pos.y + 6.0f * scale_),
                                       IM_COL32(142, 142, 147, 255), size_buf);
                }
                if (ImGui::IsItemHovered() && !e.modified.empty()) ImGui::SetTooltip("%s  %s", e.permissions.c_str(), e.modified.c_str());

                if (ImGui::BeginPopupContextItem()) {
                    if (e.isDirectory || e.isLink) {
                        if (MenuItemWithIcon("Open", nullptr, Icons::drawFolder, scale_)) navigateTo(current_serial, full);
                    } else {
                        if (MenuItemWithIcon("Save to Downloads", nullptr, Icons::drawFile, scale_)) pullToDownloads(current_serial, full);
                        if (is_apk && MenuItemWithIcon("Install", nullptr, Icons::drawScreen, scale_)) {
                            runShellAsync(current_serial, "pm install -r -t " + AdbClient::shellQuote(full), "Installing " + e.name + "...");
                        }
                    }
                    if (MenuItemWithIcon("Copy Path", nullptr, Icons::drawCopy, scale_)) {
                        ImGui::SetClipboardText(full.c_str());
                        showToast("Copied " + full);
                    }
                    ImGui::Separator();
                    if (MenuItemWithIcon("Delete...", nullptr, Icons::drawDisconnect, scale_)) {
                        pending_delete_ = full;
                        open_delete_popup_ = true;
                    }
                    ImGui::EndPopup();
                }
                ImGui::PopID();
            }
            if (remote_entries_.empty()) {
                ImGui::TextColored(Theme::ColorTextSecondary, files_loading_ ? "Loading..." :
                                   files_error_ ? "Not readable as the shell user" : "Empty folder");
            }
            ImGui::EndChild();

            if (open_delete_popup_) {
                ImGui::OpenPopup("Delete?");
                open_delete_popup_ = false;
            }
            if (ImGui::BeginPopupModal("Delete?", nullptr, ImGuiWindowFlags_AlwaysAutoResize)) {
                ImGui::Text("Delete %s from the device?", pending_delete_.c_str());
                ImGui::Spacing();
                if (ImGui::Button("Delete", ImVec2(100 * scale_, 0))) {
                    std::string serial = current_serial, target = pending_delete_;
                    jobs_.run<std::string>(
                        [this, serial, target] { return adb_.shell(serial, "rm -r " + AdbClient::shellQuote(target) + " 2>&1"); },
                        [this, serial, target](std::string out) {
                            while (!out.empty() && (out.back() == '\n' || out.back() == '\r')) out.pop_back();
                            showToast(out.empty() ? "Deleted " + target : "Delete failed: " + out, 6);
                            if (serial == selected_serial_) refreshFiles(serial);
                        });
                    pending_delete_.clear();
                    ImGui::CloseCurrentPopup();
                }
                ImGui::SameLine();
                if (ImGui::Button("Cancel", ImVec2(90 * scale_, 0))) {
                    pending_delete_.clear();
                    ImGui::CloseCurrentPopup();
                }
                ImGui::EndPopup();
            }

            if (font_caption_) ImGui::PushFont(font_caption_);
            ImGui::TextColored(Theme::ColorTextTertiary, "Double-click a folder to open it, a file to save it. Drop a file here to send it.");
            if (font_caption_) ImGui::PopFont();
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
