#pragma once

#include "tcp_socket.h"
#include <cstdint>

namespace rplayhub {

class TCPListener {
public:
    TCPListener();
    ~TCPListener();

    // Movable
    TCPListener(TCPListener&& other) noexcept;
    TCPListener& operator=(TCPListener&& other) noexcept;

    // Non-copyable
    TCPListener(const TCPListener&) = delete;
    TCPListener& operator=(const TCPListener&) = delete;

    // Listen on 127.0.0.1 with port 0 (OS picks port)
    bool open(uint16_t port = 0);
    void close();

    uint16_t getPort() const { return port_; }
    int getFd() const { return fd_; }

    // Accept an incoming connection with timeout in milliseconds
    bool accept(TCPSocket& out_socket, int timeout_ms = 20000);

private:
    int fd_ = -1;
    uint16_t port_ = 0;
};

} // namespace rplayhub
