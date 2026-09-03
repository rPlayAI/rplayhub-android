#pragma once

#include <string>
#include <vector>
#include <cstdint>
#include <sys/types.h>

namespace rplayhub {

class TCPSocket {
public:
    TCPSocket();
    explicit TCPSocket(int fd);
    ~TCPSocket();

    // Movable
    TCPSocket(TCPSocket&& other) noexcept;
    TCPSocket& operator=(TCPSocket&& other) noexcept;

    // Non-copyable
    TCPSocket(const TCPSocket&) = delete;
    TCPSocket& operator=(const TCPSocket&) = delete;

    bool connect(const std::string& host, uint16_t port, int timeout_ms = 5000);
    void close();

    bool isValid() const { return fd_ >= 0; }
    int getFd() const { return fd_; }

    bool setNoDelay(bool enable = true);
    bool setReadTimeout(int seconds);
    bool setWriteTimeout(int seconds);

    // Read exactly count bytes. Returns true on success, false on error or EOF.
    bool readFully(void* buf, size_t count);

    // Read up to max_len bytes. Returns bytes read, 0 on EOF, or -1 on error.
    ssize_t read(void* buf, size_t max_len);

    // Write exactly count bytes. Returns true on success, false on error.
    bool writeAll(const void* buf, size_t count);
    bool writeString(const std::string& str);

    void shutdownAndClose();

private:
    int fd_ = -1;
};

} // namespace rplayhub
