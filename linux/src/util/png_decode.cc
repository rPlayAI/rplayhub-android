#include "png_decode.h"
#include <cstring>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
}

namespace rplayhub {

RgbaImage decodePngToRgba(const uint8_t* data, size_t size) {
    RgbaImage out;
    if (!data || size == 0) return out;

    const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_PNG);
    if (!codec) return out;
    AVCodecContext* ctx = avcodec_alloc_context3(codec);
    if (!ctx) return out;
    AVPacket* pkt = av_packet_alloc();
    AVFrame* frame = av_frame_alloc();

    do {
        if (avcodec_open2(ctx, codec, nullptr) < 0) break;
        if (av_new_packet(pkt, static_cast<int>(size)) < 0) break;
        memcpy(pkt->data, data, size);
        if (avcodec_send_packet(ctx, pkt) < 0) break;
        if (avcodec_receive_frame(ctx, frame) < 0) break;
        if (frame->width <= 0 || frame->height <= 0) break;

        SwsContext* sws = sws_getContext(frame->width, frame->height, static_cast<AVPixelFormat>(frame->format),
                                         frame->width, frame->height, AV_PIX_FMT_RGBA,
                                         SWS_BILINEAR, nullptr, nullptr, nullptr);
        if (!sws) break;
        out.width = frame->width;
        out.height = frame->height;
        out.rgba.resize(static_cast<size_t>(out.width) * out.height * 4 + 64);
        uint8_t* dst[4] = { out.rgba.data(), nullptr, nullptr, nullptr };
        int dst_linesize[4] = { out.width * 4, 0, 0, 0 };
        sws_scale(sws, frame->data, frame->linesize, 0, frame->height, dst, dst_linesize);
        sws_freeContext(sws);
        out.rgba.resize(static_cast<size_t>(out.width) * out.height * 4);
    } while (false);

    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&ctx);
    return out;
}

} // namespace rplayhub
