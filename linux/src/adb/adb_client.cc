#include "adb_client.h"
#include <iostream>
#include <ctime>
#include <cstring>

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

// ---- sync service: SEND / RECV, little-endian ids and lengths ----

namespace {
void putU32(std::vector<uint8_t>& v, uint32_t x) {
    v.push_back(x & 0xFF); v.push_back((x >> 8) & 0xFF); v.push_back((x >> 16) & 0xFF); v.push_back((x >> 24) & 0xFF);
}
uint32_t getU32(const uint8_t* p) {
    return p[0] | (p[1] << 8) | (p[2] << 16) | (static_cast<uint32_t>(p[3]) << 24);
}
} // namespace

std::unique_ptr<TCPSocket> AdbClient::openSync(const std::string& serial) {
    auto sock = openTransport(serial);
    if (!sock) return nullptr;
    if (!sendRequest(*sock, "sync:") || !expectOkay(*sock)) return nullptr;
    return sock;
}

bool AdbClient::syncSend(TCPSocket& sock, const std::string& remote_path, mode_t mode,
                         const std::function<ssize_t(uint8_t*, size_t)>& read_chunk, std::string* out_err) {
    std::string spec = remote_path + "," + std::to_string(static_cast<unsigned>(mode));
    std::vector<uint8_t> msg = {'S', 'E', 'N', 'D'};
    putU32(msg, static_cast<uint32_t>(spec.size()));
    msg.insert(msg.end(), spec.begin(), spec.end());
    if (!sock.writeAll(msg.data(), msg.size())) return false;

    std::vector<uint8_t> chunk(64 * 1024 + 8);
    while (true) {
        ssize_t n = read_chunk(chunk.data() + 8, 64 * 1024);
        if (n < 0) return false;
        if (n == 0) break;
        chunk[0] = 'D'; chunk[1] = 'A'; chunk[2] = 'T'; chunk[3] = 'A';
        uint32_t len = static_cast<uint32_t>(n);
        chunk[4] = len & 0xFF; chunk[5] = (len >> 8) & 0xFF; chunk[6] = (len >> 16) & 0xFF; chunk[7] = (len >> 24) & 0xFF;
        if (!sock.writeAll(chunk.data(), 8 + n)) return false;
    }
    std::vector<uint8_t> done = {'D', 'O', 'N', 'E'};
    putU32(done, static_cast<uint32_t>(time(nullptr)));
    if (!sock.writeAll(done.data(), done.size())) return false;

    uint8_t reply[8];
    if (!sock.readFully(reply, 8)) return false;
    if (memcmp(reply, "OKAY", 4) == 0) return true;
    if (memcmp(reply, "FAIL", 4) == 0 && out_err) {
        uint32_t len = getU32(reply + 4);
        std::string err(len, '\0');
        if (len && sock.readFully(err.data(), len)) *out_err = err;
    }
    return false;
}

bool AdbClient::pushFile(const std::string& serial, const std::string& local_path, const std::string& remote_path, mode_t mode) {
    FILE* fp = fopen(local_path.c_str(), "rb");
    if (!fp) return false;
    auto sock = openSync(serial);
    if (!sock) { fclose(fp); return false; }
    std::string err;
    bool ok = syncSend(*sock, remote_path, mode, [fp](uint8_t* buf, size_t max) -> ssize_t {
        size_t n = fread(buf, 1, max, fp);
        if (n == 0 && ferror(fp)) return -1;
        return static_cast<ssize_t>(n);
    }, &err);
    fclose(fp);
    if (!ok && !err.empty()) std::cerr << "adb push " << remote_path << ": " << err << "\n";
    return ok;
}

bool AdbClient::pushBytes(const std::string& serial, const std::vector<uint8_t>& data, const std::string& remote_path, mode_t mode) {
    auto sock = openSync(serial);
    if (!sock) return false;
    size_t offset = 0;
    std::string err;
    bool ok = syncSend(*sock, remote_path, mode, [&](uint8_t* buf, size_t max) -> ssize_t {
        size_t n = std::min(max, data.size() - offset);
        memcpy(buf, data.data() + offset, n);
        offset += n;
        return static_cast<ssize_t>(n);
    }, &err);
    if (!ok && !err.empty()) std::cerr << "adb push " << remote_path << ": " << err << "\n";
    return ok;
}

bool AdbClient::pullFile(const std::string& serial, const std::string& remote_path, const std::string& local_path, std::string* out_err) {
    auto sock = openSync(serial);
    if (!sock) { if (out_err) *out_err = "adb server not reachable"; return false; }
    std::vector<uint8_t> msg = {'R', 'E', 'C', 'V'};
    putU32(msg, static_cast<uint32_t>(remote_path.size()));
    msg.insert(msg.end(), remote_path.begin(), remote_path.end());
    if (!sock->writeAll(msg.data(), msg.size())) return false;

    FILE* fp = fopen(local_path.c_str(), "wb");
    if (!fp) { if (out_err) *out_err = "cannot write " + local_path; return false; }
    bool ok = false;
    std::vector<uint8_t> buf;
    while (true) {
        uint8_t hdr[8];
        if (!sock->readFully(hdr, 8)) break;
        uint32_t len = getU32(hdr + 4);
        if (memcmp(hdr, "DATA", 4) == 0) {
            buf.resize(len);
            if (len && !sock->readFully(buf.data(), len)) break;
            if (len && fwrite(buf.data(), 1, len, fp) != len) break;
        } else if (memcmp(hdr, "DONE", 4) == 0) {
            ok = true;
            break;
        } else if (memcmp(hdr, "FAIL", 4) == 0) {
            std::string err(len, '\0');
            if (len && sock->readFully(err.data(), len) && out_err) *out_err = err;
            break;
        } else {
            break;
        }
    }
    fclose(fp);
    if (!ok) unlink(local_path.c_str());
    return ok;
}

bool AdbClient::execOut(const std::string& serial, const std::string& command, std::vector<uint8_t>& out) {
    out.clear();
    auto sock = openTransport(serial);
    if (!sock) return false;
    if (!sendRequest(*sock, "exec:" + command) || !expectOkay(*sock)) return false;
    uint8_t buf[65536];
    while (true) {
        ssize_t n = sock->read(buf, sizeof(buf));
        if (n <= 0) break;
        out.insert(out.end(), buf, buf + n);
    }
    return true;
}

std::string AdbClient::shellQuote(const std::string& in) {
    std::string out = "'";
    for (char c : in) {
        if (c == '\'') out += "'\\''";
        else out.push_back(c);
    }
    out += "'";
    return out;
}

namespace {
// toybox escapes spaces and other specials in names: "a\ b.txt"
std::string lsUnescape(const std::string& in) {
    std::string out;
    for (size_t i = 0; i < in.size(); ++i) {
        if (in[i] == '\\' && i + 1 < in.size()) { out.push_back(in[++i]); continue; }
        out.push_back(in[i]);
    }
    return out;
}

// -rw-r--r-- 1 root root 1234 2026-08-29 11:16 name with spaces [-> target]
bool parseLsLine(const std::string& line, DirEntry& e) {
    std::vector<std::string> f;
    size_t i = 0, n = line.size();
    while (i < n && f.size() < 7) {
        while (i < n && line[i] == ' ') ++i;
        size_t j = i;
        while (j < n && line[j] != ' ') ++j;
        if (j == i) break;
        f.push_back(line.substr(i, j - i));
        i = j;
    }
    while (i < n && line[i] == ' ') ++i;
    if (f.size() < 7 || i >= n) return false;
    if (f[0].size() < 10 || !(f[0][0] == '-' || f[0][0] == 'd' || f[0][0] == 'l' || f[0][0] == 'c' || f[0][0] == 'b' || f[0][0] == 'p' || f[0][0] == 's')) return false;
    std::string name = line.substr(i);
    e.isLink = f[0][0] == 'l';
    if (e.isLink) {
        size_t arrow = name.find(" -> ");
        if (arrow != std::string::npos) name = name.substr(0, arrow);
    }
    e.name = lsUnescape(name);
    e.permissions = f[0];
    e.isDirectory = f[0][0] == 'd';
    // Character devices print "major, minor" instead of a size: field count shifts; be lenient.
    e.size = std::atoll(f[4].c_str());
    e.modified = f[5] + " " + f[6];
    return !e.name.empty();
}
} // namespace

bool AdbClient::listDirectory(const std::string& serial, const std::string& path, std::vector<DirEntry>& out) {
    out.clear();
    // Trailing slash so a symlink like /sdcard lists its target instead of itself.
    std::string dir = path;
    if (dir.empty() || dir.back() != '/') dir += '/';
    std::string raw = shell(serial, "ls -la " + shellQuote(dir) + " 2>&1 && echo __rplayhub_ok__");
    if (raw.find("__rplayhub_ok__") == std::string::npos) return false;
    std::istringstream stream(raw);
    std::string line;
    while (std::getline(stream, line)) {
        while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) line.pop_back();
        DirEntry e;
        if (!parseLsLine(line, e)) continue;
        if (e.name == "." || e.name == "..") continue;
        out.push_back(std::move(e));
    }
    // Folders first, then names, case-insensitively.
    std::sort(out.begin(), out.end(), [](const DirEntry& a, const DirEntry& b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory;
        std::string la = a.name, lb = b.name;
        std::transform(la.begin(), la.end(), la.begin(), ::tolower);
        std::transform(lb.begin(), lb.end(), lb.begin(), ::tolower);
        return la < lb;
    });
    return true;
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

bool AdbClient::installApk(const std::string& serial, const std::string& apk_path, std::string& out_err) {
    std::string remote = "/data/local/tmp/rplayhub-install-" + std::to_string(getpid()) + ".apk";
    if (!pushFile(serial, apk_path, remote, 0644)) {
        out_err = "push failed";
        return false;
    }
    std::string output = shell(serial, "pm install -r -t '" + remote + "'; rm -f '" + remote + "'");
    if (output.find("Success") != std::string::npos) return true;
    while (!output.empty() && (output.back() == '\n' || output.back() == '\r')) output.pop_back();
    out_err = output.empty() ? "pm install failed" : output;
    return false;
}

} // namespace rplayhub
