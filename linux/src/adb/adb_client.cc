#include "adb_client.h"

#include <cstdio>
#include <cstdlib>
#include <sstream>
#include <iomanip>
#include <array>
#include <algorithm>
#include <unistd.h>
#include <sys/wait.h>

namespace rplayhub {

std::string AdbDevice::displayName() const {
    if (isEmulator()) {
        return "Android Emulator (" + serial + ")";
    }
    if (!model.empty()) {
        std::string name = model;
        std::replace(name.begin(), name.end(), '_', ' ');
        return name;
    }
    return serial;
}

AdbClient::AdbClient(std::string host, uint16_t port)
    : host_(std::move(host)), port_(port) {}

std::unique_ptr<TCPSocket> AdbClient::openServer(int timeout_ms) {
    auto sock = std::make_unique<TCPSocket>();
    if (!sock->connect(host_, port_, timeout_ms)) {
        return nullptr;
    }
    return sock;
}

bool AdbClient::sendRequest(TCPSocket& socket, const std::string& request) {
    char header[5];
    std::snprintf(header, sizeof(header), "%04x", static_cast<unsigned>(request.size()));
    if (!socket.writeAll(header, 4)) return false;
    if (!socket.writeAll(request.data(), request.size())) return false;
    return true;
}

bool AdbClient::expectOkay(TCPSocket& socket, std::string* out_err) {
    char status[5] = {0};
    if (!socket.readFully(status, 4)) return false;
    if (std::string(status, 4) == "OKAY") return true;

    if (std::string(status, 4) == "FAIL") {
        char len_hex[5] = {0};
        if (socket.readFully(len_hex, 4)) {
            unsigned int len = 0;
            std::sscanf(len_hex, "%x", &len);
            if (len > 0 && len < 4096) {
                std::vector<char> msg(len + 1, 0);
                if (socket.readFully(msg.data(), len)) {
                    if (out_err) *out_err = msg.data();
                }
            }
        }
    }
    return false;
}

std::unique_ptr<TCPSocket> AdbClient::openTransport(const std::string& serial) {
    auto sock = openServer(10000);
    if (!sock) return nullptr;

    std::string req = "host:transport:" + serial;
    if (!sendRequest(*sock, req) || !expectOkay(*sock)) {
        return nullptr;
    }
    return sock;
}

bool AdbClient::getDevices(std::vector<AdbDevice>& out_devices) {
    out_devices.clear();
    auto sock = openServer();
    if (!sock) return false;

    if (!sendRequest(*sock, "host:devices-l") || !expectOkay(*sock)) {
        return false;
    }

    char len_hex[5] = {0};
    if (!sock->readFully(len_hex, 4)) return false;

    unsigned int len = 0;
    std::sscanf(len_hex, "%x", &len);
    if (len == 0) return true;

    std::vector<char> buf(len + 1, 0);
    if (!sock->readFully(buf.data(), len)) return false;

    std::istringstream stream(buf.data());
    std::string line;
    while (std::getline(stream, line)) {
        if (line.empty()) continue;
        std::istringstream line_stream(line);
        AdbDevice dev;
        if (!(line_stream >> dev.serial >> dev.state)) continue;

        std::string token;
        while (line_stream >> token) {
            if (token.rfind("model:", 0) == 0) {
                dev.model = token.substr(6);
            } else if (token.rfind("product:", 0) == 0) {
                dev.product = token.substr(8);
            } else if (token.rfind("transport_id:", 0) == 0) {
                dev.transport_id = token.substr(13);
            }
        }
        out_devices.push_back(dev);
    }
    return true;
}

std::string AdbClient::getProp(const std::string& serial, const std::string& prop) {
    std::string val = shell(serial, "getprop " + prop);
    while (!val.empty() && (val.back() == '\r' || val.back() == '\n' || val.back() == ' ')) {
        val.pop_back();
    }
    return val;
}

bool AdbClient::reverse(const std::string& serial, const std::string& local_abstract, uint16_t to_port) {
    auto sock = openTransport(serial);
    if (!sock) return false;

    std::ostringstream req;
    req << "reverse:forward:localabstract:" << local_abstract << ";tcp:" << to_port;
    if (!sendRequest(*sock, req.str()) || !expectOkay(*sock)) {
        return false;
    }
    return true;
}

bool AdbClient::reverseRemove(const std::string& serial, const std::string& local_abstract) {
    auto sock = openTransport(serial);
    if (!sock) return false;

    std::string req = "reverse:killforward:localabstract:" + local_abstract;
    if (!sendRequest(*sock, req) || !expectOkay(*sock)) {
        return false;
    }
    return true;
}

std::string AdbClient::shell(const std::string& serial, const std::string& command) {
    auto sock = openTransport(serial);
    if (!sock) return "";

    std::string req = "shell:" + command;
    if (!sendRequest(*sock, req) || !expectOkay(*sock)) {
        return "";
    }

    std::string output;
    char buf[4096];
    while (true) {
        ssize_t n = sock->read(buf, sizeof(buf));
        if (n <= 0) break;
        output.append(buf, n);
    }
    return output;
}

std::unique_ptr<TCPSocket> AdbClient::shellStream(const std::string& serial, const std::string& command) {
    auto sock = openTransport(serial);
    if (!sock) return nullptr;

    std::string req = "shell:" + command;
    if (!sendRequest(*sock, req) || !expectOkay(*sock)) {
        return nullptr;
    }
    return sock;
}

bool AdbClient::pushFile(const std::string& serial, const std::string& local_path, const std::string& remote_path, mode_t mode) {
    // We execute adb push via fork/exec
    pid_t pid = fork();
    if (pid == 0) {
        execlp("adb", "adb", "-s", serial.c_str(), "push", local_path.c_str(), remote_path.c_str(), (char*)nullptr);
        _exit(127);
    }
    if (pid < 0) return false;

    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        if (mode != 0644) {
            char mode_str[32];
            std::snprintf(mode_str, sizeof(mode_str), "%o", static_cast<unsigned>(mode));
            shell(serial, "chmod " + std::string(mode_str) + " " + remote_path);
        }
        return true;
    }
    return false;
}

std::vector<std::string> AdbClient::getPackages(const std::string& serial, bool third_party_only) {
    std::string cmd = third_party_only ? "pm list packages -3" : "pm list packages";
    std::string raw = shell(serial, cmd);
    std::vector<std::string> packages;
    std::istringstream stream(raw);
    std::string line;
    while (std::getline(stream, line)) {
        while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) {
            line.pop_back();
        }
        if (line.rfind("package:", 0) == 0) {
            packages.push_back(line.substr(8));
        }
    }
    std::sort(packages.begin(), packages.end());
    return packages;
}

int AdbClient::getBatteryLevel(const std::string& serial) {
    std::string raw = shell(serial, "dumpsys battery");
    std::istringstream stream(raw);
    std::string line;
    while (std::getline(stream, line)) {
        size_t idx = line.find("level: ");
        if (idx != std::string::npos) {
            return std::atoi(line.c_str() + idx + 7);
        }
    }
    return -1;
}

bool AdbClient::connectNetwork(const std::string& address, std::string& out_msg) {
    auto sock = openServer();
    if (!sock) {
        out_msg = "Cannot connect to ADB server";
        return false;
    }
    std::string req = "host:connect:" + address;
    if (!sendRequest(*sock, req) || !expectOkay(*sock)) {
        out_msg = "ADB host:connect request failed";
        return false;
    }
    char len_hex[5] = {0};
    if (sock->readFully(len_hex, 4)) {
        unsigned int len = 0;
        std::sscanf(len_hex, "%x", &len);
        if (len > 0) {
            std::vector<char> buf(len + 1, 0);
            sock->readFully(buf.data(), len);
            out_msg = buf.data();
        }
    }
    return true;
}

bool AdbClient::disconnectNetwork(const std::string& address) {
    auto sock = openServer();
    if (!sock) return false;
    std::string req = "host:disconnect:" + address;
    if (!sendRequest(*sock, req) || !expectOkay(*sock)) return false;
    return true;
}

bool AdbClient::takeScreenshot(const std::string& serial, const std::string& local_png_path) {
    std::string cmd = "adb -s " + serial + " exec-out screencap -p > " + local_png_path;
    int res = system(cmd.c_str());
    return res == 0;
}

bool AdbClient::installApk(const std::string& serial, const std::string& apk_path, std::string& out_err) {
    std::string cmd = "adb -s " + serial + " install -r " + apk_path;
    FILE* fp = popen(cmd.c_str(), "r");
    if (!fp) {
        out_err = "Failed to run adb install";
        return false;
    }
    char buf[512];
    std::string output;
    while (fgets(buf, sizeof(buf), fp)) {
        output += buf;
    }
    int code = pclose(fp);
    if (code == 0 && output.find("Success") != std::string::npos) {
        return true;
    }
    out_err = output;
    return false;
}

} // namespace rplayhub
