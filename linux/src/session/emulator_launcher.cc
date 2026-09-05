#include "emulator_launcher.h"
#include "net/tcp_socket.h"

#include <algorithm>
#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <sstream>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace rplayhub {

namespace {
std::string homeDir() {
    const char* h = std::getenv("HOME");
    return h ? h : ".";
}
bool isExecutable(const std::string& p) { return ::access(p.c_str(), X_OK) == 0; }
bool isDir(const std::string& p) { struct stat st{}; return stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode); }
std::string trim(std::string s) {
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' ' || s.back() == '\t')) s.pop_back();
    size_t i = 0;
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t')) ++i;
    return s.substr(i);
}
} // namespace

std::map<std::string, std::string> EmulatorLauncher::iniValues(const std::string& path) {
    std::map<std::string, std::string> values;
    std::ifstream in(path);
    std::string line;
    while (std::getline(in, line)) {
        size_t eq = line.find('=');
        if (eq == std::string::npos || line[0] == '#') continue;
        values[trim(line.substr(0, eq))] = trim(line.substr(eq + 1));
    }
    return values;
}

std::string EmulatorLauncher::sdkRoot() {
    for (const char* var : {"ANDROID_HOME", "ANDROID_SDK_ROOT"}) {
        const char* v = std::getenv(var);
        if (v && *v && isDir(v)) return v;
    }
    for (const std::string& cand : {homeDir() + "/Android/Sdk", homeDir() + "/android-sdk", std::string("/opt/android-sdk")}) {
        if (isDir(cand)) return cand;
    }
    return "";
}

std::string EmulatorLauncher::emulatorBinary() {
    std::string root = sdkRoot();
    if (root.empty()) return "";
    std::string bin = root + "/emulator/emulator";
    return isExecutable(bin) ? bin : "";
}

std::string EmulatorLauncher::avdHome() {
    if (const char* v = std::getenv("ANDROID_AVD_HOME")) if (*v) return v;
    if (const char* v = std::getenv("ANDROID_USER_HOME")) if (*v) return std::string(v) + "/avd";
    return homeDir() + "/.android/avd";
}

std::vector<Avd> EmulatorLauncher::list() {
    std::vector<Avd> avds;
    std::string home = avdHome();
    DIR* dir = opendir(home.c_str());
    if (!dir) return avds;
    while (dirent* e = readdir(dir)) {
        std::string file = e->d_name;
        if (file.size() < 5 || file.compare(file.size() - 4, 4, ".ini") != 0) continue;
        std::string name = file.substr(0, file.size() - 4);
        auto pointer = iniValues(home + "/" + file);
        std::string directory = pointer.count("path") ? pointer["path"] : home + "/" + name + ".avd";
        auto config = iniValues(directory + "/config.ini");
        if (config.empty()) continue;
        Avd a;
        a.name = config.count("AvdId") && !config["AvdId"].empty() ? config["AvdId"] : name;
        a.display_name = config.count("avd.ini.displayname") && !config["avd.ini.displayname"].empty()
                             ? config["avd.ini.displayname"] : a.name;
        a.directory = directory;
        a.gpu_mode = config.count("hw.gpu.mode") ? config["hw.gpu.mode"] : "auto";
        a.abi = config.count("abi.type") ? config["abi.type"] : "";
        a.device = config.count("hw.device.name") ? config["hw.device.name"] : "";
        if (config.count("image.androidVersion.api")) a.api_level = config["image.androidVersion.api"];
        else if (config.count("target")) {
            std::string t = config["target"];   // "android-34"
            size_t dash = t.rfind('-');
            a.api_level = dash == std::string::npos ? t : t.substr(dash + 1);
        }
        avds.push_back(a);
    }
    closedir(dir);
    std::sort(avds.begin(), avds.end(), [](const Avd& x, const Avd& y) {
        std::string a = x.display_name, b = y.display_name;
        std::transform(a.begin(), a.end(), a.begin(), ::tolower);
        std::transform(b.begin(), b.end(), b.begin(), ::tolower);
        return a < b;
    });
    return avds;
}

// The emulator writes pid_<pid>.ini discovery files with the AVD id and its ports.
std::map<std::string, std::string> EmulatorLauncher::running() {
    std::map<std::string, std::string> result;
    std::vector<std::string> dirs;
    if (const char* rt = std::getenv("XDG_RUNTIME_DIR")) if (*rt) dirs.push_back(std::string(rt) + "/avd/running");
    dirs.push_back(homeDir() + "/.android/avd/running");
    for (const auto& d : dirs) {
        DIR* dir = opendir(d.c_str());
        if (!dir) continue;
        while (dirent* e = readdir(dir)) {
            std::string file = e->d_name;
            if (file.rfind("pid_", 0) != 0 || file.size() < 9 || file.compare(file.size() - 4, 4, ".ini") != 0) continue;
            int pid = std::atoi(file.substr(4, file.size() - 8).c_str());
            if (pid <= 0 || (kill(pid, 0) != 0 && errno != EPERM)) continue;   // stale file
            auto v = iniValues(d + "/" + file);
            // avd.id is the launch name; avd.name is the display name.
            std::string name = v.count("avd.id") ? v["avd.id"] : v["avd.name"];
            if (name.empty() || !v.count("port.serial")) continue;
            result[name] = "emulator-" + v["port.serial"];
        }
        closedir(dir);
    }
    return result;
}

int EmulatorLauncher::freeConsolePort() {
    for (int port = 5554; port <= 5682; port += 2) {
        TCPSocket probe;
        if (!probe.connect("127.0.0.1", static_cast<uint16_t>(port), 200)) return port;
    }
    return -1;
}

std::string EmulatorLauncher::logPath(const std::string& avd_name) {
    std::string dir = homeDir() + "/.cache/rplayhub-android";
    ::mkdir((homeDir() + "/.cache").c_str(), 0755);
    ::mkdir(dir.c_str(), 0755);
    return dir + "/emulator-" + avd_name + ".log";
}

std::string EmulatorLauncher::launch(const Avd& avd, std::string* out_err) {
    std::string binary = emulatorBinary();
    std::string root = sdkRoot();
    if (binary.empty()) {
        if (out_err) *out_err = "The Android SDK's emulator was not found (set ANDROID_HOME)";
        return "";
    }
    int port = freeConsolePort();
    if (port < 0) {
        if (out_err) *out_err = "No free emulator port (5554-5682) is left";
        return "";
    }
    // A hardware keyboard, so typing on the host reaches the emulator (the Mac client does this too).
    {
        std::string cfg = avd.directory + "/config.ini";
        auto values = iniValues(cfg);
        if (values["hw.keyboard"] != "yes") {
            std::ifstream in(cfg);
            std::stringstream out;
            std::string line;
            bool replaced = false;
            while (std::getline(in, line)) {
                if (trim(line).rfind("hw.keyboard=", 0) == 0) { out << "hw.keyboard=yes\n"; replaced = true; }
                else out << line << "\n";
            }
            if (!replaced) out << "hw.keyboard=yes\n";
            in.close();
            std::ofstream(cfg) << out.str();
        }
    }

    std::string log = logPath(avd.name);
    std::string port_s = std::to_string(port);
    std::vector<std::string> args = {binary, "-avd", avd.name, "-port", port_s, "-no-window", "-no-snapshot"};
    if (avd.gpu_mode == "auto") { args.push_back("-gpu"); args.push_back("swiftshader_indirect"); }   // headless: software GL

    pid_t pid = fork();
    if (pid < 0) {
        if (out_err) *out_err = std::string("fork: ") + strerror(errno);
        return "";
    }
    if (pid == 0) {
        setsid();   // survives the client; a second fork would lose the discovery file's pid match, so keep it simple
        int fd = open(log.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) { dup2(devnull, 0); close(devnull); }
        setenv("ANDROID_SDK_ROOT", root.c_str(), 1);
        setenv("ANDROID_HOME", root.c_str(), 1);
        std::vector<char*> argv;
        for (auto& a : args) argv.push_back(const_cast<char*>(a.c_str()));
        argv.push_back(nullptr);
        execv(binary.c_str(), argv.data());
        _exit(127);
    }
    std::cerr << "emulator: started " << avd.name << " as emulator-" << port << " (log: " << log << ")\n";
    return "emulator-" + port_s;
}

namespace {
// Read console output up to the next "OK" / "KO" line.
std::string consoleReply(TCPSocket& sock) {
    std::string acc;
    char buf[512];
    while (acc.find("\nOK") == std::string::npos && acc.rfind("OK", 0) != 0 &&
           acc.find("\nKO") == std::string::npos && acc.rfind("KO", 0) != 0) {
        ssize_t n = sock.read(buf, sizeof(buf));
        if (n <= 0) break;
        acc.append(buf, n);
    }
    return acc;
}

// Connect to emulator-<port>'s console and authenticate with ~/.emulator_console_auth_token.
bool openConsole(const std::string& serial, TCPSocket& sock, std::string* out_err) {
    if (serial.rfind("emulator-", 0) != 0) { if (out_err) *out_err = "not an emulator serial"; return false; }
    int port = std::atoi(serial.c_str() + 9);
    if (!sock.connect("127.0.0.1", static_cast<uint16_t>(port), 2000)) {
        if (out_err) *out_err = "emulator console " + std::to_string(port) + " is not answering";
        return false;
    }
    sock.setReadTimeout(3);
    consoleReply(sock);   // banner
    std::ifstream tok(homeDir() + "/.emulator_console_auth_token");
    std::string token;
    std::getline(tok, token);
    if (!token.empty()) {
        std::string cmd = "auth " + token + "\n";
        sock.writeAll(cmd.data(), cmd.size());
        if (consoleReply(sock).find("OK") == std::string::npos) {
            if (out_err) *out_err = "emulator console refused the auth token";
            return false;
        }
    }
    return true;
}
} // namespace

std::string EmulatorLauncher::avdNameOf(const std::string& serial) {
    TCPSocket sock;
    if (!openConsole(serial, sock, nullptr)) return "";
    const char* cmd = "avd name\n";
    sock.writeAll(cmd, strlen(cmd));
    std::string reply = consoleReply(sock);
    // "<name>\r\nOK\r\n"
    std::istringstream stream(reply);
    std::string line;
    while (std::getline(stream, line)) {
        line = trim(line);
        if (!line.empty() && line != "OK" && line != "KO") return line;
    }
    return "";
}

bool EmulatorLauncher::shutdown(const std::string& serial, std::string* out_err) {
    TCPSocket sock;
    if (!openConsole(serial, sock, out_err)) return false;
    const char* kill = "kill\n";
    sock.writeAll(kill, strlen(kill));
    consoleReply(sock);
    return true;
}

} // namespace rplayhub
