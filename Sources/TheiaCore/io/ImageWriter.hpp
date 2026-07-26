#pragma once
//
// Heightmap export. PRIVATE header.
//   - PFM: 32-bit float, lossless float data.
//   - PNG16: 16-bit grayscale image heightmap.
//   - R16: little-endian unsigned 16-bit RAW heightmap for engine import.
//   - PNG8/RGB8: lightweight preview and analysis-map helpers.
//
#include <cstdint>
#include <string>

namespace theia {

// Write a single-channel 32-bit float PFM. `data` is row-major, top row first;
// PFM stores bottom row first, so rows are flipped on write.
bool writePFM(const char* path, const float* data,
              std::uint32_t width, std::uint32_t height, std::string& error);

// Write an 8-bit grayscale PNG, normalizing [minV,maxV] -> [0,255].
bool writePNG8(const char* path, const float* data,
               std::uint32_t width, std::uint32_t height,
               float minV, float maxV, std::string& error);

// Write a 16-bit grayscale PNG, normalizing [minV,maxV] -> [0,65535]. Avoids the
// banding of 8-bit for heightmaps. Self-contained (stored-block DEFLATE), no
// external compression dependency.
bool writePNG16(const char* path, const float* data,
                std::uint32_t width, std::uint32_t height,
                float minV, float maxV, std::string& error);

// Write top-row-first little-endian unsigned 16-bit RAW heightmap, normalizing
// [minV,maxV] -> [0,65535]. This is the common R16 import path for engines.
bool writeR16(const char* path, const float* data,
              std::uint32_t width, std::uint32_t height,
              float minV, float maxV, std::string& error);

// Write top-row-first RGB8 PNG data.
bool writePNG8RGB(const char* path, const unsigned char* rgb,
                  std::uint32_t width, std::uint32_t height,
                  std::string& error);

} // namespace theia
