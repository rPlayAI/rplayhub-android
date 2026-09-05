#include "video_decoder.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
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
    logged_format_ = false;
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

        const int fmt = av_frame_->format;
        const bool is_i420 = (fmt == AV_PIX_FMT_YUV420P || fmt == AV_PIX_FMT_YUVJ420P);
        const bool is_nv12 = (fmt == AV_PIX_FMT_NV12);
        if (!is_i420 && !is_nv12) {
            updateSws(frame_w, frame_h, fmt);
            if (!sws_ctx_) continue;
        }

        {
            std::lock_guard<std::mutex> lock(mutex_);
            latest_frame_.width = frame_w;
            latest_frame_.height = frame_h;
            latest_frame_.displayWidth = header.displayWidth;
            latest_frame_.displayHeight = header.displayHeight;
            latest_frame_.displayOrientation = header.displayOrientation;
            latest_frame_.displayOrientationCorrection = header.displayOrientationCorrection;
            latest_frame_.frameNumber = header.frameNumber;

            // Copy one plane row by row: linesize may exceed the visible width.
            auto copy_plane = [&](int idx, int row_bytes, int rows) {
                auto& dst = latest_frame_.planes[idx];
                dst.resize(static_cast<size_t>(row_bytes) * rows);
                av_image_copy_plane(dst.data(), row_bytes,
                                    av_frame_->data[idx], av_frame_->linesize[idx],
                                    row_bytes, rows);
                latest_frame_.pitch[idx] = row_bytes;
            };

            if (is_i420 || is_nv12) {
                const int cw = (frame_w + 1) / 2;
                const int ch = (frame_h + 1) / 2;
                copy_plane(0, frame_w, frame_h);
                if (is_i420) {
                    copy_plane(1, cw, ch);
                    copy_plane(2, cw, ch);
                    latest_frame_.format = FrameFormat::I420;
                } else {
                    copy_plane(1, cw * 2, ch);
                    latest_frame_.planes[2].clear();
                    latest_frame_.pitch[2] = 0;
                    latest_frame_.format = FrameFormat::NV12;
                }
            } else {
                size_t num_pixels = static_cast<size_t>(frame_w) * frame_h;
                auto& rgba = latest_frame_.planes[0];
                // 128 bytes of slack for sws_scale's SIMD stores past the last row
                rgba.resize(num_pixels * 4 + 128);
                uint8_t* dst_data[4] = { rgba.data(), nullptr, nullptr, nullptr };
                int dst_linesize[4] = { frame_w * 4, 0, 0, 0 };
                sws_scale(sws_ctx_, av_frame_->data, av_frame_->linesize, 0, frame_h,
                          dst_data, dst_linesize);
                latest_frame_.pitch[0] = frame_w * 4;
                latest_frame_.planes[1].clear();
                latest_frame_.planes[2].clear();
                latest_frame_.pitch[1] = latest_frame_.pitch[2] = 0;
                latest_frame_.format = FrameFormat::RGBA;
            }

            if (!logged_format_) {
                logged_format_ = true;
                const char* name = av_get_pix_fmt_name(static_cast<AVPixelFormat>(fmt));
                std::cerr << "VideoDecoder: " << codec_ctx_->codec->name << " -> "
                          << (name ? name : "?") << " " << frame_w << "x" << frame_h
                          << ((is_i420 || is_nv12) ? " (planes uploaded to SDL)" : " (swscale -> RGBA)")
                          << "\n";
            }

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
