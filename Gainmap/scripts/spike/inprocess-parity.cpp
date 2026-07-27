// S1 spike harness: proves the in-process encoder path produces byte-identical
// output to the uhdrtool CLI on the same inputs.
//
//   gen    <out.rawf16> <w> <h>                       deterministic f16 RGBA buffer
//   encode <raw> <w> <h> <sdr.jpg> <out.jpg> <cg> <sg>  computeClamps + encodeUltraHdr
//
// Links: encoder.cpp + tiff_reader.cpp + libGainmapUHDR.a (the xcframework slice).
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "encoder.h"
#include "tiff_reader.h"

static uint16_t floatToHalfBits(float f) {
    __fp16 h = (__fp16)f;
    uint16_t bits;
    std::memcpy(&bits, &h, sizeof(bits));
    return bits;
}

static int gen(const char* path, int w, int h) {
    std::vector<uint16_t> buf((size_t)w * h * 4);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            size_t i = ((size_t)y * w + x) * 4;
            // Gradient base with a synthetic highlight blob peaking ~4.0 linear,
            // exercising >1.0 values, the 99.9th percentile path, and full range.
            float fx = (float)x / (w - 1), fy = (float)y / (h - 1);
            float base = 0.05f + 0.9f * fx;
            float dx = fx - 0.7f, dy = fy - 0.3f;
            float blob = 4.0f * (float)std::max(0.0, 1.0 - 40.0 * (dx * dx + dy * dy));
            buf[i + 0] = floatToHalfBits(base + blob);
            buf[i + 1] = floatToHalfBits(base * 0.8f + blob * 0.9f);
            buf[i + 2] = floatToHalfBits(base * 0.6f + blob * 0.7f);
            buf[i + 3] = floatToHalfBits(1.0f);
        }
    }
    FILE* f = std::fopen(path, "wb");
    if (!f) { std::perror("fopen"); return 1; }
    std::fwrite(buf.data(), sizeof(uint16_t), buf.size(), f);
    std::fclose(f);
    std::printf("wrote %s (%dx%d, %zu bytes)\n", path, w, h, buf.size() * 2);
    return 0;
}

static int encode(const char* rawPath, int w, int h, const char* sdrPath,
                  const char* outPath, int cg, int sg) {
    using namespace uhdrtool;
    HdrImage img;
    img.width = w;
    img.height = h;
    img.rgba_f16.resize((size_t)w * h * 4);
    FILE* f = std::fopen(rawPath, "rb");
    if (!f) { std::perror("fopen raw"); return 1; }
    size_t n = std::fread(img.rgba_f16.data(), sizeof(uint16_t), img.rgba_f16.size(), f);
    std::fclose(f);
    if (n != img.rgba_f16.size()) { std::fprintf(stderr, "short read\n"); return 1; }

    Clamps clamps = computeClamps(img);
    std::fprintf(stderr, "clamps: peak=%.3f (%.2f stops)  K=%.3f  L=%d\n",
                 clamps.peak_boost, clamps.stops, clamps.K, clamps.L);

    std::string err;
    if (!encodeUltraHdr(img, clamps, sdrPath, cg, sg, outPath, err)) {
        std::fprintf(stderr, "error: %s\n", err.c_str());
        return 1;
    }
    std::printf("encoded %s\n", outPath);
    return 0;
}

int main(int argc, char** argv) {
    if (argc >= 5 && std::strcmp(argv[1], "gen") == 0)
        return gen(argv[2], std::atoi(argv[3]), std::atoi(argv[4]));
    if (argc >= 9 && std::strcmp(argv[1], "encode") == 0)
        return encode(argv[2], std::atoi(argv[3]), std::atoi(argv[4]),
                      argv[5], argv[6], std::atoi(argv[7]), std::atoi(argv[8]));
    std::fprintf(stderr,
        "usage:\n  %s gen <out.rawf16> <w> <h>\n"
        "  %s encode <raw> <w> <h> <sdr.jpg> <out.jpg> <cgamut> <sgamut>\n",
        argv[0], argv[0]);
    return 2;
}
