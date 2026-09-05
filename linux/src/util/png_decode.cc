#include "png_decode.h"
#include <cstring>
#include <algorithm>
#include <vector>
#include <utility>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libavutil/pixdesc.h>
}

namespace rplayhub {

RgbaImage decodePngToRgba(const uint8_t* data, size_t size) {
    RgbaImage out;
    if (!data || size == 0) return out;

    // PNG, or JPEG (FF D8): some "png" artwork in the repo is JPEG data.
    bool jpeg = size >= 2 && data[0] == 0xFF && data[1] == 0xD8;
    const AVCodec* codec = avcodec_find_decoder(jpeg ? AV_CODEC_ID_MJPEG : AV_CODEC_ID_PNG);
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
        // A source without alpha (JPEG, RGB PNG) leaves the alpha channel unspecified: make it opaque.
        const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(static_cast<AVPixelFormat>(frame->format));
        if (!desc || !(desc->flags & AV_PIX_FMT_FLAG_ALPHA)) {
            for (size_t i = 3; i < out.rgba.size(); i += 4) out.rgba[i] = 255;
        }
    } while (false);

    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&ctx);
    return out;
}

void removeLightBackground(RgbaImage& img) {
    if (!img.valid()) return;
    const int w = img.width, h = img.height;
    uint8_t* buf = img.rgba.data();
    for (auto [x, y] : { std::pair<int, int>{0, 0}, {w - 1, 0}, {0, h - 1}, {w - 1, h - 1} }) {
        if (buf[(y * w + x) * 4 + 3] < 16) return;   // authored with a cutout already
    }
    const int edge = 105, solid = 185;
    auto lum = [&](int p) { int i = p * 4; return (buf[i] + buf[i + 1] + buf[i + 2]) / 3; };
    auto alpha_for = [&](int l) -> uint8_t {
        if (l >= solid) return 0;
        return static_cast<uint8_t>(std::max(0, std::min(255, 255 * (solid - l) / (solid - edge))));
    };
    std::vector<uint8_t> visited(static_cast<size_t>(w) * h, 0);
    std::vector<int> stack;
    auto consider = [&](int p) {
        if (visited[p]) return;
        int l = lum(p);
        if (l <= edge) return;      // hit the body; stop, keep it opaque
        visited[p] = 1;
        buf[p * 4 + 3] = alpha_for(l);
        stack.push_back(p);
    };
    for (int x = 0; x < w; ++x) { consider(x); consider((h - 1) * w + x); }
    for (int y = 0; y < h; ++y) { consider(y * w); consider(y * w + w - 1); }
    while (!stack.empty()) {
        int p = stack.back(); stack.pop_back();
        int x = p % w, y = p / w;
        if (x > 0) consider(p - 1);
        if (x < w - 1) consider(p + 1);
        if (y > 0) consider(p - w);
        if (y < h - 1) consider(p + w);
    }
}

} // namespace rplayhub
