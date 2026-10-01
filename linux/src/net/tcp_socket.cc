#include "tcp_socket.h"

#include <cerrno>
#include <climits>
#include <cstring>
#include <algorithm>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")

namespace {
struct WinsockInit {
    WinsockInit() {
        WSADATA wsa{};
        WSAStartup(MAKEWORD(2, 2), &wsa);
    }
    ~WinsockInit() {
        WSACleanup();
    }
};
static WinsockInit s_winsock_init;
} // namespace

#define close_socket(s) closesocket(static_cast<SOCKET>(s))
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#define close_socket(s) ::close(s)
#endif

namespace rplayhub {

TCPSocket::TCPSocket() : fd_(-1) {}

TCPSocket::TCPSocket(intptr_t fd) : fd_(fd) {}

TCPSocket::~TCPSocket() {
    close();
}

TCPSocket::TCPSocket(TCPSocket&& other) noexcept : fd_(other.fd_) {
    other.fd_ = -1;
}

TCPSocket& TCPSocket::operator=(TCPSocket&& other) noexcept {
    if (this != &other) {
        close();
        fd_ = other.fd_;
        other.fd_ = -1;
    }
    return *this;
}

void TCPSocket::close() {
    if (fd_ >= 0) {
        close_socket(fd_);
        fd_ = -1;
    }
}

void TCPSocket::shutdownAndClose() {
    if (fd_ >= 0) {
#ifdef _WIN32
        ::shutdown(static_cast<SOCKET>(fd_), SD_BOTH);
#else
        ::shutdown(fd_, SHUT_RDWR);
#endif
        close_socket(fd_);
        fd_ = -1;
    }
}

bool TCPSocket::connect(const std::string& host, uint16_t port, int timeout_ms) {
    close();

#ifdef _WIN32
    SOCKET s = ::socket(AF_INET, SOCK_STREAM, 0);
    if (s == INVALID_SOCKET) return false;
    fd_ = static_cast<intptr_t>(s);
#else
    int s = ::socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return false;
    fd_ = s;
#endif

    struct sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (::inet_pton(AF_INET, host.c_str(), &addr.sin_addr) <= 0) {
        close();
        return false;
    }

#ifdef _WIN32
    u_long nonblock = 1;
    ::ioctlsocket(static_cast<SOCKET>(fd_), FIONBIO, &nonblock);

    int res = ::connect(static_cast<SOCKET>(fd_), (struct sockaddr*)&addr, sizeof(addr));
    if (res < 0) {
        int wsa_err = WSAGetLastError();
        if (wsa_err != WSAEWOULDBLOCK && wsa_err != WSAEINPROGRESS) {
            close();
            return false;
        }
    }

    if (res != 0) {
        struct pollfd pfd{};
        pfd.fd = static_cast<SOCKET>(fd_);
        pfd.events = POLLOUT;
        int poll_res = ::WSAPoll(&pfd, 1, timeout_ms);
        if (poll_res <= 0) {
            close();
            return false;
        }

        int err = 0;
        int len = sizeof(err);
        if (::getsockopt(static_cast<SOCKET>(fd_), SOL_SOCKET, SO_ERROR, (char*)&err, &len) < 0 || err != 0) {
            close();
            return false;
        }
    }

    nonblock = 0;
    ::ioctlsocket(static_cast<SOCKET>(fd_), FIONBIO, &nonblock);
#else
    // Set non-blocking for connect timeout
    int flags = ::fcntl(fd_, F_GETFL, 0);
    if (flags < 0 || ::fcntl(fd_, F_SETFL, flags | O_NONBLOCK) < 0) {
        close();
        return false;
    }

    int res = ::connect(fd_, (struct sockaddr*)&addr, sizeof(addr));
    if (res < 0 && errno != EINPROGRESS) {
        close();
        return false;
    }

    if (res != 0) {
        struct pollfd pfd{};
        pfd.fd = fd_;
        pfd.events = POLLOUT;
        int poll_res = ::poll(&pfd, 1, timeout_ms);
        if (poll_res <= 0) {
            close();
            return false;
        }

        int err = 0;
        socklen_t len = sizeof(err);
        if (::getsockopt(fd_, SOL_SOCKET, SO_ERROR, &err, &len) < 0 || err != 0) {
            close();
            return false;
        }
    }

    // Restore blocking
    ::fcntl(fd_, F_SETFL, flags & ~O_NONBLOCK);
#endif
    return true;
}

bool TCPSocket::setNoDelay(bool enable) {
    if (fd_ < 0) return false;
    int opt = enable ? 1 : 0;
#ifdef _WIN32
    return ::setsockopt(static_cast<SOCKET>(fd_), IPPROTO_TCP, TCP_NODELAY, (const char*)&opt, sizeof(opt)) == 0;
#else
    return ::setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt)) == 0;
#endif
}

bool TCPSocket::setReadTimeout(int seconds) {
    if (fd_ < 0) return false;
#ifdef _WIN32
    DWORD ms = static_cast<DWORD>(seconds * 1000);
    return ::setsockopt(static_cast<SOCKET>(fd_), SOL_SOCKET, SO_RCVTIMEO, (const char*)&ms, sizeof(ms)) == 0;
#else
    struct timeval tv{};
    tv.tv_sec = seconds;
    tv.tv_usec = 0;
    return ::setsockopt(fd_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) == 0;
#endif
}

bool TCPSocket::setWriteTimeout(int seconds) {
    if (fd_ < 0) return false;
#ifdef _WIN32
    DWORD ms = static_cast<DWORD>(seconds * 1000);
    return ::setsockopt(static_cast<SOCKET>(fd_), SOL_SOCKET, SO_SNDTIMEO, (const char*)&ms, sizeof(ms)) == 0;
#else
    struct timeval tv{};
    tv.tv_sec = seconds;
    tv.tv_usec = 0;
    return ::setsockopt(fd_, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)) == 0;
#endif
}

bool TCPSocket::readFully(void* buf, size_t count) {
    if (fd_ < 0) return false;
    uint8_t* ptr = static_cast<uint8_t*>(buf);
    size_t remaining = count;
    while (remaining > 0) {
#ifdef _WIN32
        int n = ::recv(static_cast<SOCKET>(fd_), reinterpret_cast<char*>(ptr), static_cast<int>(std::min<size_t>(remaining, INT_MAX)), 0);
        if (n <= 0) {
            if (n < 0) {
                int wsa_err = WSAGetLastError();
                if (wsa_err == WSAEINTR || wsa_err == WSAEWOULDBLOCK) continue;
            }
            return false;
        }
#else
        ssize_t n = ::recv(fd_, ptr, remaining, 0);
        if (n <= 0) {
            if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            return false;
        }
#endif
        ptr += n;
        remaining -= n;
    }
    return true;
}

ssize_t TCPSocket::read(void* buf, size_t max_len) {
    if (fd_ < 0) return -1;
    while (true) {
#ifdef _WIN32
        int n = ::recv(static_cast<SOCKET>(fd_), reinterpret_cast<char*>(buf), static_cast<int>(std::min<size_t>(max_len, INT_MAX)), 0);
        if (n < 0 && WSAGetLastError() == WSAEINTR) continue;
        return n;
#else
        ssize_t n = ::recv(fd_, buf, max_len, 0);
        if (n < 0 && errno == EINTR) continue;
        return n;
#endif
    }
}

bool TCPSocket::writeAll(const void* buf, size_t count) {
    if (fd_ < 0) return false;
    const uint8_t* ptr = static_cast<const uint8_t*>(buf);
    size_t remaining = count;
    while (remaining > 0) {
#ifdef _WIN32
        int n = ::send(static_cast<SOCKET>(fd_), reinterpret_cast<const char*>(ptr), static_cast<int>(std::min<size_t>(remaining, INT_MAX)), MSG_NOSIGNAL);
        if (n <= 0) {
            if (n < 0) {
                int wsa_err = WSAGetLastError();
                if (wsa_err == WSAEINTR || wsa_err == WSAEWOULDBLOCK) continue;
            }
            return false;
        }
#else
        ssize_t n = ::send(fd_, ptr, remaining, MSG_NOSIGNAL);
        if (n <= 0) {
            if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            return false;
        }
#endif
        ptr += n;
        remaining -= n;
    }
    return true;
}

bool TCPSocket::writeString(const std::string& str) {
    return writeAll(str.data(), str.size());
}

} // namespace rplayhub
