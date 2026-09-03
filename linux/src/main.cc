#include "ui/gui_app.h"
#include <iostream>
#include <string>

int main(int argc, char* argv[]) {
    bool auto_mirror = false;
    float user_scale = 0.0f;
    std::string dump_path;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-m" || arg == "--mirror" || arg == "--auto-mirror") {
            auto_mirror = true;
        } else if (arg == "--dump-frame" && i + 1 < argc) {
            dump_path = argv[++i];
        } else if ((arg == "-s" || arg == "--scale") && i + 1 < argc) {
            user_scale = std::stof(argv[++i]);
        }
    }

    rplayhub::GuiApp app(auto_mirror, user_scale);
    if (!dump_path.empty()) {
        app.setDumpFrame(dump_path);
    }

    if (!app.init()) {
        std::cerr << "Failed to initialize rPlayHub Linux GUI\n";
        return 1;
    }

    std::cout << "Starting rPlayHub Android Linux GUI...\n";
    app.run();
    return 0;
}
