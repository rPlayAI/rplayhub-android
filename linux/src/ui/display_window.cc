#include "display_window.h"
#include "icons.h"
#include "protocol/control_messages.h"
#include "backends/imgui_impl_sdlrenderer2.h"

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <cstdlib>
#include <iostream>

#include "window_effects.h"

#ifdef RPLAYHUB_HAVE_X11
#include <SDL2/SDL_syswm.h>
#include <X11/Xlib.h>
#include <X11/extensions/shape.h>
#endif

namespace rplayhub {

namespace {

// The normal window's chassis, in proportions of the screen width / the window (doc/rPlayHub-android-vm.png)
constexpr float kBezel = 0.045f;        // bezel each side, of the screen width
constexpr float kChassisSpan = 0.9f;    // chassis width as a share of the window width
constexpr float kChassisGap = 2.0f;     // scaled px between the chassis and each bar

} // namespace

DisplayWindow::DisplayWindow(int32_t display_id, const std::string& title, int width, int height, bool decorated)
    : display_id_(display_id), decorated_(decorated), title_(title) {
    // "Naked" like the Mac's pop-out: no frame, rounded corners where the platform allows,
    // dragged by its top strip.
    // Hidden until setChrome() has sized it with its margins, so it never shows twice.
    const Uint32 flags = SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_BORDERLESS | SDL_WINDOW_OPENGL | SDL_WINDOW_HIDDEN;
    const std::string argb_visual = argbVisualId();
    // First with the ARGB visual, then, if the driver will not render to it, a plain window.
    for (int attempt = 0; attempt < 2 && !renderer_; ++attempt) {
        const bool argb = attempt == 0 && !argb_visual.empty();
        if (attempt == 1 && argb_visual.empty()) break;
        if (argb) SDL_SetHint(SDL_HINT_VIDEO_X11_WINDOW_VISUALID, argb_visual.c_str());
        window_ = SDL_CreateWindow(title.c_str(), SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, width, height, flags);
        if (window_) {
            renderer_ = SDL_CreateRenderer(window_, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
            if (!renderer_) renderer_ = SDL_CreateRenderer(window_, -1, 0);
        }
        if (argb) SDL_ResetHint(SDL_HINT_VIDEO_X11_WINDOW_VISUALID);
        if (!window_ || !renderer_) {
            std::cerr << "DisplayWindow: " << (window_ ? "SDL_CreateRenderer: " : "SDL_CreateWindow: ")
                      << SDL_GetError() << (argb ? " (ARGB visual; retrying without)" : "") << "\n";
            if (window_) SDL_DestroyWindow(window_);
            window_ = nullptr;
            continue;
        }
        argb_ = argb;
    }
    if (!window_) return;
    SDL_SetWindowHitTest(window_, &DisplayWindow::hitTest, this);

    cursor_arrow_ = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_ARROW);
    cursor_resize_ew_ = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZEWE);
    cursor_resize_ns_ = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZENS);
    cursor_resize_nwse_ = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZENWSE);
    cursor_resize_nesw_ = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZENESW);
}

DisplayWindow::~DisplayWindow() {
    if (cursor_arrow_) { SDL_FreeCursor(cursor_arrow_); cursor_arrow_ = nullptr; }
    if (cursor_resize_ew_) { SDL_FreeCursor(cursor_resize_ew_); cursor_resize_ew_ = nullptr; }
    if (cursor_resize_ns_) { SDL_FreeCursor(cursor_resize_ns_); cursor_resize_ns_ = nullptr; }
    if (cursor_resize_nwse_) { SDL_FreeCursor(cursor_resize_nwse_); cursor_resize_nwse_ = nullptr; }
    if (cursor_resize_nesw_) { SDL_FreeCursor(cursor_resize_nesw_); cursor_resize_nesw_ = nullptr; }

    if (ui_) {
        ImGuiContext* prev = ImGui::GetCurrentContext();
        ImGui::SetCurrentContext(ui_);
        ImGui_ImplSDLRenderer2_Shutdown();
        ImGui::DestroyContext(ui_);
        ImGui::SetCurrentContext(prev == ui_ ? nullptr : prev);
        ui_ = nullptr;
    }
    if (texture_) SDL_DestroyTexture(texture_);
    if (renderer_) SDL_DestroyRenderer(renderer_);
    if (window_) SDL_DestroyWindow(window_);
}

// The bare view needs no corner cut: the chassis is drawn with its own rounded corners over a
// transparent window. While the bars are in, the stage is a normal window with ~10 pt corners.
void DisplayWindow::cutCorners(int out_w, int out_h, float px_per_unit) {
    if (!argb_ || chrome_alpha_ <= 0.0f) return;
    rplayhub::cutCorners(renderer_, out_w, out_h, 11.0f * chrome_.scale * px_per_unit);
}

SDL_HitTestResult DisplayWindow::hitTest(SDL_Window* win, const SDL_Point* pt, void* data) {
    DisplayWindow* self = static_cast<DisplayWindow*>(data);
    int w = 0, h = 0;
    SDL_GetWindowSize(win, &w, &h);
    const int edge = 8;
    const float s = self->chrome_.scale;
    if (self->chrome_alpha_ < 0.5f) {
        // Bare: only the phone's box counts. Its edges resize the window, its top strip drags.
        const int bx = self->framed_ ? self->grow_dx_ : 0, by = self->framed_ ? self->grow_dy_ : 0;
        const int bw = self->framed_ ? self->bare_w_ : w, bh = self->framed_ ? self->bare_h_ : h;
        const int x = pt->x - bx, y = pt->y - by;
        if (x < 0 || y < 0 || x >= bw || y >= bh) return SDL_HITTEST_NORMAL;
        bool l = x < edge, r = x >= bw - edge, t = y < edge, b = y >= bh - edge;
        if (t && l) return SDL_HITTEST_RESIZE_TOPLEFT;
        if (t && r) return SDL_HITTEST_RESIZE_TOPRIGHT;
        if (b && l) return SDL_HITTEST_RESIZE_BOTTOMLEFT;
        if (b && r) return SDL_HITTEST_RESIZE_BOTTOMRIGHT;
        if (t) return SDL_HITTEST_RESIZE_TOP;
        if (b) return SDL_HITTEST_RESIZE_BOTTOM;
        if (l) return SDL_HITTEST_RESIZE_LEFT;
        if (r) return SDL_HITTEST_RESIZE_RIGHT;
        return y < 40.0f * s ? SDL_HITTEST_DRAGGABLE : SDL_HITTEST_NORMAL;
    }
    bool l = pt->x < edge, r = pt->x >= w - edge, t = pt->y < edge, b = pt->y >= h - edge;
    if (t && l) return SDL_HITTEST_RESIZE_TOPLEFT;
    if (t && r) return SDL_HITTEST_RESIZE_TOPRIGHT;
    if (b && l) return SDL_HITTEST_RESIZE_BOTTOMLEFT;
    if (b && r) return SDL_HITTEST_RESIZE_BOTTOMRIGHT;
    if (t) return SDL_HITTEST_RESIZE_TOP;
    if (b) return SDL_HITTEST_RESIZE_BOTTOM;
    if (l) return SDL_HITTEST_RESIZE_LEFT;
    if (r) return SDL_HITTEST_RESIZE_RIGHT;
    // The traffic lights at the top-left take the click; the rest of the title strip drags.
    if (pt->y < self->titleBarHeight()) return pt->x < 90.0f * s ? SDL_HITTEST_NORMAL : SDL_HITTEST_DRAGGABLE;
    return SDL_HITTEST_NORMAL;
}

void DisplayWindow::requestClose(const char* why) {
    if (!close_requested_) close_reason_ = why ? why : "";
    close_requested_ = true;
    if (std::getenv("RPLAYHUB_INPUT_DEBUG")) std::cerr << "display window " << display_id_ << ": close requested (" << close_reason_ << ")\n";
}

void DisplayWindow::setTitle(const std::string& title) {
    title_ = title;
    if (window_) SDL_SetWindowTitle(window_, title.c_str());
    if (ui_ && title != font_title_) buildChromeFonts();   // the atlas may lack its glyphs
}

void DisplayWindow::setChrome(const DisplayChrome& chrome) {
    chrome_ = chrome;
    if (!renderer_) return;
    if (!framed_) {
        // The window was created at the phone's size; add the room for the bars and margins
        // around it, keeping the phone where it is, then show it for the first time.
        int w = 0, h = 0, x = 0, y = 0;
        SDL_GetWindowSize(window_, &w, &h);
        SDL_GetWindowPosition(window_, &x, &y);
        frameFromBare(w, h);
        SDL_SetWindowSize(window_, grown_w_, grown_h_);
        SDL_SetWindowPosition(window_, x - grow_dx_, y - grow_dy_);
        framed_ = true;
        SDL_ShowWindow(window_);
        applyInputShape(false);
    }
    if (ui_) return;
    ImGuiContext* prev = ImGui::GetCurrentContext();
    ui_ = ImGui::CreateContext();
    ImGui::SetCurrentContext(ui_);
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.LogFilename = nullptr;
    ImGui::StyleColorsDark();
    ImGuiStyle& st = ImGui::GetStyle();
    st.Colors[ImGuiCol_PopupBg] = ImVec4(0.11f, 0.11f, 0.13f, 1.0f);
    st.WindowRounding = 6.0f * chrome_.scale;
    st.WindowPadding = ImVec2(8.0f * chrome_.scale, 6.0f * chrome_.scale);
    ImGui_ImplSDLRenderer2_Init(renderer_);
    buildChromeFonts();
    ImGui::SetCurrentContext(prev);
}

// Latin plus whatever the title needs; called with ui_ current or from setTitle.
void DisplayWindow::buildChromeFonts() {
    ImGuiContext* prev = ImGui::GetCurrentContext();
    ImGui::SetCurrentContext(ui_);
    ImGuiIO& io = ImGui::GetIO();
    io.Fonts->Clear();
    ImGui_ImplSDLRenderer2_DestroyFontsTexture();
    const float s = chrome_.scale;
    static ImVector<ImWchar> ranges;
    ranges.clear();
    bool beyond_latin = false;
    {
        ImFontGlyphRangesBuilder b;
        static const ImWchar latin[] = { 0x0020, 0x00FF, 0x2000, 0x206F, 0 };
        b.AddRanges(latin);
        b.AddText(title_.c_str());
        for (unsigned char c : title_) if (c >= 0x80) beyond_latin = true;
        b.BuildRanges(&ranges);
    }
    ui_font_ = ui_font_bold_ = nullptr;
    if (!chrome_.regular_font.empty()) {
        ui_font_ = io.Fonts->AddFontFromFileTTF(chrome_.regular_font.c_str(), 13.5f * s, nullptr, ranges.Data);
    }
    if (!chrome_.bold_font.empty()) {
        ui_font_bold_ = io.Fonts->AddFontFromFileTTF(chrome_.bold_font.c_str(), 15.0f * s, nullptr, ranges.Data);
        if (beyond_latin && !chrome_.cjk_font.empty()) {
            ImFontConfig cfg;
            cfg.MergeMode = true;
            cfg.FontNo = chrome_.cjk_face;
            cfg.OversampleH = 1;
            io.Fonts->AddFontFromFileTTF(chrome_.cjk_font.c_str(), 15.0f * s, &cfg, ranges.Data);
        }
    }
    if (!ui_font_) ui_font_ = io.Fonts->AddFontDefault();
    if (!ui_font_bold_) ui_font_bold_ = ui_font_;
    io.FontDefault = ui_font_;
    font_title_ = title_;
    ImGui::SetCurrentContext(prev);
}

void DisplayWindow::moveResize(int w, int h, int x, int y) {
    if (std::getenv("RPLAYHUB_INPUT_DEBUG")) std::cerr << "display window " << display_id_ << ": resize to " << w << "x" << h << " at " << x << "," << y << "\n";
#ifdef RPLAYHUB_HAVE_X11
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (SDL_GetWindowWMInfo(window_, &info) && info.subsystem == SDL_SYSWM_X11) {
        XMoveResizeWindow(info.info.x11.display, info.info.x11.window, x, y, static_cast<unsigned>(w), static_cast<unsigned>(h));
        XFlush(info.info.x11.display);
        return;
    }
#endif
    SDL_SetWindowSize(window_, w, h);
    SDL_SetWindowPosition(window_, x, y);
}

// The Mac's proportions: the chassis spans 90 % of the window's width, the title bar sits
// above it and the strip below, each with a small gap. Desktop Mode / app windows only get
// the title bar.
void DisplayWindow::frameFromBare(int bw, int bh) {
    bare_w_ = bw;
    bare_h_ = bh;
    const float gap = isPhone() ? kChassisGap * chrome_.scale : 0.0f;
    grown_w_ = isPhone() ? static_cast<int>(std::lround(bw / kChassisSpan)) : bw;
    grown_h_ = static_cast<int>(std::lround(titleBarHeight() + gap + bh + gap + toolbarHeight()));
    grow_dx_ = (grown_w_ - bw) / 2;
    grow_dy_ = static_cast<int>(std::lround(titleBarHeight() + gap));
}

// The inverse, for a window the user resized: the phone's box is what is left between the
// bars and the margins.
void DisplayWindow::layoutFromWindow(int win_w, int win_h) {
    if (!framed_) return;
    if (win_w == grown_w_ && win_h == grown_h_) return;
    const float gap = isPhone() ? kChassisGap * chrome_.scale : 0.0f;
    const int bw = isPhone() ? static_cast<int>(std::lround(win_w * kChassisSpan)) : win_w;
    const int bh = std::max(1, static_cast<int>(std::lround(win_h - titleBarHeight() - toolbarHeight() - 2.0f * gap)));
    bare_w_ = bw;
    bare_h_ = bh;
    grown_w_ = win_w;
    grown_h_ = win_h;
    grow_dx_ = (win_w - bw) / 2;
    grow_dy_ = static_cast<int>(std::lround(titleBarHeight() + gap));
    applyInputShape(input_full_);
}

// Clicks in the transparent margins must reach whatever is behind: while the bars are hidden
// the window's input shape is just the phone's box.
void DisplayWindow::applyInputShape(bool full) {
    input_full_ = full;
#ifdef RPLAYHUB_HAVE_X11
    if (!window_) return;
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(window_, &info) || info.subsystem != SDL_SYSWM_X11) return;
    int w = 0, h = 0;
    SDL_GetWindowSize(window_, &w, &h);
    XRectangle r;
    if (full || !framed_) { r = { 0, 0, static_cast<unsigned short>(w), static_cast<unsigned short>(h) }; }
    else { r = { static_cast<short>(grow_dx_), static_cast<short>(grow_dy_), static_cast<unsigned short>(bare_w_), static_cast<unsigned short>(bare_h_) }; }
    XShapeCombineRectangles(info.info.x11.display, info.info.x11.window, ShapeInput, 0, 0, &r, 1, ShapeSet, Unsorted);
    XFlush(info.info.x11.display);
#endif
}

// Like the Mac's sizeWindowToMirror: when the picture turns, the window turns with it, keeping
// the phone's longest side and the window's centre, so the phone fills its box either way.
void DisplayWindow::fitWindowToFrame() {
    if (!window_ || tex_w_ <= 0 || tex_h_ <= 0) return;
    if (SDL_GetWindowFlags(window_) & SDL_WINDOW_MAXIMIZED) return;
    int w = 0, h = 0, x = 0, y = 0;
    SDL_GetWindowSize(window_, &w, &h);
    SDL_GetWindowPosition(window_, &x, &y);
    const int bw = framed_ ? bare_w_ : w, bh = framed_ ? bare_h_ : h;
    const int longest = std::max(bw, bh);
    const float aspect = presentedAspect();
    int nw, nh;
    if (isPhone()) {
        if (aspect < 1.0f) {   // portrait: the chassis is `longest` tall
            const float pw = longest / (1.0f / aspect + 2.0f * kBezel);
            nw = static_cast<int>(std::lround(pw * (1.0f + 2.0f * kBezel)));
            nh = bareHeightForWidth(nw, aspect);
        } else {
            nw = longest;
            nh = bareHeightForWidth(nw, aspect);
        }
    } else if (aspect < 1.0f) {
        nh = longest; nw = static_cast<int>(std::lround(longest * aspect));
    } else {
        nw = longest; nh = static_cast<int>(std::lround(longest / aspect));
    }
    const int cx = x + w / 2, cy = y + h / 2;
    if (!framed_) {
        moveResize(nw, nh, cx - nw / 2, cy - nh / 2);
    } else {
        frameFromBare(nw, nh);
        moveResize(grown_w_, grown_h_, cx - grown_w_ / 2, cy - grown_h_ / 2);
        applyInputShape(input_full_);
    }
}

int DisplayWindow::bareHeightForWidth(int width, float screen_aspect) {
    const float pw = width / (1.0f + 2.0f * kBezel);
    return static_cast<int>(std::lround(pw / screen_aspect + 2.0f * kBezel * pw));
}

void DisplayWindow::barePicture(float W, float H, float& px, float& py, float& pw, float& ph) const {
    const float aspect = presentedAspect();
    if (!isPhone()) {   // no chassis: the picture fills the window
        pw = W; ph = pw / aspect;
        if (ph > H) { ph = H; pw = ph * aspect; }
    } else {
        pw = std::min(W / (1.0f + 2.0f * kBezel), H / (1.0f / aspect + 2.0f * kBezel));
        ph = pw / aspect;
    }
    px = (W - pw) * 0.5f;
    py = (H - ph) * 0.5f;
}

void DisplayWindow::chassisPicture(float W, float H, float& px, float& py, float& pw, float& ph) const {
    const float s = chrome_.scale;
    const float stage_top = titleBarHeight(), stage_h = std::max(1.0f, H - titleBarHeight() - toolbarHeight());
    const float aspect = presentedAspect();
    if (!isPhone()) {   // plain window: the picture fills everything under the title bar
        pw = W; ph = pw / aspect;
        if (ph > stage_h) { ph = stage_h; pw = ph * aspect; }
        px = (W - pw) * 0.5f; py = stage_top + (stage_h - ph) * 0.5f;
        return;
    }
    const float gap_v = kChassisGap * s;
    ph = (stage_h - 2.0f * gap_v) / (1.0f + 2.0f * kBezel * aspect);
    pw = ph * aspect;
    const float max_pw = kChassisSpan * W / (1.0f + 2.0f * kBezel);
    if (pw > max_pw) { pw = max_pw; ph = pw / aspect; }
    px = (W - pw) * 0.5f;
    py = stage_top + (stage_h - ph) * 0.5f;
}

// In the normal view only the phone's picture takes touches; the rest is window furniture.
bool DisplayWindow::overChrome(int x, int y) const {
    if (!ui_ || chrome_alpha_ < 0.5f) return false;
    return x < image_rect_.x || y < image_rect_.y || x >= image_rect_.x + image_rect_.w || y >= image_rect_.y + image_rect_.h;
}

void DisplayWindow::setPinned(bool on) {
    pinned_ = on;
    if (window_) SDL_SetWindowAlwaysOnTop(window_, on ? SDL_TRUE : SDL_FALSE);
}

bool DisplayWindow::hasFocus() const {
    return window_ && (SDL_GetWindowFlags(window_) & SDL_WINDOW_INPUT_FOCUS);
}

void DisplayWindow::mapToDisplay(int mx, int my, int& dx, int& dy) const {
    float fx = image_rect_.w > 0 ? std::clamp((mx - image_rect_.x) / static_cast<float>(image_rect_.w), 0.0f, 1.0f) : 0.0f;
    float fy = image_rect_.h > 0 ? std::clamp((my - image_rect_.y) / static_cast<float>(image_rect_.h), 0.0f, 1.0f) : 0.0f;
    float nx = fx, ny = fy;
    switch (disp_rot_) {
        case 1: nx = 1.0f - fy; ny = fx; break;
        case 2: nx = 1.0f - fx; ny = 1.0f - fy; break;
        case 3: nx = fy; ny = 1.0f - fx; break;
        default: break;
    }
    dx = static_cast<int>(nx * disp_w_);
    dy = static_cast<int>(ny * disp_h_);
}

bool DisplayWindow::handleEvent(const SDL_Event& e, AgentSession* session) {
    if (!window_) return false;
    const Uint32 id = windowId();
    // The chrome's ImGui context sees the pointer first (its own queue, its own window).
    if (ui_) {
        ImGuiContext* prev = ImGui::GetCurrentContext();
        ImGui::SetCurrentContext(ui_);
        ImGuiIO& io = ImGui::GetIO();
        if (e.type == SDL_MOUSEMOTION && e.motion.windowID == id) {
            io.AddMousePosEvent(static_cast<float>(e.motion.x), static_cast<float>(e.motion.y));
        } else if ((e.type == SDL_MOUSEBUTTONDOWN || e.type == SDL_MOUSEBUTTONUP) && e.button.windowID == id) {
            int b = e.button.button == SDL_BUTTON_LEFT ? 0 : e.button.button == SDL_BUTTON_RIGHT ? 1 : e.button.button == SDL_BUTTON_MIDDLE ? 2 : -1;
            if (b >= 0) {
                io.AddMousePosEvent(static_cast<float>(e.button.x), static_cast<float>(e.button.y));
                io.AddMouseButtonEvent(b, e.type == SDL_MOUSEBUTTONDOWN);
            }
        } else if (e.type == SDL_WINDOWEVENT && e.window.windowID == id && e.window.event == SDL_WINDOWEVENT_LEAVE) {
            io.AddMousePosEvent(-FLT_MAX, -FLT_MAX);
        }
        ImGui::SetCurrentContext(prev);
    }
    switch (e.type) {
    case SDL_WINDOWEVENT:
        if (e.window.windowID != id) return false;
        if (e.window.event == SDL_WINDOWEVENT_CLOSE) requestClose("window manager");
        if (e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) layoutFromWindow(e.window.data1, e.window.data2);
        if (e.window.event == SDL_WINDOWEVENT_LEAVE && cursor_overridden_) {
            SDL_SetCursor(cursor_arrow_);
            cursor_overridden_ = false;
        }
        return true;
    case SDL_MOUSEBUTTONDOWN:
    case SDL_MOUSEBUTTONUP: {
        // Presses on the title bar or the toolbar belong to the chrome; a touch already in
        // progress still gets its release.
        if (e.button.windowID == id && !touch_down_ && overChrome(e.button.x, e.button.y)) return true;
        if (std::getenv("RPLAYHUB_INPUT_DEBUG")) {
            std::cerr << "display window " << display_id_ << ": button event for window " << e.button.windowID
                      << " (mine " << id << ") at " << e.button.x << "," << e.button.y
                      << " session=" << (session != nullptr) << " disp=" << disp_w_ << "x" << disp_h_
                      << " rect=" << image_rect_.x << "," << image_rect_.y << " " << image_rect_.w << "x" << image_rect_.h << "\n";
        }
        if (e.button.windowID != id) return false;
        if (!session || disp_w_ <= 0) return true;
        if (e.button.button == SDL_BUTTON_RIGHT) {
            if (e.type == SDL_MOUSEBUTTONDOWN) session->sendKey(AndroidKey::BACK);
            return true;
        }
        if (e.button.button != SDL_BUTTON_LEFT) return true;
        int dx, dy;
        mapToDisplay(e.button.x, e.button.y, dx, dy);
        if (e.type == SDL_MOUSEBUTTONDOWN) {
            touch_down_ = true;
            session->sendTouch(dx, dy, MotionAction::DOWN, display_id_);
        } else if (touch_down_) {
            touch_down_ = false;
            session->sendTouch(dx, dy, MotionAction::UP, display_id_);
        }
        return true;
    }
    case SDL_MOUSEMOTION: {
        if (e.motion.windowID != id) return false;
        if (session && touch_down_ && disp_w_ > 0) {
            int dx, dy;
            mapToDisplay(e.motion.x, e.motion.y, dx, dy);
            session->sendTouch(dx, dy, MotionAction::MOVE, display_id_);
        } else if (!touch_down_) {
            int w = 0, h = 0;
            SDL_GetWindowSize(window_, &w, &h);
            int mx = e.motion.x, my = e.motion.y;
            const int edge = static_cast<int>(std::max(8.0f, 7.0f * chrome_.scale));
            bool l = (mx < edge), r = (mx >= w - edge), t = (my < edge), b = (my >= h - edge);
            SDL_Cursor* target = nullptr;
            if ((t && l) || (b && r)) target = cursor_resize_nwse_;
            else if ((t && r) || (b && l)) target = cursor_resize_nesw_;
            else if (l || r) target = cursor_resize_ew_;
            else if (t || b) target = cursor_resize_ns_;

            if (target) {
                SDL_SetCursor(target);
                cursor_overridden_ = true;
            } else if (cursor_overridden_) {
                SDL_SetCursor(cursor_arrow_);
                cursor_overridden_ = false;
            }
        }
        return true;
    }
    case SDL_MOUSEWHEEL: {
        if (e.wheel.windowID != id) return false;
        if (session && disp_w_ > 0) {
            int mx, my;
            SDL_GetMouseState(&mx, &my);
            int dx, dy;
            mapToDisplay(mx, my, dx, dy);
            session->sendScroll(dx, dy, static_cast<float>(e.wheel.x), static_cast<float>(e.wheel.y), display_id_);
        }
        return true;
    }
    case SDL_KEYDOWN: {
        if (e.key.windowID != id) return false;
        if (!session) return true;
        int key = -1;
        switch (e.key.keysym.sym) {
            case SDLK_BACKSPACE: key = AndroidKey::DEL; break;
            case SDLK_RETURN: case SDLK_KP_ENTER: key = AndroidKey::ENTER; break;
            case SDLK_ESCAPE: key = AndroidKey::BACK; break;
            case SDLK_TAB: key = AndroidKey::TAB; break;
            case SDLK_HOME: key = AndroidKey::HOME; break;
            case SDLK_UP: key = AndroidKey::DPAD_UP; break;
            case SDLK_DOWN: key = AndroidKey::DPAD_DOWN; break;
            case SDLK_LEFT: key = AndroidKey::DPAD_LEFT; break;
            case SDLK_RIGHT: key = AndroidKey::DPAD_RIGHT; break;
            case SDLK_DELETE: key = AndroidKey::FORWARD_DEL; break;
            default: break;
        }
        if (key >= 0) session->sendKey(key);
        return true;
    }
    case SDL_TEXTINPUT:
        if (e.text.windowID != id) return false;
        if (session) session->sendText(e.text.text);
        return true;
    default:
        return false;
    }
}

void DisplayWindow::render(const DecodedFrame& frame) {
    if (!renderer_) return;
    if (!frame.empty()) {
        if (!texture_ || tex_w_ != frame.width || tex_h_ != frame.height || tex_format_ != frame.format) {
            if (texture_) SDL_DestroyTexture(texture_);
            Uint32 fmt = SDL_PIXELFORMAT_RGBA32;
            if (frame.format == FrameFormat::I420) fmt = SDL_PIXELFORMAT_IYUV;
            else if (frame.format == FrameFormat::NV12) fmt = SDL_PIXELFORMAT_NV12;
            texture_ = SDL_CreateTexture(renderer_, fmt, SDL_TEXTUREACCESS_STREAMING, frame.width, frame.height);
            // Blend: the rounded picture's anti-aliased edge must fade into the bezel, not
            // punch low-alpha pixels through the ARGB window (a light line along the edge).
            if (texture_) SDL_SetTextureBlendMode(texture_, SDL_BLENDMODE_BLEND);
            tex_w_ = frame.width;
            tex_h_ = frame.height;
            tex_format_ = frame.format;
            uploaded_frame_ = 0;
            turn_ = frame.correctionQuadrants();
            const int landscape = presentedAspect() > 1.0f ? 1 : 0;
            // A turn flips the aspect; a foldable's fold swaps the panel and changes it too.
            if (tex_landscape_ >= 0 && (tex_landscape_ != landscape || std::fabs(presentedAspect() - tex_aspect_) > 0.02f)) fitWindowToFrame();
            tex_landscape_ = landscape;
            tex_aspect_ = presentedAspect();
            have_frame_ = false;
        }
        if (texture_ && (!have_frame_ || frame.frameNumber != uploaded_frame_)) {
            switch (frame.format) {
            case FrameFormat::I420:
                SDL_UpdateYUVTexture(texture_, nullptr, frame.planes[0].data(), frame.pitch[0],
                                     frame.planes[1].data(), frame.pitch[1], frame.planes[2].data(), frame.pitch[2]);
                break;
            case FrameFormat::NV12:
                SDL_UpdateNVTexture(texture_, nullptr, frame.planes[0].data(), frame.pitch[0],
                                    frame.planes[1].data(), frame.pitch[1]);
                break;
            default:
                SDL_UpdateTexture(texture_, nullptr, frame.planes[0].data(), frame.pitch[0]);
                break;
            }
            uploaded_frame_ = frame.frameNumber;
            have_frame_ = true;
        }
        disp_w_ = frame.displayWidth > 0 ? frame.displayWidth : frame.width;
        disp_h_ = frame.displayHeight > 0 ? frame.displayHeight : frame.height;
        disp_rot_ = frame.presentedQuadrants();
        if (turn_ != frame.correctionQuadrants()) {
            turn_ = frame.correctionQuadrants();
            const int landscape = presentedAspect() > 1.0f ? 1 : 0;
            if (tex_landscape_ != landscape) { fitWindowToFrame(); tex_landscape_ = landscape; }
        }
    }

    int out_w = 0, out_h = 0;
    SDL_GetRendererOutputSize(renderer_, &out_w, &out_h);
    int win_w = 0, win_h = 0;
    SDL_GetWindowSize(window_, &win_w, &win_h);
    // Input arrives in window coordinates; the renderer may be high-DPI scaled.
    const float px = win_w > 0 ? static_cast<float>(out_w) / win_w : 1.0f;
    const float a = (ui_ && win_w > 0 && win_h > 0) ? updateChromeAlpha(win_w, win_h) : 0.0f;
    if (SDL_GetWindowFlags(window_) & SDL_WINDOW_HIDDEN) SDL_ShowWindow(window_);   // no chrome was set
    // Transparent outside the phone: the margins only show once the bars fade in.
    if (argb_) SDL_SetRenderDrawColor(renderer_, 0, 0, 0, 0); else SDL_SetRenderDrawColor(renderer_, 0, 0, 0, 255);
    SDL_RenderClear(renderer_);
    if (ui_) {
        // The window never changes size or position: the chrome context draws the phone in
        // its box every frame and fades the bars and margins in or out around it.
        if (win_w > 0 && win_h > 0) renderChrome(win_w, win_h, out_w, out_h);
    } else if (texture_ && have_frame_ && out_w > 0 && out_h > 0) {
        float aspect = presentedAspect();
        int w = out_w, h = static_cast<int>(out_w / aspect);
        if (h > out_h) { h = out_h; w = static_cast<int>(out_h * aspect); }
        SDL_Rect bare = { (out_w - w) / 2, (out_h - h) / 2, w, h };
        if (turn_ == 0) {
            SDL_RenderCopy(renderer_, texture_, nullptr, &bare);
        } else {   // SDL rotates about the destination centre: give it the untamed rect
            SDL_Rect src_sized = (turn_ % 2 == 1) ? SDL_Rect{ bare.x + (bare.w - bare.h) / 2, bare.y + (bare.h - bare.w) / 2, bare.h, bare.w } : bare;
            SDL_RenderCopyEx(renderer_, texture_, nullptr, &src_sized, -90.0 * turn_, nullptr, SDL_FLIP_NONE);
        }
        image_rect_ = px != 1.0f ? SDL_Rect{ static_cast<int>(bare.x / px), static_cast<int>(bare.y / px),
                                             static_cast<int>(bare.w / px), static_cast<int>(bare.h / px) }
                                 : bare;
    }
    {
        int win_w = 0;
        SDL_GetWindowSize(window_, &win_w, nullptr);
        cutCorners(out_w, out_h, win_w > 0 ? static_cast<float>(out_w) / win_w : 1.0f);
    }
    SDL_RenderPresent(renderer_);
}

// Fade the normal view in while the pointer is in or near the window, out when it leaves.
float DisplayWindow::updateChromeAlpha(int win_w, int win_h) {
    const auto now = std::chrono::steady_clock::now();
    float dt = chrome_clock_.time_since_epoch().count() == 0
                   ? 1.0f / 60.0f
                   : std::chrono::duration<float>(now - chrome_clock_).count();
    chrome_clock_ = now;
    dt = std::clamp(dt, 0.001f, 0.1f);

    int gx = 0, gy = 0, wx = 0, wy = 0;
    SDL_GetGlobalMouseState(&gx, &gy);
    SDL_GetWindowPosition(window_, &wx, &wy);
#ifdef RPLAYHUB_HAVE_X11
    {
        // SDL caches the global pointer and stops refreshing it once the window's input
        // shape no longer covers the pointer; ask the X server directly.
        SDL_SysWMinfo info;
        SDL_VERSION(&info.version);
        if (SDL_GetWindowWMInfo(window_, &info) && info.subsystem == SDL_SYSWM_X11) {
            ::Window root_ret, child_ret; int rx, ry, cx, cy; unsigned mask;
            if (XQueryPointer(info.info.x11.display, DefaultRootWindow(info.info.x11.display), &root_ret, &child_ret, &rx, &ry, &cx, &cy, &mask)) {
                gx = rx; gy = ry;
            }
        }
    }
#endif
    const int reach = static_cast<int>(48.0f * chrome_.scale);
    // Near the phone itself, not the window (whose margins are invisible while bare)
    const int bx = wx + (framed_ ? grow_dx_ : 0), by = wy + (framed_ ? grow_dy_ : 0);
    const int bw = framed_ ? bare_w_ : win_w, bh = framed_ ? bare_h_ : win_h;
    const bool near = gx >= bx - reach && gx < bx + bw + reach && gy >= by - reach && gy < by + bh + reach;
    // A touch in progress keeps the view where it is.
    const float target = (near || touch_down_) ? 1.0f : 0.0f;
    if (std::getenv("RPLAYHUB_INPUT_DEBUG")) {
        static int last_near = -1;
        if (static_cast<int>(near) != last_near) {
            last_near = near;
            std::cerr << "display window " << display_id_ << ": pointer " << gx << "," << gy << " phone box " << bx << "," << by
                      << " " << bw << "x" << bh << " -> " << (near ? "near" : "away") << "\n";
        }
    }
    // The bars take input as soon as they start coming in, and give it back once gone.
    if (target > 0.5f && !input_full_) applyInputShape(true);
    chrome_alpha_ += (target - chrome_alpha_) * std::min(1.0f, dt * 12.0f);
    if (chrome_alpha_ < 0.01f) chrome_alpha_ = 0.0f;
    if (chrome_alpha_ > 0.99f) chrome_alpha_ = 1.0f;
    if (const char* forced = std::getenv("RPLAYHUB_CHROME_ALPHA")) chrome_alpha_ = std::clamp(static_cast<float>(std::atof(forced)), 0.0f, 1.0f);   // for screenshots
    if (chrome_alpha_ == 0.0f && input_full_ && framed_) applyInputShape(false);

    return chrome_alpha_;
}

// The normal-window look, modelled on the main window's phone viewer: a light title bar with
// the traffic lights and the title, the phone in its black bezel on a light stage, and the
// control strip along the bottom. It fades in over the bare picture while the pointer is in
// or near the window and out again when it leaves. Everything here goes through the
// window's own ImGui context; the video is the SDL texture drawn with rounded corners.
void DisplayWindow::renderChrome(int win_w, int win_h, int out_w, int out_h) {
    const float a = chrome_alpha_;
    const float s = chrome_.scale;

    ImGuiContext* prev = ImGui::GetCurrentContext();
    ImGui::SetCurrentContext(ui_);
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize = ImVec2(static_cast<float>(win_w), static_cast<float>(win_h));
    io.DisplayFramebufferScale = ImVec2(static_cast<float>(out_w) / win_w, static_cast<float>(out_h) / win_h);
    io.DeltaTime = 1.0f / 60.0f;
    ImGui_ImplSDLRenderer2_NewFrame();
    ImGui::NewFrame();

    const ImGuiWindowFlags flags = ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove |
                                   ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBackground |
                                   ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoScrollWithMouse;
    auto alpha = [a](int r, int g, int b, int al) { return IM_COL32(r, g, b, static_cast<int>(al * a)); };
    const float W = static_cast<float>(win_w), H = static_cast<float>(win_h);
    const float top_h = titleBarHeight(), strip_h = toolbarHeight();

    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(ImVec2(W, H));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
    ImGui::Begin("##normal", nullptr, flags);
    ImDrawList* dl = ImGui::GetWindowDrawList();

    // The window around the phone: white stage and strip, light gray title bar
    // (doc/rPlayHub-android-vm.png), a normal window's rounded corners, fading in over the
    // transparent margins.
    const float wr = 11.0f * s;
    if (a > 0.0f) {
        dl->AddRectFilled(ImVec2(0, 0), ImVec2(W, H), alpha(255, 255, 255, 255), wr);
        dl->AddRectFilled(ImVec2(0, 0), ImVec2(W, top_h), alpha(236, 236, 238, 255), wr, ImDrawFlags_RoundCornersTop);
        dl->AddLine(ImVec2(0, top_h - 0.5f), ImVec2(W, top_h - 0.5f), alpha(214, 214, 218, 255), 1.0f);
        dl->AddRect(ImVec2(0.5f, 0.5f), ImVec2(W - 0.5f, H - 0.5f), alpha(0, 0, 0, 60), wr, 0, 1.0f);   // the edge line
    }

    // ---- title bar: traffic lights, title ----
    {
        const float r = 7.5f * s, gap = 24.0f * s;   // same discs as the main window
        const ImVec2 pos(18.0f * s, top_h * 0.5f);
        const ImU32 cols[3] = { alpha(255, 95, 87, 255), alpha(254, 188, 46, 255), alpha(40, 200, 64, 255) };
        const ImU32 rims[3] = { alpha(225, 70, 62, 255), alpha(222, 160, 30, 255), alpha(30, 170, 50, 255) };
        ImGui::SetCursorScreenPos(ImVec2(pos.x - r - 4 * s, pos.y - r - 4 * s));
        ImGui::InvisibleButton("##lights", ImVec2(gap * 2 + r * 2 + 8 * s, r * 2 + 8 * s));
        const bool group_hover = ImGui::IsItemHovered();
        const ImVec2 mouse = ImGui::GetMousePos();
        for (int i = 0; i < 3; ++i) {
            ImVec2 c(pos.x + i * gap, pos.y);
            dl->AddCircleFilled(c, r, cols[i], 24);
            dl->AddCircle(c, r, rims[i], 24, 1.0f);
            if (group_hover) {
                const float k = r * 0.42f;
                if (i == 0) {
                    dl->AddLine(ImVec2(c.x - k, c.y - k), ImVec2(c.x + k, c.y + k), alpha(70, 20, 15, 200), 1.3f * s);
                    dl->AddLine(ImVec2(c.x - k, c.y + k), ImVec2(c.x + k, c.y - k), alpha(70, 20, 15, 200), 1.3f * s);
                } else if (i == 1) {
                    dl->AddLine(ImVec2(c.x - k, c.y), ImVec2(c.x + k, c.y), alpha(120, 80, 10, 220), 1.3f * s);
                } else {
                    const ImU32 gg = alpha(10, 80, 20, 220);
                    dl->AddTriangleFilled(ImVec2(c.x - k, c.y + k * 0.2f), ImVec2(c.x - k, c.y - k), ImVec2(c.x + k * 0.2f, c.y - k), gg);
                    dl->AddTriangleFilled(ImVec2(c.x + k, c.y - k * 0.2f), ImVec2(c.x + k, c.y + k), ImVec2(c.x - k * 0.2f, c.y + k), gg);
                }
            }
            const bool over = std::fabs(mouse.x - c.x) <= r + 2 && std::fabs(mouse.y - c.y) <= r + 2;
            if (over && a >= 0.5f && ImGui::IsMouseClicked(ImGuiMouseButton_Left)) {
                if (i == 0) requestClose("close dot");
                else if (i == 1) SDL_MinimizeWindow(window_);
                else if (SDL_GetWindowFlags(window_) & SDL_WINDOW_MAXIMIZED) SDL_RestoreWindow(window_);
                else SDL_MaximizeWindow(window_);
            }
        }
        // "rPlayHub — <title>" after the lights, like the Mac's
        const float title_px = 15.0f * s;
        const std::string full = "rPlayHub \u2014 " + title_;
        ImVec2 sz = ui_font_bold_->CalcTextSizeA(title_px, FLT_MAX, 0.0f, full.c_str());
        dl->AddText(ui_font_bold_, title_px, ImVec2(84.0f * s, (top_h - sz.y) * 0.5f),
                    alpha(50, 50, 54, 255), full.c_str());
    }

    // ---- stage: the picture, easing from the whole window into the chassis ----
    // Chassis after the Mac's: bezel 4.5 % of the screen width, corner radii 16 % outside and
    // 12 % inside, a camera hole 4 % wide, spanning 90 % of the window between the bars.
    // Desktop Mode / app windows just fit under the title bar.
    if (texture_ && have_frame_) {
        // The phone in its box, the same in both modes: nothing ever moves.
        float px, py, pw, ph;
        const float bW = framed_ ? static_cast<float>(bare_w_) : W, bH = framed_ ? static_cast<float>(bare_h_) : H;
        barePicture(bW, bH, px, py, pw, ph);
        if (framed_) { px += grow_dx_; py += grow_dy_; }
        ImVec2 uv0, uv1;                                // drop the frame's edge texels
        VideoUvInset(tex_w_, tex_h_, uv0, uv1);
        if (isPhone()) {
            // The chassis is there in both modes, like the Mac's (doc/mirror-and-youtube.png)
            const float bezel = kBezel * pw;
            dl->AddRectFilled(ImVec2(px - bezel, py - bezel), ImVec2(px + pw + bezel, py + ph + bezel),
                              IM_COL32(6, 6, 8, 255), 0.16f * pw);
            DrawImageTurned(dl, (ImTextureID)(intptr_t)texture_, ImVec2(px, py), ImVec2(px + pw, py + ph), turn_,
                                   IM_COL32_WHITE, 0.12f * std::min(pw, ph), uv0, uv1);
            dl->AddCircleFilled(ImVec2(px + pw * 0.5f, py + 0.07f * pw), 0.041f * pw, IM_COL32(0, 0, 0, 255), 32);
        } else {
            dl->AddRectFilled(ImVec2(px, py), ImVec2(px + pw, py + ph), IM_COL32(0, 0, 0, 255));
            DrawImageTurned(dl, (ImTextureID)(intptr_t)texture_, ImVec2(px, py), ImVec2(px + pw, py + ph), turn_,
                                   IM_COL32_WHITE, 0.0f, uv0, uv1);
        }
        image_rect_ = { static_cast<int>(px), static_cast<int>(py), static_cast<int>(pw), static_cast<int>(ph) };
    }

    // ---- control strip (the phone's window only) ----
    if (isPhone()) {
        const float y0 = H - strip_h;
        dl->AddLine(ImVec2(0, y0 + 0.5f), ImVec2(W, y0 + 0.5f), alpha(230, 230, 235, 255), 1.0f);
        struct Btn { const char* id; void (*icon)(ImDrawList*, ImVec2, float, ImU32); const char* tip; ChromeAction act; };
        const Btn btns[] = {
            { "##Back", Icons::drawBack, "Back", ChromeAction::Back },
            { "##Home", Icons::drawHome, "Home", ChromeAction::Home },
            { "##Recents", Icons::drawRecents, "Overview / Recents", ChromeAction::Recents },
            { "##VolDown", Icons::drawVolumeDown, "Volume Down", ChromeAction::VolumeDown },
            { "##VolUp", Icons::drawVolumeUp, "Volume Up", ChromeAction::VolumeUp },
            { "##Power", Icons::drawPower, "Power Button", ChromeAction::Power },
            { "##Rotate", Icons::drawRotate, "Rotate Screen", ChromeAction::Rotate },
            { "##Camera", Icons::drawCamera, "Take Screenshot", ChromeAction::Screenshot },
            { "##Record", Icons::drawRecord, "Record Screen", ChromeAction::Record },
        };
        const int n = static_cast<int>(sizeof(btns) / sizeof(btns[0]));
        const float btn_w = 46.0f * s, btn_h = 42.0f * s;
        float spacing = 54.0f * s;
        if ((n - 1) * spacing + btn_w > W - 16.0f * s) spacing = std::max(btn_w, (W - 16.0f * s - btn_w) / (n - 1));
        const float x0 = (W - (n - 1) * spacing - btn_w) * 0.5f;
        const bool recording = chrome_.recording && chrome_.recording();
        for (int i = 0; i < n; ++i) {
            const ImVec2 p(x0 + i * spacing, y0 + (strip_h - btn_h) * 0.5f);
            ImGui::SetCursorScreenPos(p);
            const bool clicked = ImGui::InvisibleButton(btns[i].id, ImVec2(btn_w, btn_h));
            const bool hovered = ImGui::IsItemHovered();
            const bool active = ImGui::IsItemActive();
            if (active) dl->AddRectFilled(p, ImVec2(p.x + btn_w, p.y + btn_h), alpha(220, 220, 225, 255), 7.0f * s);
            else if (hovered) dl->AddRectFilled(p, ImVec2(p.x + btn_w, p.y + btn_h), alpha(236, 236, 240, 230), 7.0f * s);
            const ImU32 col = active ? alpha(0, 122, 255, 255) : hovered ? alpha(28, 28, 30, 255) : alpha(142, 142, 147, 255);
            const float icon = std::min(btn_w, btn_h) * 0.65f;
            const ImVec2 ip(p.x + (btn_w - icon) * 0.5f, p.y + (btn_h - icon) * 0.5f);
            if (btns[i].act == ChromeAction::Record && recording) {
                dl->AddCircleFilled(ImVec2(p.x + btn_w * 0.5f, p.y + btn_h * 0.5f), 6.0f * s, alpha(255, 59, 48, 255));
                if (hovered) ImGui::SetTooltip("Stop Recording");
            } else {
                btns[i].icon(dl, ip, icon, col);
                if (hovered) ImGui::SetTooltip("%s", btns[i].tip);
            }
            if (clicked && a >= 0.5f && chrome_.on_action) chrome_.on_action(btns[i].act);
        }
    }
    ImGui::End();
    ImGui::PopStyleVar();

    ImGui::Render();
    ImGui_ImplSDLRenderer2_RenderDrawData(ImGui::GetDrawData(), renderer_);
    SDL_RenderSetClipRect(renderer_, nullptr);
    ImGui::SetCurrentContext(prev);
}

bool DisplayWindow::saveScreenshotBmp(const std::string& path) {
    if (!renderer_) return false;
    int w = 0, h = 0;
    SDL_GetRendererOutputSize(renderer_, &w, &h);
    SDL_Surface* s = SDL_CreateRGBSurfaceWithFormat(0, w, h, 32, SDL_PIXELFORMAT_ARGB8888);
    if (!s) return false;
    bool ok = SDL_RenderReadPixels(renderer_, nullptr, SDL_PIXELFORMAT_ARGB8888, s->pixels, s->pitch) == 0 &&
              SDL_SaveBMP(s, path.c_str()) == 0;
    SDL_FreeSurface(s);
    return ok;
}

} // namespace rplayhub
