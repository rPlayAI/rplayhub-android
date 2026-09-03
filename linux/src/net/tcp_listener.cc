#include "tcp_listener.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cstring>

namespace rplayhub {

TCPListener::TCPListener() : fd_(-1), port_(0) {}

TCPListener::~TCPListener() {
    close();
}

TCPListener::TCPListener(TCPListener&& other) noexcept : fd_(other.fd_), port_(other.port_) {
    other.fd_ = -1;
    other.port_ = 0;
}

TCPListener& TCPListener::operator=(TCPListener&& other) noexcept {
    if (this != &other) {
        close();
        fd_ = other.fd_;
        port_ = other.port_;
        other.fd_ = -1;
        other.port_ = 0;
    }
    return *this;
}

void TCPListener::close() {
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
        port_ = 0;
    }
}

bool TCPListener::open(uint16_t port) {
    close();

    fd_ = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd_ < 0) return false;

    int opt = 1;
    ::setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);

    if (::bind(fd_, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close();
        return false;
    }

    if (::listen(fd_, 16) < 0) {
        close();
        return false;
    }

    // Determine assigned port
    socklen_t len = sizeof(addr);
    if (::getsockname(fd_, (struct sockaddr*)&addr, &len) == 0) {
        port_ = ntohs(addr.sin_port);
    } else {
        close();
        return false;
    }

    return true;
}

bool TCPListener::accept(TCPSocket& out_socket, int timeout_ms) {
    if (fd_ < 0) return false;

    struct pollfd pfd{};
    pfd.fd = fd_;
    pfd.events = POLLIN;

    int res = ::poll(&pfd, 1, timeout_ms);
    if (res <= 0) return false;

    struct sockaddr_in client_addr{};
    socklen_t client_len = sizeof(client_addr);
    int client_fd = ::accept(fd_, (struct sockaddr*)&client_addr, &client_len);
    if (client_fd < 0) return false;

    out_socket = TCPSocket(client_fd);
    return true;
}

} // namespace rplayhub
