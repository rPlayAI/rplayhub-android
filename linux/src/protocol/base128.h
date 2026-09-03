#pragma once

#include <vector>
#include <string>
#include <cstdint>
#include <cstddef>

namespace rplayhub {

class Base128Writer {
public:
    Base128Writer() = default;

    void writeByte(uint8_t b);
    void writeUInt32(uint32_t value);
    void writeInt32(int32_t value);
    void writeUInt64(uint64_t value);
    void writeInt64(int64_t value);
    void writeBool(bool value);
    void writeFixed32(int32_t value);
    void writeFloat(float value);
    void writeString16(const std::string& utf8_str);
    void writeBytes(const std::string& str);
    void writeBytes(const void* data, size_t len);

    const std::vector<uint8_t>& data() const { return data_; }
    void clear() { data_.clear(); }

private:
    std::vector<uint8_t> data_;
};

class Base128Reader {
public:
    Base128Reader(const uint8_t* data, size_t size);
    explicit Base128Reader(const std::vector<uint8_t>& data);

    bool hasMore() const { return offset_ < size_; }
    bool readUInt32(uint32_t& out_val);
    bool readInt32(int32_t& out_val);
    bool readBool(bool& out_val);

private:
    const uint8_t* data_;
    size_t size_;
    size_t offset_ = 0;
};

} // namespace rplayhub
