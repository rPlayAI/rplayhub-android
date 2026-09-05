#pragma once

// Host-side screen recording: the agent's H.264 / HEVC packets are written
// into an .mp4 as they arrive, no re-encode, so it costs nothing on the CPU
// and has no length cap. Writing begins at the first keyframe after start()
// (the agent emits one every 10 s while the screen changes); the codec config
// packet (SPS/PPS) is kept and prepended to every keyframe so the file is
// self-describing and seekable.

#include "protocol/video_packet.h"
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

struct AVFormatContext;
struct AVStream;

namespace rplayhub {

class StreamRecorder {
public:
    StreamRecorder() = default;
    ~StreamRecorder();

    // codec_name is what the agent reported ("h264", "hevc"). Returns false and
    // sets error() if the file cannot be opened.
    bool start(const std::string& path, const std::string& codec_name, int width, int height, int32_t display_id = 0);

    // Called from the video read loop for every packet, config packets included.
    void write(const uint8_t* data, size_t size, const VideoPacketHeader& header);

    // Finalise the file. Returns false if nothing was written (the file is removed).
    bool stop();

    bool isRecording() const;
    bool hasStarted() const;        // a keyframe has been seen; frames are going to disk
    uint64_t framesWritten() const;
    double seconds() const;         // recorded duration so far
    std::string path() const;
    std::string error() const;

private:
    bool isKeyframe(const uint8_t* data, size_t size) const;
    void closeFile(bool keep);

    mutable std::mutex mutex_;
    AVFormatContext* fmt_ = nullptr;
    AVStream* stream_ = nullptr;
    bool header_written_ = false;
    bool hevc_ = false;
    std::vector<uint8_t> config_;   // latest SPS/PPS (Annex-B)
    std::vector<uint8_t> scratch_;
    int32_t display_id_ = 0;        // packets of other displays share the channel; skip them
    int64_t first_pts_ = -1;
    int64_t last_pts_ = 0;
    uint64_t frames_ = 0;
    std::string path_;
    std::string error_;
};

} // namespace rplayhub
