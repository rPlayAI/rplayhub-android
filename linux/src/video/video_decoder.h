#pragma once

#include "protocol/video_packet.h"
#include <vector>
#include <mutex>
#include <atomic>
#include <string>
#include <memory>
#include <cstdint>

struct AVCodecContext;
struct AVFrame;
struct AVPacket;
struct SwsContext;

namespace rplayhub {

struct DecodedFrame {
    int width = 0;
    int height = 0;
    int displayWidth = 0;
    int displayHeight = 0;
    int displayOrientation = 0;
    int displayOrientationCorrection = 0;
    std::vector<uint8_t> rgba; // RGBA32 pixels
    uint32_t frameNumber = 0;
};

class VideoDecoder {
public:
    VideoDecoder();
    ~VideoDecoder();

    bool init(const std::string& codec_name = "h264");
    void close();

    // Feed a packet (header + payload)
    bool decode(const uint8_t* payload, size_t size, const VideoPacketHeader& header);

    // Retrieve the newest frame if available (thread-safe)
    bool getLatestFrame(DecodedFrame& out_frame, bool only_if_new = false);

    bool hasFrame() const;

    // Total frames decoded since init(); for --stats.
    uint64_t framesDecoded() const { return frames_decoded_.load(std::memory_order_relaxed); }

private:
    AVCodecContext* codec_ctx_ = nullptr;
    AVFrame* av_frame_ = nullptr;
    AVPacket* av_pkt_ = nullptr;
    SwsContext* sws_ctx_ = nullptr;
    int sws_src_w_ = 0;
    int sws_src_h_ = 0;
    int sws_src_format_ = -1;

    mutable std::mutex mutex_;
    DecodedFrame latest_frame_;
    bool has_new_frame_ = false;
    bool has_any_frame_ = false;
    std::atomic<uint64_t> frames_decoded_{0};

    void updateSws(int src_w, int src_h, int src_fmt);
};

} // namespace rplayhub
