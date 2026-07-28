// Clamp computation + libultrahdr "encode scenario 3": fuse the linear
// half-float HDR buffer with the user's SDR JPEG into a gain-map (UltraHDR) JPEG.
//
// The -K/-L clamp math is ported from the Python oracle (hdr_clamps.py) and must
// match it numerically. The encode call sequence is the transcription of the
// uhdrtool-encoder OpenSpec design (E1-E4).
//
// P2 (in-process encoding): the clamp computation is histogram-based — samples
// are IEEE-754 halfs, so a 65,536-bin bit-pattern histogram (256 KB) yields the
// EXACT order statistics the old sort-all-samples implementation produced from
// a w*h*3 float vector (~576 MB at 48 MP — the iPhone-viability fix). The old
// implementation is retained as computeClampsReference, the parity oracle. The
// encode core is memory-in/memory-out (encodeUltraHdrToMemory) so the app can
// encode without temp files; the file-based wrapper remains for the CLI.
#ifndef UHDRTOOL_ENCODER_H
#define UHDRTOOL_ENCODER_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "tiff_reader.h"

namespace uhdrtool {

// Zero-copy view over an externally-owned interleaved RGBA f16 buffer
// (row-major, 4 halfs per pixel, sized width*height*4).
struct RawF16View {
    const uint16_t* rgba_f16 = nullptr;
    int width = 0;
    int height = 0;
};

// Per-image gain-map clamps derived from the HDR pixels.
struct Clamps {
    double peak_boost = 1.0;  // high-percentile linear value, floored at 1.0
    double stops = 0.0;       // log2(peak_boost)
    double K = 1.0;           // max content boost = peak_boost * margin (3 dp)
    int L = 203;              // target display peak nits = clamp(203*peak, 203, 10000)
};

// Compute -K/-L from the RGBA f16 buffer. `percentile` (default 99.9) and
// `margin` (1.05) are fixed constants, matching the oracle. Mirrors numpy's
// np.percentile(linear-interpolation) over the R,G,B samples. Histogram-based:
// bit-exact with computeClampsReference for NaN-free input; NaN samples are
// excluded from the population (the reference's ordering of NaN was undefined).
Clamps computeClamps(const RawF16View& img, double percentile = 99.9, double margin = 1.05);
Clamps computeClamps(const HdrImage& img, double percentile = 99.9, double margin = 1.05);

// The original sort-all-samples implementation, kept ONLY as the parity oracle
// for the histogram version (see inprocess-parity.cpp clamps-selftest).
Clamps computeClampsReference(const RawF16View& img, double percentile = 99.9, double margin = 1.05);

// Encode scenario 3, memory-in/memory-out: takes the SDR JPEG bytes (passed
// through untouched, never decoded) and fills `out` with the gain-map JPEG.
// Returns true on success; on failure fills `error` (same messages the CLI
// prints after "error: ").
bool encodeUltraHdrToMemory(const RawF16View& hdr, const Clamps& clamps,
                            const uint8_t* sdrJpeg, size_t sdrJpegSize,
                            int hdrCgamut, int sdrCgamut,
                            std::vector<uint8_t>& out, std::string& error);

// File-based wrapper (the CLI path). `hdrCgamut`/`sdrCgamut` are the libultrahdr
// color-gamut enum values (0/1/2). Reads `sdrJpegPath` bytes, encodes, and
// writes the gain-map JPEG to `outPath`.
bool encodeUltraHdr(const HdrImage& hdr, const Clamps& clamps,
                    const std::string& sdrJpegPath, int hdrCgamut, int sdrCgamut,
                    const std::string& outPath, std::string& error);

}  // namespace uhdrtool

#endif  // UHDRTOOL_ENCODER_H
