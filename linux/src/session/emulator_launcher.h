#pragma once

// Android SDK emulators (AVDs) as the sidebar sees them: listed from
// ~/.android/avd, started headless on a known console port so their adb
// serial is known up front, marked running from the emulator's own discovery
// files, and shut down through the emulator console. A running emulator is
// mirrored like any device: adb lists it as emulator-<port> and the agent has
// an x86_64 build.

#include <map>
#include <string>
#include <vector>

namespace rplayhub {

struct Avd {
    std::string name;          // what `-avd` takes (AvdId)
    std::string display_name;  // avd.ini.displayname, else the name
    std::string directory;     // <name>.avd
    std::string gpu_mode;      // hw.gpu.mode from config.ini
    std::string api_level;     // image.androidVersion.api / target
    std::string abi;
    std::string device;        // hw.device.name
};

class EmulatorLauncher {
public:
    static std::string sdkRoot();            // ANDROID_HOME / ANDROID_SDK_ROOT / ~/Android/Sdk; empty if none
    static std::string emulatorBinary();     // <sdk>/emulator/emulator, empty if missing
    static std::string avdHome();            // ANDROID_AVD_HOME / ANDROID_USER_HOME/avd / ~/.android/avd

    static std::vector<Avd> list();
    // AVD name -> adb serial from the emulator's discovery files ($XDG_RUNTIME_DIR/avd/running).
    // The Linux emulator only writes them when started with -grpc, so the sidebar relies on
    // avdNameOf() for the serials adb lists instead.
    static std::map<std::string, std::string> running();
    // `avd name` on the emulator console of emulator-<port>; empty if it does not answer.
    static std::string avdNameOf(const std::string& serial);

    // Start headless. Returns the serial it will have (emulator-<port>), or empty with a reason.
    static std::string launch(const Avd& avd, std::string* out_err);
    // `kill` on the emulator console (auth token from ~/.emulator_console_auth_token).
    static bool shutdown(const std::string& serial, std::string* out_err);

    static std::string logPath(const std::string& avd_name);

private:
    static std::map<std::string, std::string> iniValues(const std::string& path);
    static int freeConsolePort();
};

} // namespace rplayhub
