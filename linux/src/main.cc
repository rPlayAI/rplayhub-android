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
    int tab = -1;
    bool clipboard = true;
    bool desktop = false;
    bool pop_out = false;
    std::string app_package;
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
        } else if (arg == "-v" || arg == "--verbose") {
            rplayhub::AgentSession::setVerbose(true);
        } else if (arg == "--tab" && i + 1 < argc) {
            std::string t = argv[++i];
            tab = (t == "info") ? 0 : (t == "apps") ? 1 : (t == "files") ? 2 : (t == "logcat") ? 3 : -1;
            if (tab < 0) {
                std::cerr << "--tab: expected info, apps, files or logcat\n";
                return 2;
            }
        } else if (arg == "--no-audio") {
            opts.audio = false;
        } else if (arg == "--desktop") {
            desktop = true;
        } else if (arg == "--pop-out") {
            pop_out = true;
        } else if (arg == "--app" && i + 1 < argc) {
            app_package = argv[++i];
        } else if (arg == "--no-clipboard") {
            clipboard = false;
        } else if (arg == "--screen-off") {
            opts.turn_screen_off = true;
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
                         "  -v, --verbose         echo the device agent's log to stderr\n"
                         "      --tab <name>      inspector tab to open with: info, apps, files, logcat\n"
                         "      --no-audio        do not forward device audio (Android 12+ devices)\n"
                         "      --desktop         once mirroring, open Android's desktop in a window (Desktop Mode)\n"
                         "      --app <package>   once mirroring, open that app in a window of its own\n"
                         "      --pop-out         once mirroring, open the phone's screen in a bare window too\n"
                         "      --no-clipboard    do not sync the clipboard with the device\n"
                         "      --screen-off      turn the phone's screen off while mirroring\n"
                         "      --codec <c>       agent video codec: avc (default), hevc, vp8, vp9, av1\n"
                         "      --decoder <name>  FFmpeg decoder, e.g. h264_v4l2m2m (default: generic), or RPLAYHUB_DECODER\n"
                         "      --max-size WxH    agent frame size cap per dimension (default 1920x2400; 720x1600 for a Pi)\n";
            return 0;
        }
    }

    rplayhub::GuiApp app(auto_mirror, user_scale);
    if (!dump_path.empty()) {
        app.setDumpFrame(dump_path);
    }
    app.setPreferredSerial(serial);
    app.setStats(stats);
    if (tab >= 0) app.setInspectorTab(tab);
    app.setSessionOptions(opts);
    app.setClipboardSyncDefault(clipboard);
    app.setStartupDesktop(desktop);
    app.setStartupApp(app_package);
    app.setStartupPopOut(pop_out);

    if (!app.init()) {
        std::cerr << "Failed to initialize rPlayHub Linux GUI\n";
        return 1;
    }

    std::cout << "Starting rPlayHub Android Linux GUI...\n";
    app.run();
    return 0;
}
