#pragma once

#include "net/tcp_socket.h"
#include <string>
#include <vector>
#include <memory>

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

    // Push a file to the device
    bool pushFile(const std::string& serial, const std::string& local_path, const std::string& remote_path, mode_t mode = 0644);

    // Get list of installed packages
    std::vector<std::string> getPackages(const std::string& serial, bool third_party_only = true);

    // Get battery percentage (0-100) or -1 if unknown
    int getBatteryLevel(const std::string& serial);

    // Connect / Disconnect network device (e.g. 192.168.1.50:5555)
    bool connectNetwork(const std::string& address, std::string& out_msg);
    bool disconnectNetwork(const std::string& address);

    // Take screenshot to local PNG
    bool takeScreenshot(const std::string& serial, const std::string& local_png_path);

    // Install APK
    bool installApk(const std::string& serial, const std::string& apk_path, std::string& out_err);

private:
    std::string host_;
    uint16_t port_;

    std::unique_ptr<TCPSocket> openServer(int timeout_ms = 5000);
    bool sendRequest(TCPSocket& socket, const std::string& request);
    bool expectOkay(TCPSocket& socket, std::string* out_err = nullptr);
    std::unique_ptr<TCPSocket> openTransport(const std::string& serial);
};

} // namespace rplayhub
