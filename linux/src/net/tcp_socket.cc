#include "tcp_socket.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>

namespace rplayhub {

TCPSocket::TCPSocket() : fd_(-1) {}

TCPSocket::TCPSocket(int fd) : fd_(fd) {}

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
        ::close(fd_);
        fd_ = -1;
    }
}

void TCPSocket::shutdownAndClose() {
    if (fd_ >= 0) {
        ::shutdown(fd_, SHUT_RDWR);
        ::close(fd_);
        fd_ = -1;
    }
}

bool TCPSocket::connect(const std::string& host, uint16_t port, int timeout_ms) {
    close();

    fd_ = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd_ < 0) return false;

    struct sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (::inet_pton(AF_INET, host.c_str(), &addr.sin_addr) <= 0) {
        close();
        return false;
    }

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
    return true;
}

bool TCPSocket::setNoDelay(bool enable) {
    if (fd_ < 0) return false;
    int opt = enable ? 1 : 0;
    return ::setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt)) == 0;
}

bool TCPSocket::setReadTimeout(int seconds) {
    if (fd_ < 0) return false;
    struct timeval tv{};
    tv.tv_sec = seconds;
    tv.tv_usec = 0;
    return ::setsockopt(fd_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) == 0;
}

bool TCPSocket::setWriteTimeout(int seconds) {
    if (fd_ < 0) return false;
    struct timeval tv{};
    tv.tv_sec = seconds;
    tv.tv_usec = 0;
    return ::setsockopt(fd_, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)) == 0;
}

bool TCPSocket::readFully(void* buf, size_t count) {
    if (fd_ < 0) return false;
    uint8_t* ptr = static_cast<uint8_t*>(buf);
    size_t remaining = count;
    while (remaining > 0) {
        ssize_t n = ::recv(fd_, ptr, remaining, 0);
        if (n <= 0) {
            if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            return false;
        }
        ptr += n;
        remaining -= n;
    }
    return true;
}

ssize_t TCPSocket::read(void* buf, size_t max_len) {
    if (fd_ < 0) return -1;
    while (true) {
        ssize_t n = ::recv(fd_, buf, max_len, 0);
        if (n < 0 && errno == EINTR) continue;
        return n;
    }
}

bool TCPSocket::writeAll(const void* buf, size_t count) {
    if (fd_ < 0) return false;
    const uint8_t* ptr = static_cast<const uint8_t*>(buf);
    size_t remaining = count;
    while (remaining > 0) {
        ssize_t n = ::send(fd_, ptr, remaining, MSG_NOSIGNAL);
        if (n <= 0) {
            if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            return false;
        }
        ptr += n;
        remaining -= n;
    }
    return true;
}

bool TCPSocket::writeString(const std::string& str) {
    return writeAll(str.data(), str.size());
}

} // namespace rplayhub
