#include "stream_recorder.h"

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
}

#include <cstring>
#include <cstdlib>
#include <iostream>
#include <unistd.h>

namespace rplayhub {

namespace {
std::string averr(int rc) {
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(rc, buf, sizeof(buf));
    return buf;
}

// Walk Annex-B NAL units: calls fn(nal_header_byte) for each.
template <typename F>
void forEachNal(const uint8_t* data, size_t size, F fn) {
    size_t i = 0;
    while (i + 3 < size) {
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
            if (i + 3 < size) fn(data[i + 3]);
            i += 3;
        } else {
            ++i;
        }
    }
}
} // namespace

StreamRecorder::~StreamRecorder() {
    closeFile(frames_ > 0);
}

bool StreamRecorder::start(const std::string& path, const std::string& codec_name, int width, int height) {
    std::lock_guard<std::mutex> lock(mutex_);
    closeFile(frames_ > 0);
    error_.clear();
    path_ = path;
    hevc_ = (codec_name == "hevc" || codec_name == "h265");
    first_pts_ = -1;
    last_pts_ = 0;
    frames_ = 0;
    header_written_ = false;

    int rc = avformat_alloc_output_context2(&fmt_, nullptr, "mp4", path.c_str());
    if (rc < 0 || !fmt_) {
        error_ = "mp4 muxer: " + averr(rc);
        return false;
    }
    stream_ = avformat_new_stream(fmt_, nullptr);
    if (!stream_) {
        error_ = "cannot add stream";
        closeFile(false);
        return false;
    }
    AVCodecParameters* par = stream_->codecpar;
    par->codec_type = AVMEDIA_TYPE_VIDEO;
    par->codec_id = hevc_ ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264;
    par->width = width;
    par->height = height;
    stream_->time_base = AVRational{1, 1000000};

    rc = avio_open(&fmt_->pb, path.c_str(), AVIO_FLAG_WRITE);
    if (rc < 0) {
        error_ = "cannot write " + path + ": " + averr(rc);
        closeFile(false);
        return false;
    }
    return true;
}

bool StreamRecorder::isKeyframe(const uint8_t* data, size_t size) const {
    bool key = false;
    forEachNal(data, size, [&](uint8_t b) {
        if (hevc_) {
            int type = (b >> 1) & 0x3F;
            if (type >= 16 && type <= 21) key = true;   // IRAP
        } else {
            int type = b & 0x1F;
            if (type == 5) key = true;                  // IDR
        }
    });
    return key;
}

void StreamRecorder::write(const uint8_t* data, size_t size, const VideoPacketHeader& header) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!fmt_ || size == 0) return;

    if (header.isConfig()) {
        config_.assign(data, data + size);
        return;
    }

    bool key = isKeyframe(data, size);
    if (std::getenv("RPLAYHUB_NAL_DEBUG")) {
        std::cerr << "pkt " << size << "B pts=" << header.presentationTimestampUs << " nal:";
        forEachNal(data, size, [&](uint8_t b) { std::cerr << " " << (hevc_ ? ((b >> 1) & 0x3F) : (b & 0x1F)); });
        std::cerr << (key ? " KEY" : "") << "\n";
    }
    if (first_pts_ < 0) {
        if (!key) return;                  // wait for a point the decoder can start from
        first_pts_ = header.presentationTimestampUs;
        // Extradata from the config packet; the mov muxer turns Annex-B SPS/PPS into avcC/hvcC
        // and reformats the Annex-B samples to length-prefixed ones.
        if (!config_.empty()) {
            AVCodecParameters* par = stream_->codecpar;
            par->extradata = static_cast<uint8_t*>(av_mallocz(config_.size() + AV_INPUT_BUFFER_PADDING_SIZE));
            memcpy(par->extradata, config_.data(), config_.size());
            par->extradata_size = static_cast<int>(config_.size());
        }
        int rc = avformat_write_header(fmt_, nullptr);
        if (rc < 0) {
            error_ = "write header: " + averr(rc);
            std::cerr << "StreamRecorder: " << error_ << "\n";
            closeFile(false);
            return;
        }
        header_written_ = true;
    }

    // Keyframes carry SPS/PPS in front so the file is seekable and survives a stream restart.
    const uint8_t* payload = data;
    size_t payload_size = size;
    if (key && !config_.empty()) {
        scratch_.resize(config_.size() + size);
        memcpy(scratch_.data(), config_.data(), config_.size());
        memcpy(scratch_.data() + config_.size(), data, size);
        payload = scratch_.data();
        payload_size = scratch_.size();
    }

    AVPacket* pkt = av_packet_alloc();
    if (av_new_packet(pkt, static_cast<int>(payload_size)) < 0) { av_packet_free(&pkt); return; }
    memcpy(pkt->data, payload, payload_size);
    int64_t pts = header.presentationTimestampUs - first_pts_;
    if (pts < last_pts_) pts = last_pts_ + 1;      // keep the timeline monotonic
    last_pts_ = pts;
    pkt->pts = pkt->dts = pts;
    pkt->stream_index = stream_->index;
    pkt->flags = key ? AV_PKT_FLAG_KEY : 0;
    int rc = av_interleaved_write_frame(fmt_, pkt);
    av_packet_free(&pkt);
    if (rc < 0) {
        error_ = "write: " + averr(rc);
        std::cerr << "StreamRecorder: " << error_ << "\n";
        closeFile(false);
        return;
    }
    frames_++;
}

bool StreamRecorder::stop() {
    std::lock_guard<std::mutex> lock(mutex_);
    bool had_frames = frames_ > 0;
    closeFile(had_frames);
    return had_frames;
}

void StreamRecorder::closeFile(bool keep) {
    if (!fmt_) return;
    if (header_written_ && keep) av_write_trailer(fmt_);
    if (fmt_->pb) avio_closep(&fmt_->pb);
    avformat_free_context(fmt_);
    fmt_ = nullptr;
    stream_ = nullptr;
    header_written_ = false;
    if (!keep && !path_.empty()) unlink(path_.c_str());
}

bool StreamRecorder::isRecording() const { std::lock_guard<std::mutex> lock(mutex_); return fmt_ != nullptr; }
bool StreamRecorder::hasStarted() const { std::lock_guard<std::mutex> lock(mutex_); return fmt_ && first_pts_ >= 0; }
uint64_t StreamRecorder::framesWritten() const { std::lock_guard<std::mutex> lock(mutex_); return frames_; }
double StreamRecorder::seconds() const { std::lock_guard<std::mutex> lock(mutex_); return first_pts_ < 0 ? 0.0 : last_pts_ / 1e6; }
std::string StreamRecorder::path() const { std::lock_guard<std::mutex> lock(mutex_); return path_; }
std::string StreamRecorder::error() const { std::lock_guard<std::mutex> lock(mutex_); return error_; }

} // namespace rplayhub
