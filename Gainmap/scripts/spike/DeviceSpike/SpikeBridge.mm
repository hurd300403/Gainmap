#import "SpikeBridge.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "encoder.h"

char *spike_encode(const char *rawPath, int width, int height,
                   const char *sdrPath, const char *outPath) {
    using namespace uhdrtool;
    HdrImage img;
    img.width = width;
    img.height = height;
    img.rgba_f16.resize((size_t)width * height * 4);
    FILE *f = std::fopen(rawPath, "rb");
    if (!f) return strdup("error: fopen raw failed");
    size_t n = std::fread(img.rgba_f16.data(), sizeof(uint16_t), img.rgba_f16.size(), f);
    std::fclose(f);
    if (n != img.rgba_f16.size()) return strdup("error: short raw read");

    Clamps clamps = computeClamps(img);
    std::string err;
    if (!encodeUltraHdr(img, clamps, sdrPath, 0, 0, outPath, err)) {
        std::string msg = "error: " + err;
        return strdup(msg.c_str());
    }
    char buf[160];
    std::snprintf(buf, sizeof(buf), "clamps: peak=%.3f (%.2f stops)  K=%.3f  L=%d",
                  clamps.peak_boost, clamps.stops, clamps.K, clamps.L);
    return strdup(buf);
}
