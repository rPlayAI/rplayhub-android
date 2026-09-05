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

// Decode a PNG (or anything else libavcodec can sniff from a single packet)
// to straight RGBA using the FFmpeg we already link; no extra image library.
RgbaImage decodePngToRgba(const uint8_t* data, size_t size);

} // namespace rplayhub
