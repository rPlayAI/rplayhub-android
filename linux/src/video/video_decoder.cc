#include "video_decoder.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libavutil/imgutils.h>
}

#include <iostream>

namespace rplayhub {

VideoDecoder::VideoDecoder() = default;

VideoDecoder::~VideoDecoder() {
    close();
}

void VideoDecoder::close() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (sws_ctx_) {
        sws_freeContext(sws_ctx_);
        sws_ctx_ = nullptr;
    }
    if (av_frame_) {
        av_frame_free(&av_frame_);
    }
    if (av_pkt_) {
        av_packet_free(&av_pkt_);
    }
    if (codec_ctx_) {
        avcodec_free_context(&codec_ctx_);
    }
    has_new_frame_ = false;
    has_any_frame_ = false;
}

bool VideoDecoder::init(const std::string& codec_name) {
    close();

    AVCodecID id = AV_CODEC_ID_H264;
    if (codec_name == "hevc" || codec_name == "h265") id = AV_CODEC_ID_HEVC;
    else if (codec_name == "vp8") id = AV_CODEC_ID_VP8;
    else if (codec_name == "vp9") id = AV_CODEC_ID_VP9;

    const AVCodec* codec = avcodec_find_decoder(id);
    if (!codec) {
        std::cerr << "VideoDecoder: Decoder not found for " << codec_name << "\n";
        return false;
    }

    codec_ctx_ = avcodec_alloc_context3(codec);
    if (!codec_ctx_) return false;

    // Enable low latency
    codec_ctx_->flags |= AV_CODEC_FLAG_LOW_DELAY;
    codec_ctx_->flags2 |= AV_CODEC_FLAG2_FAST;

    if (avcodec_open2(codec_ctx_, codec, nullptr) < 0) {
        avcodec_free_context(&codec_ctx_);
        return false;
    }

    av_frame_ = av_frame_alloc();
    av_pkt_ = av_packet_alloc();

    return true;
}

void VideoDecoder::updateSws(int src_w, int src_h, int src_fmt) {
    if (sws_ctx_ && sws_src_w_ == src_w && sws_src_h_ == src_h && sws_src_format_ == src_fmt) {
        return;
    }
    if (sws_ctx_) {
        sws_freeContext(sws_ctx_);
        sws_ctx_ = nullptr;
    }
    sws_src_w_ = src_w;
    sws_src_h_ = src_h;
    sws_src_format_ = src_fmt;
    sws_ctx_ = sws_getContext(
        src_w, src_h, static_cast<AVPixelFormat>(src_fmt),
        src_w, src_h, AV_PIX_FMT_RGBA,
        SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
}

bool VideoDecoder::decode(const uint8_t* payload, size_t size, const VideoPacketHeader& header) {
    if (!codec_ctx_ || !av_pkt_ || !av_frame_) return false;

    av_pkt_->data = const_cast<uint8_t*>(payload);
    av_pkt_->size = static_cast<int>(size);
    av_pkt_->pts = header.presentationTimestampUs;
    av_pkt_->dts = header.originationTimestampUs;

    int ret = avcodec_send_packet(codec_ctx_, av_pkt_);
    av_packet_unref(av_pkt_);
    if (ret < 0) {
        return false;
    }

    while (ret >= 0) {
        ret = avcodec_receive_frame(codec_ctx_, av_frame_);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            break;
        } else if (ret < 0) {
            return false;
        }

        int frame_w = av_frame_->width;
        int frame_h = av_frame_->height;
        if (frame_w <= 0 || frame_h <= 0) continue;

        updateSws(frame_w, frame_h, av_frame_->format);
        if (!sws_ctx_) continue;

        {
            std::lock_guard<std::mutex> lock(mutex_);
            latest_frame_.width = frame_w;
            latest_frame_.height = frame_h;
            latest_frame_.displayWidth = header.displayWidth;
            latest_frame_.displayHeight = header.displayHeight;
            latest_frame_.displayOrientation = header.displayOrientation;
            latest_frame_.displayOrientationCorrection = header.displayOrientationCorrection;
            latest_frame_.frameNumber = header.frameNumber;

            size_t num_pixels = static_cast<size_t>(frame_w * frame_h);
            // Add 128 bytes safety padding for sws_scale SIMD stores to prevent glibc heap corruption
            latest_frame_.rgba.resize(num_pixels * 4 + 128);

            uint8_t* dst_data[4] = { latest_frame_.rgba.data(), nullptr, nullptr, nullptr };
            int dst_linesize[4] = { frame_w * 4, 0, 0, 0 };

            sws_scale(sws_ctx_, av_frame_->data, av_frame_->linesize, 0, frame_h,
                      dst_data, dst_linesize);

            has_new_frame_ = true;
            has_any_frame_ = true;
        }
        frames_decoded_.fetch_add(1, std::memory_order_relaxed);
    }

    return true;
}

bool VideoDecoder::getLatestFrame(DecodedFrame& out_frame, bool only_if_new) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!has_any_frame_) return false;
    if (only_if_new && !has_new_frame_) return false;

    out_frame = latest_frame_;
    has_new_frame_ = false;
    return true;
}

bool VideoDecoder::hasFrame() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return has_any_frame_;
}

} // namespace rplayhub
