#pragma once

#include <SDL2/SDL.h>
#include <string>

namespace rplayhub {

// Returns the X11 Visual ID (in decimal string) for a 32-bit ARGB TrueColor visual
// supporting GLX rendering and an 8-bit alpha channel. Returns "" if unavailable or not on X11.
std::string argbVisualId();

// Cuts the four corners of a window to a smooth, anti-aliased circular arc with radius r.
// Pixels outside the radius are zeroed out (alpha = 0); boundary pixels are scaled by coverage.
// Only effective when the window has an ARGB visual with an alpha channel.
void cutCorners(SDL_Renderer* renderer, int out_w, int out_h, float r);

} // namespace rplayhub
