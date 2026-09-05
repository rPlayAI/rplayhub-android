#include "display_window.h"
#include "protocol/control_messages.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>

namespace rplayhub {

DisplayWindow::DisplayWindow(int32_t display_id, const std::string& title, int width, int height, bool decorated)
    : display_id_(display_id), decorated_(decorated) {
    window_ = SDL_CreateWindow(title.c_str(), SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                               width, height, SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
    if (!window_) {
        std::cerr << "DisplayWindow: SDL_CreateWindow: " << SDL_GetError() << "\n";
        return;
    }
    renderer_ = SDL_CreateRenderer(window_, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!renderer_) renderer_ = SDL_CreateRenderer(window_, -1, 0);
    if (!renderer_) {
        std::cerr << "DisplayWindow: SDL_CreateRenderer: " << SDL_GetError() << "\n";
        SDL_DestroyWindow(window_);
        window_ = nullptr;
    }
}

DisplayWindow::~DisplayWindow() {
    if (texture_) SDL_DestroyTexture(texture_);
    if (renderer_) SDL_DestroyRenderer(renderer_);
    if (window_) SDL_DestroyWindow(window_);
}

void DisplayWindow::setTitle(const std::string& title) {
    if (window_) SDL_SetWindowTitle(window_, title.c_str());
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
    switch (e.type) {
    case SDL_WINDOWEVENT:
        if (e.window.windowID != id) return false;
        if (e.window.event == SDL_WINDOWEVENT_CLOSE) close_requested_ = true;
        return true;
    case SDL_MOUSEBUTTONDOWN:
    case SDL_MOUSEBUTTONUP: {
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
            tex_w_ = frame.width;
            tex_h_ = frame.height;
            tex_format_ = frame.format;
            uploaded_frame_ = 0;
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
        disp_rot_ = frame.displayOrientation;
    }

    int out_w = 0, out_h = 0;
    SDL_GetRendererOutputSize(renderer_, &out_w, &out_h);
    SDL_SetRenderDrawColor(renderer_, 0, 0, 0, 255);
    SDL_RenderClear(renderer_);
    if (texture_ && have_frame_ && out_w > 0 && out_h > 0) {
        float aspect = static_cast<float>(tex_w_) / static_cast<float>(tex_h_);
        int w = out_w, h = static_cast<int>(out_w / aspect);
        if (h > out_h) { h = out_h; w = static_cast<int>(out_h * aspect); }
        image_rect_ = { (out_w - w) / 2, (out_h - h) / 2, w, h };
        // Input arrives in window coordinates; the renderer may be high-DPI scaled.
        int win_w = 0, win_h = 0;
        SDL_GetWindowSize(window_, &win_w, &win_h);
        SDL_RenderCopy(renderer_, texture_, nullptr, &image_rect_);
        if (win_w > 0 && out_w != win_w) {
            float sx = static_cast<float>(win_w) / out_w, sy = static_cast<float>(win_h) / out_h;
            image_rect_ = { static_cast<int>(image_rect_.x * sx), static_cast<int>(image_rect_.y * sy),
                            static_cast<int>(image_rect_.w * sx), static_cast<int>(image_rect_.h * sy) };
        }
    }
    SDL_RenderPresent(renderer_);
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
