#pragma once

// A second SDL window showing one display of the phone: a virtual display
// (Desktop Mode, an app in a window of its own) or the phone's own screen
// popped out bare. It has its own renderer and texture, fits the picture to
// the window on black, and turns mouse and keyboard input into agent messages
// tagged with its display id. Dear ImGui is not involved: it is picture only.

#include "session/agent_session.h"
#include "video/video_decoder.h"
#include "imgui.h"
#include <SDL2/SDL.h>
#include <chrono>
#include <cstdint>
#include <functional>
#include <string>

namespace rplayhub {

// The buttons on the bar that appears along the bottom of a bare window when the pointer
// comes near; the app decides what each does.
enum class ChromeAction { Back, Home, Recents, VolumeDown, VolumeUp, Power, Rotate, Screenshot, Record };

// What the hover chrome (title bar, bottom toolbar) needs from the app.
struct DisplayChrome {
    std::string regular_font, bold_font;   // TTF paths; empty = ImGui's bitmap font
    std::string cjk_font;                  // merged in for title glyphs outside Latin
    int cjk_face = 0;
    float scale = 1.0f;
    std::function<void(ChromeAction)> on_action;
    std::function<bool()> recording;
};

class DisplayWindow {
public:
    DisplayWindow(int32_t display_id, const std::string& title, int width, int height, bool decorated);
    ~DisplayWindow();

    DisplayWindow(const DisplayWindow&) = delete;
    DisplayWindow& operator=(const DisplayWindow&) = delete;

    bool valid() const { return window_ != nullptr; }
    int32_t displayId() const { return display_id_; }
    Uint32 windowId() const { return window_ ? SDL_GetWindowID(window_) : 0; }
    bool decorated() const { return decorated_; }
    const std::string& package() const { return package_; }
    void setPackage(const std::string& p) { package_ = p; }
    void setTitle(const std::string& title);
    // Give the window its hover chrome: the macOS-style title bar and the bottom toolbar,
    // shown while the pointer is in or near the window. Without it the window is picture only.
    void setChrome(const DisplayChrome& chrome);
    void requestClose(const char* why);
    const std::string& closeReason() const { return close_reason_; }

    bool pinned() const { return pinned_; }
    void setPinned(bool on);
    bool hasFocus() const;

    // True when this event belongs to this window and was consumed.
    bool handleEvent(const SDL_Event& e, AgentSession* session);
    bool closeRequested() const { return close_requested_; }

    // Upload the frame if it is new and draw it.
    void render(const DecodedFrame& frame);
    bool saveScreenshotBmp(const std::string& path);

private:
    // Bare window, no frame: a strip along the top drags it, the edges resize it, a close dot
    // appears when the pointer nears the top. On X11 the window has an alpha channel and the
    // corners are painted transparent, which is what rounds them.
    static SDL_HitTestResult hitTest(SDL_Window* win, const SDL_Point* pt, void* data);
    void cutCorners(int out_w, int out_h, float px_per_unit);
    bool argb_ = false;
    void mapToDisplay(int mx, int my, int& dx, int& dy) const;

    // Hover chrome: while the pointer is in or near the window it becomes a normal window
    // like the main window's phone viewer (title bar, phone in its bezel, control strip),
    // drawn with its own Dear ImGui context; otherwise it is the bare picture.
    void buildChromeFonts();
    float updateChromeAlpha(int win_w, int win_h);   // fade toward shown/hidden; returns the alpha
    void renderChrome(int win_w, int win_h, int out_w, int out_h);
    bool overChrome(int x, int y) const;
    // Where the picture sits inside the chassis of the normal window, in window units.
    void chassisPicture(float W, float H, float& px, float& py, float& pw, float& ph) const;
    // The phone's own window gets the chassis and the control strip; Desktop Mode and app
    // windows are plain rectangles (doc/mirror-and-youtube.png) with just a title bar.
    bool isPhone() const { return display_id_ == 0; }
    float titleBarHeight() const { return 52.0f * chrome_.scale; }   // macOS unified-toolbar height
    float toolbarHeight() const { return isPhone() ? 64.0f * chrome_.scale : 0.0f; }
    DisplayChrome chrome_;
    ImGuiContext* ui_ = nullptr;
    ImFont* ui_font_ = nullptr;
    ImFont* ui_font_bold_ = nullptr;
    std::string title_;
    std::string font_title_;          // the title the atlas was built for
    float chrome_alpha_ = 0.0f;       // 0 = hidden, 1 = fully shown

    std::chrono::steady_clock::time_point chrome_clock_{};

    int32_t display_id_;
    bool decorated_;
    std::string package_;
    SDL_Window* window_ = nullptr;
    SDL_Renderer* renderer_ = nullptr;
    SDL_Texture* texture_ = nullptr;
    int tex_w_ = 0, tex_h_ = 0;
    FrameFormat tex_format_ = FrameFormat::NONE;
    uint32_t uploaded_frame_ = 0;
    bool have_frame_ = false;
    // Geometry of the last draw, for input mapping
    SDL_Rect image_rect_{0, 0, 0, 0};
    int disp_w_ = 0, disp_h_ = 0, disp_rot_ = 0;
    bool touch_down_ = false;
    bool pinned_ = false;
    bool close_requested_ = false;
    std::string close_reason_;
};

} // namespace rplayhub
