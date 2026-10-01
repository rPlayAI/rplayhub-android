#include "tcp_listener.h"

#include <cstring>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#define close_socket(s) closesocket(static_cast<SOCKET>(s))
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#define close_socket(s) ::close(s)
#endif

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
        close_socket(fd_);
        fd_ = -1;
        port_ = 0;
    }
}

bool TCPListener::open(uint16_t port) {
    close();

#ifdef _WIN32
    SOCKET s = ::socket(AF_INET, SOCK_STREAM, 0);
    if (s == INVALID_SOCKET) return false;
    fd_ = static_cast<intptr_t>(s);
    int opt = 1;
    ::setsockopt(static_cast<SOCKET>(fd_), SOL_SOCKET, SO_REUSEADDR, (const char*)&opt, sizeof(opt));
#else
    int s = ::socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return false;
    fd_ = s;
    int opt = 1;
    ::setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#endif

    struct sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);

    if (::bind(static_cast<SOCKET>(fd_), (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close();
        return false;
    }

    if (::listen(static_cast<SOCKET>(fd_), 16) < 0) {
        close();
        return false;
    }

    // Determine assigned port
#ifdef _WIN32
    int len = sizeof(addr);
    if (::getsockname(static_cast<SOCKET>(fd_), (struct sockaddr*)&addr, &len) == 0) {
        port_ = ntohs(addr.sin_port);
    } else {
        close();
        return false;
    }
#else
    socklen_t len = sizeof(addr);
    if (::getsockname(fd_, (struct sockaddr*)&addr, &len) == 0) {
        port_ = ntohs(addr.sin_port);
    } else {
        close();
        return false;
    }
#endif

    return true;
}

bool TCPListener::accept(TCPSocket& out_socket, int timeout_ms) {
    if (fd_ < 0) return false;

    struct pollfd pfd{};
    pfd.fd = static_cast<SOCKET>(fd_);
    pfd.events = POLLIN;

#ifdef _WIN32
    int res = ::WSAPoll(&pfd, 1, timeout_ms);
#else
    int res = ::poll(&pfd, 1, timeout_ms);
#endif
    if (res <= 0) return false;

    struct sockaddr_in client_addr{};
#ifdef _WIN32
    int client_len = sizeof(client_addr);
    SOCKET client_fd = ::accept(static_cast<SOCKET>(fd_), (struct sockaddr*)&client_addr, &client_len);
    if (client_fd == INVALID_SOCKET) return false;
    out_socket = TCPSocket(static_cast<intptr_t>(client_fd));
#else
    socklen_t client_len = sizeof(client_addr);
    int client_fd = ::accept(fd_, (struct sockaddr*)&client_addr, &client_len);
    if (client_fd < 0) return false;
    out_socket = TCPSocket(client_fd);
#endif
    return true;
}

} // namespace rplayhub
