#pragma once

#include <cstdint>
#include <cstring>

namespace rplayhub {

struct VideoPacketHeader {
    static constexpr size_t HEADER_SIZE = 44;

    int32_t displayId = 0;
    int32_t displayWidth = 0;
    int32_t displayHeight = 0;
    uint8_t displayOrientation = 0;
    uint8_t displayOrientationCorrection = 0;
    int16_t flags = 0;
    int32_t bitRate = 0;
    uint32_t frameNumber = 0;
    int64_t originationTimestampUs = 0;
    int64_t presentationTimestampUs = 0;
    int32_t packetSize = 0;

    static constexpr int16_t FLAG_DISPLAY_ROUND = 0x01;
    static constexpr int16_t FLAG_BITRATE_REDUCED = 0x02;
    static constexpr int16_t FLAG_CAMERA = 0x04;

    bool isConfig() const { return presentationTimestampUs == 0; }
    bool isDisplayRound() const { return (flags & FLAG_DISPLAY_ROUND) != 0; }

    int presentedQuadrants() const {
        int raw = (displayOrientationCorrection % 2 == 0)
            ? (displayOrientation + displayOrientationCorrection)
            : displayOrientation;
        return ((raw % 4) + 4) % 4;
    }

    int rotatedDisplayWidth() const {
        return (presentedQuadrants() % 2 == 1) ? displayHeight : displayWidth;
    }

    int rotatedDisplayHeight() const {
        return (presentedQuadrants() % 2 == 1) ? displayWidth : displayHeight;
    }

    static bool parse(const uint8_t* data, size_t len, VideoPacketHeader& out_header) {
        if (len < HEADER_SIZE) return false;

        auto read_i32 = [data](size_t offset) -> int32_t {
            uint32_t u = static_cast<uint32_t>(data[offset]) |
                        (static_cast<uint32_t>(data[offset + 1]) << 8) |
                        (static_cast<uint32_t>(data[offset + 2]) << 16) |
                        (static_cast<uint32_t>(data[offset + 3]) << 24);
            return static_cast<int32_t>(u);
        };
        auto read_u32 = [data](size_t offset) -> uint32_t {
            return static_cast<uint32_t>(data[offset]) |
                  (static_cast<uint32_t>(data[offset + 1]) << 8) |
                  (static_cast<uint32_t>(data[offset + 2]) << 16) |
                  (static_cast<uint32_t>(data[offset + 3]) << 24);
        };
        auto read_i64 = [read_u32](size_t offset) -> int64_t {
            uint64_t low = read_u32(offset);
            uint64_t high = read_u32(offset + 4);
            return static_cast<int64_t>(low | (high << 32));
        };

        out_header.displayId = read_i32(0);
        out_header.displayWidth = read_i32(4);
        out_header.displayHeight = read_i32(8);
        out_header.displayOrientation = data[12];
        out_header.displayOrientationCorrection = data[13];
        out_header.flags = static_cast<int16_t>(data[14] | (data[15] << 8));
        out_header.bitRate = read_i32(16);
        out_header.frameNumber = read_u32(20);
        out_header.originationTimestampUs = read_i64(24);
        out_header.presentationTimestampUs = read_i64(32);
        out_header.packetSize = read_i32(40);
        return true;
    }
};

} // namespace rplayhub
