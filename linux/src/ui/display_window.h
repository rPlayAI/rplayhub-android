#pragma once

// A second SDL window showing one display of the phone: a virtual display
// (Desktop Mode, an app in a window of its own) or the phone's own screen
// popped out bare. It has its own renderer and texture, fits the picture to
// the window on black, and turns mouse and keyboard input into agent messages
// tagged with its display id. Dear ImGui is not involved: it is picture only.

#include "session/agent_session.h"
#include "video/video_decoder.h"
#include <SDL2/SDL.h>
#include <cstdint>
#include <string>

namespace rplayhub {

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
    void mapToDisplay(int mx, int my, int& dx, int& dy) const;

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
};

} // namespace rplayhub
