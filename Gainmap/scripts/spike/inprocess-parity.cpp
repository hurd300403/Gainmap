// S1/P2 harness: proves the in-process encoder path produces byte-identical
// output to the uhdrtool CLI on the same inputs, and that the histogram
// computeClamps is bit-exact with the sort-all-samples reference.
//
//   gen        <out.rawf16> <w> <h>                     deterministic f16 RGBA buffer
//   encode     <raw> <w> <h> <sdr.jpg> <out.jpg> <cg> <sg>  file-API: computeClamps + encodeUltraHdr
//   encode-mem <raw> <w> <h> <sdr.jpg> <out.jpg> <cg> <sg>  memory-API: encodeUltraHdrToMemory
//   clamps-selftest                                     histogram vs reference, edge cases incl.
//                                                       negatives/subnormals/Inf/NaN — exits non-zero on any mismatch
//
// Links: encoder.cpp + tiff_reader.cpp (unused decl) + libGainmapUHDR.a (xcframework slice).
#include <algorithm>
#include <cmath>
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

static bool loadRaw(const char* rawPath, int w, int h, uhdrtool::HdrImage& img) {
    img.width = w;
    img.height = h;
    img.rgba_f16.resize((size_t)w * h * 4);
    FILE* f = std::fopen(rawPath, "rb");
    if (!f) { std::perror("fopen raw"); return false; }
    size_t n = std::fread(img.rgba_f16.data(), sizeof(uint16_t), img.rgba_f16.size(), f);
    std::fclose(f);
    if (n != img.rgba_f16.size()) { std::fprintf(stderr, "short read\n"); return false; }
    return true;
}

static int encode(const char* rawPath, int w, int h, const char* sdrPath,
                  const char* outPath, int cg, int sg) {
    using namespace uhdrtool;
    HdrImage img;
    if (!loadRaw(rawPath, w, h, img)) return 1;

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

// Memory-API twin of `encode`: same inputs, but the SDR JPEG is read into memory
// here and the encoded bytes come back as a vector — the exact path the app's
// InProcessEncoder takes. Output must be byte-identical to `encode`'s.
static int encodeMem(const char* rawPath, int w, int h, const char* sdrPath,
                     const char* outPath, int cg, int sg) {
    using namespace uhdrtool;
    HdrImage img;
    if (!loadRaw(rawPath, w, h, img)) return 1;

    FILE* jf = std::fopen(sdrPath, "rb");
    if (!jf) { std::perror("fopen sdr"); return 1; }
    std::fseek(jf, 0, SEEK_END);
    long jsz = std::ftell(jf);
    std::fseek(jf, 0, SEEK_SET);
    std::vector<uint8_t> jpeg((size_t)jsz);
    if (std::fread(jpeg.data(), 1, jpeg.size(), jf) != jpeg.size()) {
        std::fclose(jf); std::fprintf(stderr, "short read sdr\n"); return 1;
    }
    std::fclose(jf);

    RawF16View view{img.rgba_f16.data(), img.width, img.height};
    Clamps clamps = computeClamps(view);
    std::fprintf(stderr, "clamps: peak=%.3f (%.2f stops)  K=%.3f  L=%d\n",
                 clamps.peak_boost, clamps.stops, clamps.K, clamps.L);

    std::vector<uint8_t> out;
    std::string err;
    if (!encodeUltraHdrToMemory(view, clamps, jpeg.data(), jpeg.size(), cg, sg, out, err)) {
        std::fprintf(stderr, "error: %s\n", err.c_str());
        return 1;
    }
    FILE* of = std::fopen(outPath, "wb");
    if (!of) { std::perror("fopen out"); return 1; }
    std::fwrite(out.data(), 1, out.size(), of);
    std::fclose(of);
    std::printf("encoded (memory API) %s\n", outPath);
    return 0;
}

// ---------------------------------------------------------------------------
// clamps-selftest: histogram computeClamps vs computeClampsReference, exact.
// ---------------------------------------------------------------------------

namespace selftest {

struct Case {
    std::string name;
    int w = 0, h = 0;
    std::vector<uint16_t> buf;  // w*h*4 halfs
    bool hasNaN = false;        // reference is UB with NaN → compare vs filtered oracle
};

static void push(Case& c, float r, float g, float b) {
    c.buf.push_back(floatToHalfBits(r));
    c.buf.push_back(floatToHalfBits(g));
    c.buf.push_back(floatToHalfBits(b));
    c.buf.push_back(floatToHalfBits(1.0f));
}

// Naive oracle with NaN filtered out — defines expected behavior for NaN cases
// (identical to the reference for NaN-free input).
static uhdrtool::Clamps filteredOracle(const Case& c, double percentile, double margin) {
    std::vector<float> rgb;
    const size_t pixels = (size_t)c.w * c.h;
    for (size_t p = 0; p < pixels; ++p) {
        for (int k = 0; k < 3; ++k) {
            uint16_t hbits = c.buf[p * 4 + k];
            bool nan = ((hbits >> 10) & 0x1fu) == 0x1fu && (hbits & 0x3ffu) != 0;
            if (nan) continue;
            __fp16 hval;
            std::memcpy(&hval, &hbits, 2);
            rgb.push_back((float)hval);
        }
    }
    // Percentile over the filtered population, same algorithm as the reference.
    uhdrtool::Clamps out;
    double peak;
    if (rgb.empty()) {
        peak = 1.0;
    } else if (rgb.size() == 1) {
        peak = rgb[0];
    } else {
        std::vector<float> v = rgb;
        double virt = (percentile / 100.0) * (double)(v.size() - 1);
        size_t lo = (size_t)std::floor(virt);
        double frac = virt - (double)lo;
        std::nth_element(v.begin(), v.begin() + lo, v.end());
        double vlo = v[lo];
        if (frac == 0.0) {
            peak = vlo;
        } else {
            double vhi = *std::min_element(v.begin() + lo + 1, v.end());
            peak = vlo + frac * (vhi - vlo);
        }
    }
    if (peak < 1.0) peak = 1.0;
    out.peak_boost = peak;
    out.stops = std::log2(peak);
    // K/L math copied from encoder.cpp's constants (round-half-even, 3 dp / 0 dp).
    auto rhe = [](double x, int decimals) {
        double scale = std::pow(10.0, decimals);
        double scaled = x * scale;
        double floorv = std::floor(scaled);
        double diff = scaled - floorv;
        double r;
        if (diff > 0.5) r = floorv + 1.0;
        else if (diff < 0.5) r = floorv;
        else r = (std::fmod(floorv, 2.0) == 0.0) ? floorv : floorv + 1.0;
        return r / scale;
    };
    out.K = rhe(peak * margin, 3);
    double l = std::min(10000.0, std::max(203.0, 203.0 * peak));
    out.L = (int)rhe(l, 0);
    return out;
}

static bool clampsEqual(const uhdrtool::Clamps& a, const uhdrtool::Clamps& b) {
    return a.peak_boost == b.peak_boost && a.stops == b.stops &&
           a.K == b.K && a.L == b.L;
}

static int run() {
    using namespace uhdrtool;
    std::vector<Case> cases;

    {   // 1. gradient + blob (the gen pattern), odd dimensions
        Case c; c.name = "gradient-blob 313x217"; c.w = 313; c.h = 217;
        for (int y = 0; y < c.h; ++y) for (int x = 0; x < c.w; ++x) {
            float fx = (float)x / (c.w - 1), fy = (float)y / (c.h - 1);
            float base = 0.05f + 0.9f * fx;
            float dx = fx - 0.7f, dy = fy - 0.3f;
            float blob = 4.0f * (float)std::max(0.0, 1.0 - 40.0 * (dx * dx + dy * dy));
            push(c, base + blob, base * 0.8f + blob * 0.9f, base * 0.6f + blob * 0.7f);
        }
        cases.push_back(std::move(c));
    }
    {   // 2. uniform bright
        Case c; c.name = "uniform 3.25"; c.w = 64; c.h = 48;
        for (int i = 0; i < c.w * c.h; ++i) push(c, 3.25f, 3.25f, 3.25f);
        cases.push_back(std::move(c));
    }
    {   // 3. all zeros
        Case c; c.name = "zeros"; c.w = 32; c.h = 32;
        for (int i = 0; i < c.w * c.h; ++i) push(c, 0, 0, 0);
        cases.push_back(std::move(c));
    }
    {   // 4. negatives mixed in (raw-buffer path never clips)
        Case c; c.name = "negatives"; c.w = 100; c.h = 50;
        for (int i = 0; i < c.w * c.h; ++i) {
            float t = (float)i / (c.w * c.h);
            push(c, -0.5f + 2.0f * t, 0.25f - t, 1.5f * t - 0.2f);
        }
        cases.push_back(std::move(c));
    }
    {   // 5. subnormal halfs (bit patterns 0x0001..0x03FF) + tiny normals
        Case c; c.name = "subnormals"; c.w = 128; c.h = 8;
        for (int i = 0; i < c.w * c.h; ++i) {
            uint16_t sub = (uint16_t)(1 + (i % 0x3FF));           // subnormal
            uint16_t tiny = (uint16_t)(0x0400 + (i % 0x0400));    // small normal
            c.buf.push_back(sub);
            c.buf.push_back(tiny);
            c.buf.push_back(floatToHalfBits(0.5f));
            c.buf.push_back(floatToHalfBits(1.0f));
        }
        cases.push_back(std::move(c));
    }
    {   // 6. +Inf / -Inf sprinkled
        Case c; c.name = "infinities"; c.w = 64; c.h = 64;
        for (int i = 0; i < c.w * c.h; ++i) {
            if (i % 511 == 0) {
                c.buf.push_back(0x7C00);                          // +Inf
                c.buf.push_back(0xFC00);                          // -Inf
                c.buf.push_back(floatToHalfBits(2.0f));
                c.buf.push_back(floatToHalfBits(1.0f));
            } else {
                push(c, 0.8f, 1.2f, 0.4f);
            }
        }
        cases.push_back(std::move(c));
    }
    {   // 7. deterministic LCG over all non-NaN bit patterns (stress)
        Case c; c.name = "lcg-stress 256x256"; c.w = 256; c.h = 256;
        uint32_t s = 0x12345678u;
        auto next = [&]() {
            s = s * 1664525u + 1013904223u;
            uint16_t hbits = (uint16_t)(s >> 13);
            if (((hbits >> 10) & 0x1f) == 0x1f && (hbits & 0x3ff) != 0) hbits = 0x3C00; // NaN→1.0
            return hbits;
        };
        for (int i = 0; i < c.w * c.h; ++i) {
            c.buf.push_back(next());
            c.buf.push_back(next());
            c.buf.push_back(next());
            c.buf.push_back(floatToHalfBits(1.0f));
        }
        cases.push_back(std::move(c));
    }
    {   // 8. single pixel
        Case c; c.name = "single-pixel"; c.w = 1; c.h = 1;
        push(c, 2.5f, 0.5f, 1.0f);
        cases.push_back(std::move(c));
    }
    {   // 9. one row
        Case c; c.name = "one-row 1x977"; c.w = 977; c.h = 1;
        for (int i = 0; i < c.w; ++i) push(c, 0.001f * i, 0.002f * i, 0.003f * i);
        cases.push_back(std::move(c));
    }
    {   // 10. all sub-white (peak floors at 1.0)
        Case c; c.name = "sub-white"; c.w = 40; c.h = 40;
        for (int i = 0; i < c.w * c.h; ++i) push(c, 0.5f, 0.3f, 0.7f);
        cases.push_back(std::move(c));
    }
    {   // 11. NaN samples (histogram defines: excluded; compared vs filtered oracle)
        Case c; c.name = "nan-mixed"; c.w = 48; c.h = 48; c.hasNaN = true;
        for (int i = 0; i < c.w * c.h; ++i) {
            if (i % 97 == 0) {
                c.buf.push_back(0x7E00);                          // qNaN
                c.buf.push_back(floatToHalfBits(1.5f));
                c.buf.push_back(0xFE00);                          // -qNaN
                c.buf.push_back(floatToHalfBits(1.0f));
            } else {
                push(c, 0.6f + 0.001f * (i % 100), 1.1f, 0.9f);
            }
        }
        cases.push_back(std::move(c));
    }

    int failures = 0;
    for (const auto& c : cases) {
        RawF16View v{c.buf.data(), c.w, c.h};
        Clamps hist = computeClamps(v);
        Clamps expect = c.hasNaN ? filteredOracle(c, 99.9, 1.05)
                                 : computeClampsReference(v);
        bool ok = clampsEqual(hist, expect);
        std::printf("%-22s hist: peak=%.9f K=%.3f L=%d  %s\n",
                    c.name.c_str(), hist.peak_boost, hist.K, hist.L,
                    ok ? "OK" : "MISMATCH");
        if (!ok) {
            std::printf("  expected: peak=%.17g stops=%.17g K=%.17g L=%d\n",
                        expect.peak_boost, expect.stops, expect.K, expect.L);
            std::printf("  got:      peak=%.17g stops=%.17g K=%.17g L=%d\n",
                        hist.peak_boost, hist.stops, hist.K, hist.L);
            ++failures;
        }
    }
    std::printf("%s (%zu cases, %d failures)\n",
                failures == 0 ? "CLAMPS SELFTEST PASS" : "CLAMPS SELFTEST FAIL",
                cases.size(), failures);
    return failures == 0 ? 0 : 1;
}

}  // namespace selftest

int main(int argc, char** argv) {
    if (argc >= 5 && std::strcmp(argv[1], "gen") == 0)
        return gen(argv[2], std::atoi(argv[3]), std::atoi(argv[4]));
    if (argc >= 9 && std::strcmp(argv[1], "encode") == 0)
        return encode(argv[2], std::atoi(argv[3]), std::atoi(argv[4]),
                      argv[5], argv[6], std::atoi(argv[7]), std::atoi(argv[8]));
    if (argc >= 9 && std::strcmp(argv[1], "encode-mem") == 0)
        return encodeMem(argv[2], std::atoi(argv[3]), std::atoi(argv[4]),
                         argv[5], argv[6], std::atoi(argv[7]), std::atoi(argv[8]));
    if (argc >= 2 && std::strcmp(argv[1], "clamps-selftest") == 0)
        return selftest::run();
    std::fprintf(stderr,
        "usage:\n  %s gen <out.rawf16> <w> <h>\n"
        "  %s encode <raw> <w> <h> <sdr.jpg> <out.jpg> <cgamut> <sgamut>\n"
        "  %s encode-mem <raw> <w> <h> <sdr.jpg> <out.jpg> <cgamut> <sgamut>\n"
        "  %s clamps-selftest\n",
        argv[0], argv[0], argv[0], argv[0]);
    return 2;
}
