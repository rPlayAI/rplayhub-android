#include "audio_player.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
}

#include <cmath>
#include <cstring>
#include <iostream>

namespace rplayhub {

namespace {
constexpr int kSampleRate = 48000;
constexpr int kChannels = 2;
// Beyond this much queued audio we are behind the phone; drop and catch up.
constexpr Uint32 kMaxQueuedBytes = kSampleRate * kChannels * sizeof(float) * 3 / 10;   // 300 ms
} // namespace

AudioPlayer::AudioPlayer(TCPSocket& socket) : socket_(socket) {}

AudioPlayer::~AudioPlayer() {
    stop();
}

void AudioPlayer::start() {
    if (thread_.joinable()) return;
    stopping_.store(false);
    thread_ = std::thread(&AudioPlayer::readLoop, this);
}

void AudioPlayer::setPlaying(bool on) {
    playing_.store(on);
    if (device_) {
        if (!on) SDL_ClearQueuedAudio(device_);
        SDL_PauseAudioDevice(device_, on ? 0 : 1);
    }
}

void AudioPlayer::stop() {
    stopping_.store(true);
    if (thread_.joinable()) thread_.join();
    if (device_) {
        SDL_CloseAudioDevice(device_);
        device_ = 0;
    }
    closeDecoder();
}

std::string AudioPlayer::lastError() const {
    std::lock_guard<std::mutex> lock(error_mutex_);
    return error_;
}

void AudioPlayer::closeDecoder() {
    if (frame_) av_frame_free(&frame_);
    if (pkt_) av_packet_free(&pkt_);
    if (codec_ctx_) avcodec_free_context(&codec_ctx_);
}

// The config packet is the Opus identification header ("OpusHead"); libavcodec's decoder takes
// it as extradata, and decodes standard stereo without it too.
bool AudioPlayer::configure(const std::vector<uint8_t>& config) {
    closeDecoder();
    const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_OPUS);
    if (!codec) {
        std::lock_guard<std::mutex> lock(error_mutex_);
        error_ = "no Opus decoder in this FFmpeg";
        return false;
    }
    codec_ctx_ = avcodec_alloc_context3(codec);
    codec_ctx_->sample_rate = kSampleRate;
    av_channel_layout_default(&codec_ctx_->ch_layout, kChannels);
    if (config.size() >= 8 && memcmp(config.data(), "OpusHead", 8) == 0) {
        codec_ctx_->extradata = static_cast<uint8_t*>(av_mallocz(config.size() + AV_INPUT_BUFFER_PADDING_SIZE));
        memcpy(codec_ctx_->extradata, config.data(), config.size());
        codec_ctx_->extradata_size = static_cast<int>(config.size());
    }
    if (avcodec_open2(codec_ctx_, codec, nullptr) < 0) {
        std::lock_guard<std::mutex> lock(error_mutex_);
        error_ = "Opus decoder failed to open";
        avcodec_free_context(&codec_ctx_);
        return false;
    }
    frame_ = av_frame_alloc();
    pkt_ = av_packet_alloc();

    if (!device_) {
        SDL_AudioSpec want{}, have{};
        want.freq = kSampleRate;
        want.format = AUDIO_F32SYS;
        want.channels = kChannels;
        want.samples = 1024;
        device_ = SDL_OpenAudioDevice(nullptr, 0, &want, &have, 0);
        if (!device_) {
            std::lock_guard<std::mutex> lock(error_mutex_);
            error_ = std::string("SDL audio: ") + SDL_GetError();
            std::cerr << "AudioPlayer: " << error_ << "\n";
            return false;
        }
        SDL_PauseAudioDevice(device_, playing_.load() ? 0 : 1);
        std::cerr << "AudioPlayer: Opus decoder ready, output " << have.freq << " Hz "
                  << static_cast<int>(have.channels) << " ch via SDL " << SDL_GetCurrentAudioDriver() << "\n";
    }
    return true;
}

void AudioPlayer::decodeAndQueue(const uint8_t* data, size_t size) {
    if (!codec_ctx_) {
        // No config packet seen (older agent build): standard stereo works without it.
        if (!configure({})) return;
    }
    if (av_new_packet(pkt_, static_cast<int>(size)) < 0) return;
    memcpy(pkt_->data, data, size);
    int rc = avcodec_send_packet(codec_ctx_, pkt_);
    av_packet_unref(pkt_);
    if (rc < 0) return;

    while (avcodec_receive_frame(codec_ctx_, frame_) >= 0) {
        const int n = frame_->nb_samples;
        const int ch = frame_->ch_layout.nb_channels;
        interleaved_.resize(static_cast<size_t>(n) * kChannels);
        float peak = 0.0f;
        if (frame_->format == AV_SAMPLE_FMT_FLTP) {
            for (int i = 0; i < n; ++i) {
                for (int c = 0; c < kChannels; ++c) {
                    float v = reinterpret_cast<const float*>(frame_->data[std::min(c, ch - 1)])[i];
                    interleaved_[static_cast<size_t>(i) * kChannels + c] = v;
                    peak = std::max(peak, std::fabs(v));
                }
            }
        } else if (frame_->format == AV_SAMPLE_FMT_FLT) {
            const float* src = reinterpret_cast<const float*>(frame_->data[0]);
            for (int i = 0; i < n; ++i) {
                for (int c = 0; c < kChannels; ++c) {
                    float v = src[i * ch + std::min(c, ch - 1)];
                    interleaved_[static_cast<size_t>(i) * kChannels + c] = v;
                    peak = std::max(peak, std::fabs(v));
                }
            }
        } else if (frame_->format == AV_SAMPLE_FMT_S16) {
            const int16_t* src = reinterpret_cast<const int16_t*>(frame_->data[0]);
            for (int i = 0; i < n; ++i) {
                for (int c = 0; c < kChannels; ++c) {
                    float v = src[i * ch + std::min(c, ch - 1)] / 32768.0f;
                    interleaved_[static_cast<size_t>(i) * kChannels + c] = v;
                    peak = std::max(peak, std::fabs(v));
                }
            }
        } else {
            continue;
        }
        peak_db_.store(peak > 1e-6f ? 20.0f * std::log10(peak) : -120.0f);

        if (!playing_.load() || !device_) continue;
        if (SDL_GetQueuedAudioSize(device_) > kMaxQueuedBytes) {
            SDL_ClearQueuedAudio(device_);
            dropped_.fetch_add(1);
        }
        SDL_QueueAudio(device_, interleaved_.data(), static_cast<Uint32>(interleaved_.size() * sizeof(float)));
    }
}

void AudioPlayer::readLoop() {
    std::vector<uint8_t> payload;
    while (!stopping_.load()) {
        uint8_t hdr[4];
        if (!socket_.readFully(hdr, 4)) break;
        uint32_t raw = hdr[0] | (hdr[1] << 8) | (hdr[2] << 16) | (static_cast<uint32_t>(hdr[3]) << 24);
        bool is_config = (raw & 0x80000000u) != 0;
        uint32_t size = raw & 0x7FFFFFFFu;
        if (size == 0) continue;
        if (size > (1u << 20)) {
            std::cerr << "AudioPlayer: implausible packet size " << size << "\n";
            break;
        }
        payload.resize(size);
        if (!socket_.readFully(payload.data(), size)) break;
        packets_.fetch_add(1);
        if (is_config) {
            configure(payload);
        } else {
            decodeAndQueue(payload.data(), size);
        }
    }
}

} // namespace rplayhub
