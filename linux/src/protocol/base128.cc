#include "base128.h"
#include <cstring>

namespace rplayhub {

void Base128Writer::writeByte(uint8_t b) {
    data_.push_back(b);
}

void Base128Writer::writeUInt32(uint32_t value) {
    do {
        uint8_t b = static_cast<uint8_t>(value & 0x7F);
        value >>= 7;
        if (value != 0) b |= 0x80;
        data_.push_back(b);
    } while (value != 0);
}

void Base128Writer::writeInt32(int32_t value) {
    writeUInt32(static_cast<uint32_t>(value));
}

void Base128Writer::writeUInt64(uint64_t value) {
    do {
        uint8_t b = static_cast<uint8_t>(value & 0x7F);
        value >>= 7;
        if (value != 0) b |= 0x80;
        data_.push_back(b);
    } while (value != 0);
}

void Base128Writer::writeInt64(int64_t value) {
    writeUInt64(static_cast<uint64_t>(value));
}

void Base128Writer::writeBool(bool value) {
    data_.push_back(value ? 1 : 0);
}

void Base128Writer::writeFixed32(int32_t value) {
    uint32_t u = static_cast<uint32_t>(value);
    data_.push_back(static_cast<uint8_t>(u & 0xFF));
    data_.push_back(static_cast<uint8_t>((u >> 8) & 0xFF));
    data_.push_back(static_cast<uint8_t>((u >> 16) & 0xFF));
    data_.push_back(static_cast<uint8_t>((u >> 24) & 0xFF));
}

void Base128Writer::writeFloat(float value) {
    int32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(float));
    writeFixed32(bits);
}

// Convert UTF-8 to UTF-16 code units
static std::vector<uint16_t> utf8ToUtf16(const std::string& str) {
    std::vector<uint16_t> out;
    size_t i = 0;
    while (i < str.size()) {
        uint32_t cp = 0;
        uint8_t c = static_cast<uint8_t>(str[i]);
        if (c < 0x80) {
            cp = c;
            i += 1;
        } else if ((c & 0xE0) == 0xC0) {
            if (i + 1 >= str.size()) break;
            cp = (c & 0x1F) << 6 | (static_cast<uint8_t>(str[i + 1]) & 0x3F);
            i += 2;
        } else if ((c & 0xF0) == 0xE0) {
            if (i + 2 >= str.size()) break;
            cp = (c & 0x0F) << 12 | ((static_cast<uint8_t>(str[i + 1]) & 0x3F) << 6) | (static_cast<uint8_t>(str[i + 2]) & 0x3F);
            i += 3;
        } else if ((c & 0xF8) == 0xF0) {
            if (i + 3 >= str.size()) break;
            cp = (c & 0x07) << 18 | ((static_cast<uint8_t>(str[i + 1]) & 0x3F) << 12) | ((static_cast<uint8_t>(str[i + 2]) & 0x3F) << 6) | (static_cast<uint8_t>(str[i + 3]) & 0x3F);
            i += 4;
        } else {
            i += 1;
            continue;
        }

        if (cp <= 0xFFFF) {
            out.push_back(static_cast<uint16_t>(cp));
        } else {
            cp -= 0x10000;
            out.push_back(static_cast<uint16_t>((cp >> 10) + 0xD800));
            out.push_back(static_cast<uint16_t>((cp & 0x3FF) + 0xDC00));
        }
    }
    return out;
}

void Base128Writer::writeString16(const std::string& utf8_str) {
    auto u16 = utf8ToUtf16(utf8_str);
    writeUInt32(static_cast<uint32_t>(u16.size()));
    for (uint16_t unit : u16) {
        writeUInt32(unit);
    }
}

void Base128Writer::writeBytes(const std::string& str) {
    writeBytes(str.data(), str.size());
}

void Base128Writer::writeBytes(const void* data, size_t len) {
    writeUInt32(static_cast<uint32_t>(len));
    const uint8_t* p = static_cast<const uint8_t*>(data);
    data_.insert(data_.end(), p, p + len);
}

Base128Reader::Base128Reader(const uint8_t* data, size_t size)
    : data_(data), size_(size) {}

Base128Reader::Base128Reader(const std::vector<uint8_t>& data)
    : data_(data.data()), size_(data.size()) {}

bool Base128Reader::readUInt32(uint32_t& out_val) {
    out_val = 0;
    uint32_t shift = 0;
    while (true) {
        if (offset_ >= size_) return false;
        uint8_t b = data_[offset_++];
        out_val |= static_cast<uint32_t>(b & 0x7F) << shift;
        if ((b & 0x80) == 0) return true;
        shift += 7;
        if (shift >= 32) return false;
    }
}

bool Base128Reader::readInt32(int32_t& out_val) {
    uint32_t u = 0;
    if (!readUInt32(u)) return false;
    out_val = static_cast<int32_t>(u);
    return true;
}

bool Base128Reader::readBool(bool& out_val) {
    if (offset_ >= size_) return false;
    out_val = (data_[offset_++] != 0);
    return true;
}

} // namespace rplayhub
