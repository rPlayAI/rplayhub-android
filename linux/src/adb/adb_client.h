#pragma once

#include "net/tcp_socket.h"
#include <string>
#include <vector>
#include <memory>
#include <functional>
#include <sys/types.h>

namespace rplayhub {

struct AdbDevice {
    std::string serial;
    std::string state; // "device", "unauthorized", "offline", etc.
    std::string model;
    std::string product;
    std::string transport_id;

    bool isReady() const { return state == "device"; }
    bool isEmulator() const { return serial.rfind("emulator-", 0) == 0; }
    std::string displayName() const;
};

// One line of toybox `ls -la`, parsed.
struct DirEntry {
    std::string name;
    std::string permissions;   // "drwxrwx--x"
    std::string modified;      // "2026-08-29 11:16"
    long long size = 0;
    bool isDirectory = false;
    bool isLink = false;
};

class AdbClient {
public:
    explicit AdbClient(std::string host = "127.0.0.1", uint16_t port = 5037);

    // List connected devices
    bool getDevices(std::vector<AdbDevice>& out_devices);

    // Retrieve device system property via `getprop`
    std::string getProp(const std::string& serial, const std::string& prop);

    // Setup reverse socket forward: localabstract:<name> -> tcp:<port>
    bool reverse(const std::string& serial, const std::string& local_abstract, uint16_t to_port);
    bool reverseRemove(const std::string& serial, const std::string& local_abstract);

    // Execute shell command and get stdout as string
    std::string shell(const std::string& serial, const std::string& command);

    // Open a persistent socket streaming shell stdout (e.g. for agent process)
    std::unique_ptr<TCPSocket> shellStream(const std::string& serial, const std::string& command);

    // Raw stdout of a command with no pty (adb exec-out); binary safe.
    bool execOut(const std::string& serial, const std::string& command, std::vector<uint8_t>& out);

    // File transfer over the adb sync service (no adb binary involved).
    bool pushFile(const std::string& serial, const std::string& local_path, const std::string& remote_path, mode_t mode = 0644);
    bool pushBytes(const std::string& serial, const std::vector<uint8_t>& data, const std::string& remote_path, mode_t mode = 0644);
    bool pullFile(const std::string& serial, const std::string& remote_path, const std::string& local_path, std::string* out_err = nullptr);

    // Directory listing via `ls -la`; "." and ".." are dropped. False when the
    // path is unreadable as the shell user.
    bool listDirectory(const std::string& serial, const std::string& path, std::vector<DirEntry>& out);

    // Single-quote for the device shell.
    static std::string shellQuote(const std::string& s);

    // Get list of installed packages
    std::vector<std::string> getPackages(const std::string& serial, bool third_party_only = true);

    // Get battery percentage (0-100) or -1 if unknown
    int getBatteryLevel(const std::string& serial);

    // Connect / Disconnect network device (e.g. 192.168.1.50:5555)
    bool connectNetwork(const std::string& address, std::string& out_msg);
    bool disconnectNetwork(const std::string& address);

    // Install an APK: pushed to /data/local/tmp, `pm install -r`, removed again.
    bool installApk(const std::string& serial, const std::string& apk_path, std::string& out_err);

private:
    std::string host_;
    uint16_t port_;

    std::unique_ptr<TCPSocket> openServer(int timeout_ms = 5000);
    bool sendRequest(TCPSocket& socket, const std::string& request);
    bool expectOkay(TCPSocket& socket, std::string* out_err = nullptr);
    std::unique_ptr<TCPSocket> openTransport(const std::string& serial);
    std::unique_ptr<TCPSocket> openSync(const std::string& serial);
    bool syncSend(TCPSocket& sock, const std::string& remote_path, mode_t mode,
                  const std::function<ssize_t(uint8_t*, size_t)>& read_chunk, std::string* out_err);
};

} // namespace rplayhub
