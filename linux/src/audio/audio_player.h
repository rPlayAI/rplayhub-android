#pragma once

// Device audio on the host's speakers. The agent (API 31+) encodes 48 kHz
// stereo Opus and writes each packet as a 4-byte little-endian header (sign
// bit = codec config packet, low 31 bits = payload size) followed by the
// payload. We decode with libavcodec's Opus decoder and queue PCM into an SDL
// audio device. If playback falls behind the stream (a stall, a sleep) the
// queue is dropped rather than letting latency grow.

#include "net/tcp_socket.h"
#include <SDL2/SDL.h>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct AVCodecContext;
struct AVFrame;
struct AVPacket;

namespace rplayhub {

class AudioPlayer {
public:
    explicit AudioPlayer(TCPSocket& socket);
    ~AudioPlayer();

    void start();                 // spawn the read/decode thread
    void setPlaying(bool on);     // false = decode but discard (audio forwarding off)
    void stop();                  // join; the socket is closed by the session

    uint64_t packetsReceived() const { return packets_.load(); }
    uint64_t packetsDropped() const { return dropped_.load(); }
    float peakDb() const { return peak_db_.load(); }
    std::string lastError() const;

private:
    void readLoop();
    bool configure(const std::vector<uint8_t>& config);
    void decodeAndQueue(const uint8_t* data, size_t size);
    void closeDecoder();

    TCPSocket& socket_;
    std::thread thread_;
    std::atomic<bool> stopping_{false};
    std::atomic<bool> playing_{true};
    std::atomic<uint64_t> packets_{0};
    std::atomic<uint64_t> dropped_{0};
    std::atomic<float> peak_db_{-120.0f};

    SDL_AudioDeviceID device_ = 0;
    AVCodecContext* codec_ctx_ = nullptr;
    AVFrame* frame_ = nullptr;
    AVPacket* pkt_ = nullptr;
    std::vector<float> interleaved_;

    mutable std::mutex error_mutex_;
    std::string error_;
};

} // namespace rplayhub
