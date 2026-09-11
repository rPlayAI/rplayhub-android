#include "window_effects.h"

#include <algorithm>
#include <cmath>
#include <iostream>

#ifdef RPLAYHUB_HAVE_X11
#include <SDL2/SDL_syswm.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <GL/glx.h>
#endif

namespace rplayhub {

std::string argbVisualId() {
#ifdef RPLAYHUB_HAVE_X11
    const char* driver = SDL_GetCurrentVideoDriver();
    if (!driver || std::string(driver) != "x11") return "";
    Display* dpy = XOpenDisplay(nullptr);
    if (!dpy) return "";
    std::string id;
    XVisualInfo tmpl{};
    tmpl.screen = DefaultScreen(dpy);
    tmpl.depth = 32;
    tmpl.c_class = TrueColor;
    int n = 0;
    XVisualInfo* vis = XGetVisualInfo(dpy, VisualScreenMask | VisualDepthMask | VisualClassMask, &tmpl, &n);
    for (int i = 0; i < n && id.empty(); ++i) {
        int use_gl = 0, rgba = 0, dbl = 0, alpha = 0;
        if (glXGetConfig(dpy, &vis[i], GLX_USE_GL, &use_gl) == 0 && use_gl &&
            glXGetConfig(dpy, &vis[i], GLX_RGBA, &rgba) == 0 && rgba &&
            glXGetConfig(dpy, &vis[i], GLX_DOUBLEBUFFER, &dbl) == 0 && dbl &&
            glXGetConfig(dpy, &vis[i], GLX_ALPHA_SIZE, &alpha) == 0 && alpha >= 8) {
            id = std::to_string(vis[i].visualid);
        }
    }
    if (vis) XFree(vis);
    XCloseDisplay(dpy);
    return id;
#else
    return "";
#endif
}

void cutCorners(SDL_Renderer* renderer, int out_w, int out_h, float r) {
    const int ri = static_cast<int>(std::ceil(r));
    if (ri <= 0) return;
    static const SDL_BlendMode scale_by_alpha = SDL_ComposeCustomBlendMode(
        SDL_BLENDFACTOR_ZERO, SDL_BLENDFACTOR_SRC_ALPHA, SDL_BLENDOPERATION_ADD,
        SDL_BLENDFACTOR_ZERO, SDL_BLENDFACTOR_SRC_ALPHA, SDL_BLENDOPERATION_ADD);
    const bool aa = SDL_SetRenderDrawBlendMode(renderer, scale_by_alpha) == 0;
    if (!aa) SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_NONE);
    for (int i = 0; i < ri; ++i) {
        const float d = r - (i + 0.5f);
        const float xb = r - std::sqrt(std::max(0.0f, r * r - d * d));   // where the arc crosses this row
        const int full = static_cast<int>(std::floor(xb));
        const int y_top = i, y_bot = out_h - 1 - i;
        if (full > 0) {
            SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0);
            SDL_Rect rows[4] = { {0, y_top, full, 1}, {out_w - full, y_top, full, 1},
                                 {0, y_bot, full, 1}, {out_w - full, y_bot, full, 1} };
            SDL_RenderFillRects(renderer, rows, 4);
        }
        if (aa) {
            const float coverage = std::clamp(full + 1.0f - xb, 0.0f, 1.0f);
            const Uint8 a = static_cast<Uint8>(std::lround(coverage * 255.0f));
            SDL_SetRenderDrawColor(renderer, 0, 0, 0, a);
            SDL_Point pts[4] = { {full, y_top}, {out_w - 1 - full, y_top},
                                 {full, y_bot}, {out_w - 1 - full, y_bot} };
            SDL_RenderDrawPoints(renderer, pts, 4);
        }
    }
    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_NONE);
}

} // namespace rplayhub
