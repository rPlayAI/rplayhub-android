#include "ui/gui_app.h"
#include "session/agent_session.h"
#include <cstdlib>
#include <iostream>
#include <string>

int main(int argc, char* argv[]) {
    bool auto_mirror = false;
    float user_scale = 0.0f;
    std::string dump_path;
    std::string serial;
    bool stats = false;
    rplayhub::AgentSession::Options opts;
    if (const char* env = std::getenv("RPLAYHUB_DECODER")) opts.decoder = env;

    auto parse_size = [&](const std::string& v) -> bool {
        size_t x = v.find_first_of("xX,");
        if (x == std::string::npos) return false;
        try {
            opts.max_w = std::stoi(v.substr(0, x));
            opts.max_h = std::stoi(v.substr(x + 1));
        } catch (...) { return false; }
        return opts.max_w > 0 && opts.max_h > 0;
    };
    if (const char* env = std::getenv("RPLAYHUB_SERIAL")) serial = env;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-m" || arg == "--mirror" || arg == "--auto-mirror") {
            auto_mirror = true;
        } else if (arg == "--dump-frame" && i + 1 < argc) {
            dump_path = argv[++i];
        } else if ((arg == "-s" || arg == "--scale") && i + 1 < argc) {
            user_scale = std::stof(argv[++i]);
        } else if (arg == "--serial" && i + 1 < argc) {
            serial = argv[++i];
        } else if (arg == "--stats") {
            stats = true;
        } else if (arg == "--decoder" && i + 1 < argc) {
            opts.decoder = argv[++i];
        } else if (arg == "--codec" && i + 1 < argc) {
            opts.codec = argv[++i];
            if (opts.codec == "h264") opts.codec = "avc";
            if (opts.codec == "h265") opts.codec = "hevc";
            if (opts.codec != "avc" && opts.codec != "hevc" && opts.codec != "vp8" &&
                opts.codec != "vp9" && opts.codec != "av1") {
                std::cerr << "--codec: expected avc, hevc, vp8, vp9 or av1\n";
                return 2;
            }
        } else if (arg == "--max-size" && i + 1 < argc) {
            if (!parse_size(argv[++i])) {
                std::cerr << "--max-size: expected WxH, e.g. 1080x2400\n";
                return 2;
            }
        } else if (arg == "-h" || arg == "--help") {
            std::cout << "Usage: rplayhub-android-linux [options]\n"
                         "  -m, --mirror          start mirroring immediately\n"
                         "      --serial <s>      device --mirror picks (default: first ready), or RPLAYHUB_SERIAL\n"
                         "  -s, --scale <f>       UI scale factor, or RPLAYHUB_SCALE\n"
                         "      --dump-frame <p>  save a BMP of the window once the mirror is up\n"
                         "      --stats           print decoded / rendered fps to stderr every 5 s\n"
                         "      --codec <c>       agent video codec: avc (default), hevc, vp8, vp9, av1\n"
                         "      --decoder <name>  FFmpeg decoder, e.g. h264_v4l2m2m (default: generic), or RPLAYHUB_DECODER\n"
                         "      --max-size WxH    agent frame size cap (default 1080x2400)\n";
            return 0;
        }
    }

    rplayhub::GuiApp app(auto_mirror, user_scale);
    if (!dump_path.empty()) {
        app.setDumpFrame(dump_path);
    }
    app.setPreferredSerial(serial);
    app.setStats(stats);
    app.setSessionOptions(opts);

    if (!app.init()) {
        std::cerr << "Failed to initialize rPlayHub Linux GUI\n";
        return 1;
    }

    std::cout << "Starting rPlayHub Android Linux GUI...\n";
    app.run();
    return 0;
}
