#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace rplayhub {

struct RgbaImage {
    int width = 0;
    int height = 0;
    std::vector<uint8_t> rgba;   // width * height * 4
    bool valid() const { return width > 0 && height > 0 && !rgba.empty(); }
};

// Decode a PNG or JPEG to straight RGBA using the FFmpeg we already link;
// no extra image library.
RgbaImage decodePngToRgba(const uint8_t* data, size_t size);

// Clear a light photo backdrop to transparent: a flood fill from the borders through
// everything lighter than the phone, with alpha ramping through the anti-aliased rim, so a
// white flash inside the phone survives. No-op when a corner is already transparent.
void removeLightBackground(RgbaImage& img);

} // namespace rplayhub
