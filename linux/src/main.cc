#include "ui/gui_app.h"
#include <cstdlib>
#include <iostream>
#include <string>

int main(int argc, char* argv[]) {
    bool auto_mirror = false;
    float user_scale = 0.0f;
    std::string dump_path;
    std::string serial;
    bool stats = false;
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
        } else if (arg == "-h" || arg == "--help") {
            std::cout << "Usage: rplayhub-android-linux [options]\n"
                         "  -m, --mirror          start mirroring immediately\n"
                         "      --serial <s>      device --mirror picks (default: first ready), or RPLAYHUB_SERIAL\n"
                         "  -s, --scale <f>       UI scale factor, or RPLAYHUB_SCALE\n"
                         "      --dump-frame <p>  save a BMP of the window once the mirror is up\n"
                         "      --stats           print decoded / rendered fps to stderr every 5 s\n";
            return 0;
        }
    }

    rplayhub::GuiApp app(auto_mirror, user_scale);
    if (!dump_path.empty()) {
        app.setDumpFrame(dump_path);
    }
    app.setPreferredSerial(serial);
    app.setStats(stats);

    if (!app.init()) {
        std::cerr << "Failed to initialize rPlayHub Linux GUI\n";
        return 1;
    }

    std::cout << "Starting rPlayHub Android Linux GUI...\n";
    app.run();
    return 0;
}
