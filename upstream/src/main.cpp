// uhdrtool — fuse a Lightroom direct-HDR float TIFF + an SDR JPEG into an
// UltraHDR (ISO 21496-1) gain-map JPEG, by calling libultrahdr in-process.
//
// This file is currently the CLI skeleton only: argument surface, --help, and
// --version. The TIFF reader, clamp computation, and the libultrahdr encode call
// are added by their respective OpenSpec changes (hdr-tiff-reader,
// ultrahdr-encoding). It links libultrahdr now so the build path is exercised
// end-to-end from the real source tree.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "ultrahdr_api.h"
#include "tiff_reader.h"
#include "encoder.h"

namespace {

constexpr char kToolVersion[] = "1.0.0";

void printUsage(const char* argv0) {
    std::printf(
        "uhdrtool %s — Lightroom HDR TIFF + SDR JPEG -> UltraHDR JPEG\n"
        "\n"
        "Usage:\n"
        "  %s --hdr <in.tif> --sdr <in.jpg> --out <out.jpg> [options]\n"
        "\n"
        "Required:\n"
        "  --hdr <path>     32-bit float direct-HDR TIFF (Maximize Compatibility OFF)\n"
        "  --sdr <path>     SDR JPEG (passed through as the primary image)\n"
        "  --out <path>     output UltraHDR JPEG\n"
        "\n"
        "Options:\n"
        "  --cgamut <0|1|2> HDR color gamut: 0 Rec.709 (default), 1 P3, 2 Rec.2020\n"
        "  --sgamut <0|1|2> SDR color gamut: 0 sRGB (default), 1 P3, 2 Rec.2020\n"
        "  --version        print version (incl. linked libultrahdr) and exit\n"
        "  --help           print this help and exit\n",
        kToolVersion, argv0);
}

void printVersion() {
    // UHDR_LIB_VERSION_STR comes from the linked libultrahdr header; printing it
    // confirms we are compiled against the vendored copy.
    std::printf("uhdrtool %s (libultrahdr %s)\n", kToolVersion, UHDR_LIB_VERSION_STR);
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        printUsage(argv[0]);
        return 2;
    }

    std::string hdrPath, sdrPath, outPath;
    std::string dumpRawPath;  // hidden: dump decoded RGBA f16 buffer for regression tests
    std::string rawHdrPath;   // app auto-mode: load a pre-synthesized RGBA f16 buffer
    int rawW = 0, rawH = 0;   // dimensions for --raw-hdr
    bool printClamps = false; // hidden: print computed -K/-L and stop
    int cgamut = 0;  // Rec.709
    int sgamut = 0;  // sRGB

    for (int i = 1; i < argc; ++i) {
        const char* a = argv[i];
        auto needValue = [&](const char* name) -> const char* {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "error: %s requires a value\n", name);
                return nullptr;
            }
            return argv[++i];
        };

        if (std::strcmp(a, "--help") == 0) {
            printUsage(argv[0]);
            return 0;
        } else if (std::strcmp(a, "--version") == 0) {
            printVersion();
            return 0;
        } else if (std::strcmp(a, "--hdr") == 0) {
            const char* v = needValue("--hdr"); if (!v) return 2; hdrPath = v;
        } else if (std::strcmp(a, "--sdr") == 0) {
            const char* v = needValue("--sdr"); if (!v) return 2; sdrPath = v;
        } else if (std::strcmp(a, "--out") == 0) {
            const char* v = needValue("--out"); if (!v) return 2; outPath = v;
        } else if (std::strcmp(a, "--cgamut") == 0) {
            const char* v = needValue("--cgamut"); if (!v) return 2; cgamut = std::atoi(v);
        } else if (std::strcmp(a, "--sgamut") == 0) {
            const char* v = needValue("--sgamut"); if (!v) return 2; sgamut = std::atoi(v);
        } else if (std::strcmp(a, "--dump-raw") == 0) {
            const char* v = needValue("--dump-raw"); if (!v) return 2; dumpRawPath = v;
        } else if (std::strcmp(a, "--raw-hdr") == 0) {
            const char* v = needValue("--raw-hdr"); if (!v) return 2; rawHdrPath = v;
        } else if (std::strcmp(a, "--raw-w") == 0) {
            const char* v = needValue("--raw-w"); if (!v) return 2; rawW = std::atoi(v);
        } else if (std::strcmp(a, "--raw-h") == 0) {
            const char* v = needValue("--raw-h"); if (!v) return 2; rawH = std::atoi(v);
        } else if (std::strcmp(a, "--print-clamps") == 0) {
            printClamps = true;
        } else {
            std::fprintf(stderr, "error: unknown argument '%s'\n", a);
            printUsage(argv[0]);
            return 2;
        }
    }

    if (hdrPath.empty() && rawHdrPath.empty()) {
        std::fprintf(stderr, "error: --hdr or --raw-hdr is required\n");
        return 2;
    }
    if (dumpRawPath.empty() && !printClamps && (sdrPath.empty() || outPath.empty())) {
        std::fprintf(stderr, "error: --hdr, --sdr, and --out are all required\n");
        return 2;
    }
    (void)cgamut;
    (void)sgamut;

    // --- obtain the RGBA half-float HDR buffer -------------------------------
    // Either by reading a direct-HDR float TIFF (--hdr), or by loading a
    // pre-synthesized RGBA f16 buffer from the app's auto-mode (--raw-hdr). The
    // raw layout is identical to what --dump-raw writes: w*h*4 IEEE-754 halfs.
    uhdrtool::HdrImage hdr;
    std::string err;
    if (!rawHdrPath.empty()) {
        if (rawW <= 0 || rawH <= 0) {
            std::fprintf(stderr, "error: --raw-hdr requires positive --raw-w and --raw-h\n");
            return 2;
        }
        std::FILE* rf = std::fopen(rawHdrPath.c_str(), "rb");
        if (!rf) {
            std::fprintf(stderr, "error: cannot open --raw-hdr '%s'\n", rawHdrPath.c_str());
            return 1;
        }
        std::fseek(rf, 0, SEEK_END);
        long rsz = std::ftell(rf);
        std::fseek(rf, 0, SEEK_SET);
        const size_t expected = static_cast<size_t>(rawW) * rawH * 4 * sizeof(uint16_t);
        if (rsz < 0 || static_cast<size_t>(rsz) != expected) {
            std::fclose(rf);
            std::fprintf(stderr, "error: --raw-hdr size %ld != expected %zu (w*h*4*2 bytes)\n",
                         rsz, expected);
            return 1;
        }
        hdr.width = rawW;
        hdr.height = rawH;
        hdr.rgba_f16.resize(static_cast<size_t>(rawW) * rawH * 4);
        const size_t got = std::fread(hdr.rgba_f16.data(), sizeof(uint16_t), hdr.rgba_f16.size(), rf);
        std::fclose(rf);
        if (got != hdr.rgba_f16.size()) {
            std::fprintf(stderr, "error: short read on --raw-hdr\n");
            return 1;
        }
    } else if (!uhdrtool::readDirectHdrTiff(hdrPath, hdr, err)) {
        std::fprintf(stderr, "error: %s\n", err.c_str());
        return 1;
    }
    std::fprintf(stderr, "hdr: %dx%d RGBA f16 (%zu bytes)\n",
                 hdr.width, hdr.height, hdr.rgba_f16.size() * sizeof(uint16_t));

    // Developer hook: write the raw RGBA f16 buffer and stop. Used by the
    // regression harness to compare against hdr_clamps.py --write byte-for-byte.
    if (!dumpRawPath.empty()) {
        std::FILE* f = std::fopen(dumpRawPath.c_str(), "wb");
        if (!f) {
            std::fprintf(stderr, "error: cannot open '%s' for writing\n", dumpRawPath.c_str());
            return 1;
        }
        std::fwrite(hdr.rgba_f16.data(), sizeof(uint16_t), hdr.rgba_f16.size(), f);
        std::fclose(f);
        return 0;
    }

    // --- compute the per-image gain-map clamps (-K / -L) ---------------------
    uhdrtool::Clamps clamps = uhdrtool::computeClamps(hdr);
    std::fprintf(stderr, "clamps: peak=%.3f (%.2f stops)  K=%.3f  L=%d\n",
                 clamps.peak_boost, clamps.stops, clamps.K, clamps.L);

    // Developer hook: print clamps as parseable key=value and stop. Used by the
    // regression harness to compare -K/-L against hdr_clamps.py.
    if (printClamps) {
        std::printf("peak=%.6f\nstops=%.6f\nK=%.3f\nL=%d\n",
                    clamps.peak_boost, clamps.stops, clamps.K, clamps.L);
        return 0;
    }

    // --- encode (scenario 3): fuse HDR buffer + SDR JPEG -> gain-map JPEG -----
    if (!uhdrtool::encodeUltraHdr(hdr, clamps, sdrPath, cgamut, sgamut, outPath, err)) {
        std::fprintf(stderr, "error: %s\n", err.c_str());
        return 1;
    }
    std::fprintf(stderr, "wrote %s\n", outPath.c_str());
    return 0;
}
