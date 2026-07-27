# S1 encoder spike — evidence record

Date: 2026-07-27 · Machine: Apple Silicon Mac, Xcode 26.5 (17F42), cmake 4.1.2 (Homebrew), iOS SDK 26.5.
Pinned engine: libultrahdr `13a058f452d846e43d4691f6885eeeaa8b0ea8d0` + libjpeg-turbo 3.1.0 (fetched by the sub-build).

## 1. xcframework build — PASS (first attempt)

```
Gainmap/scripts/build-uhdr-xcframework.sh
→ Gainmap/Vendor/GainmapUHDR.xcframework  (macos-arm64, ios-arm64, ios-arm64-simulator; 5.4 MB)
```

The feared libjpeg-turbo cross-compile snag did not occur: per-slice toolchain files
(`Gainmap/scripts/toolchains/*.cmake`) carry every platform setting, and
`CMAKE_TOOLCHAIN_FILE` is the one variable libultrahdr forwards into the jpeg
ExternalProject (`UHDR_CMAKE_ARGS`, libultrahdr CMakeLists ~:404). No NASM needed
(arm64 NEON). `CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY` on the iOS slices.

## 2. macOS in-process parity — PASS, byte-identical

Harness: `Gainmap/scripts/spike/inprocess-parity.cpp` (links `upstream/src/encoder.cpp`
+ the macos slice). Input: deterministic 512×512 RGBA-f16 gradient + highlight blob
(`parity gen`), SDR base = `mockups/hdr-samples/p1_sdr.jpg` resampled to 512×512 (sips).

```
uhdrtool  --raw-hdr test.rawf16 --raw-w 512 --raw-h 512 --sdr test_sdr.jpg --out cli.jpg --cgamut 0 --sgamut 0
parity    encode    test.rawf16 512 512 test_sdr.jpg mem.jpg 0 0
```

Both printed `clamps: peak=4.527 (2.18 stops)  K=4.754  L=919`.
`cmp cli.jpg mem.jpg` → **byte-identical** (CLI here is the committed
`Gainmap/Resources/Helpers/uhdrtool`, i.e. the shipping Mac binary).

## 3. iOS simulator link + encode — PASS, byte-identical

```
clang++ -std=c++17 -O2 -arch arm64 -isysroot $(xcrun --sdk iphonesimulator --show-sdk-path) \
  -mios-simulator-version-min=17.0 inprocess-parity.cpp encoder.cpp \
  -I upstream/src -I <xcframework>/ios-arm64-simulator/Headers \
  <xcframework>/ios-arm64-simulator/libGainmapUHDR.a -o parity-sim        # links ✅
clang++ ... -isysroot $(xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=17.0 \
  ... ios-arm64/libGainmapUHDR.a -o parity-device                          # links ✅

xcrun simctl boot C361367C-64ED-43D6-9DFE-0853D572E54E
xcrun simctl spawn <udid> /abs/path/parity-sim encode /abs/test.rawf16 512 512 \
  /abs/test_sdr.jpg /abs/sim.jpg 0 0     # NOTE: absolute paths — spawn cwd differs
cmp cli.jpg sim.jpg                       # → byte-identical ✅
```

Same clamps line as macOS. The iOS-simulator build of the engine is byte-identical
to the shipping macOS CLI on identical input.

## 4. No tiled/streaming encode API — CONFIRMED

`grep -i 'tile|stripe|chunk|partial' ultrahdr_api.h` → no encode-related hits; the
encoder takes one whole `uhdr_raw_image_t`. The iOS memory strategy (histogram
`computeClamps` + downscale cap) stands. `uhdr_get_encoded_stream()` exists →
P2's memory-out overload has a first-class SDK path.

## 5. Clean-rebuild reproducibility

First check (before `ZERO_AR_DATE`): clean rebuild produced differing archive
hashes — `ar`/`libtool` embed member mtimes; expected nondeterminism, not a code
difference. Fix: `export ZERO_AR_DATE=1` in the build script.
Methodology: two consecutive from-clean builds (work dir wiped between) must
hash-match each other, and the rebuilt macos slice must still be byte-identical
to the CLI via the §2 harness.

Result: **PASS.** Two consecutive from-clean builds (work dir wiped between) produced
hash-identical slices, and the rebuilt macos slice re-verified byte-identical to the
CLI via the §2 harness (same clamps, `cmp` clean). Canonical committed hashes (SHA-256):

```
e20b803bd8ed84adbfbbe84adee56f4f5db5cd693e6e4def3d7f41d5a8cfd862  ios-arm64-simulator/libGainmapUHDR.a
d4a9ffafddc0c2c683d82a6d9b0d7c7a97caf532674d0e75c86007289a90e668  ios-arm64/libGainmapUHDR.a
44369e99f8e52813e8118cf0f793c6d47e577fb212ceec9a730c7efed6b0b9b7  macos-arm64/libGainmapUHDR.a
```

## 6. Open items (S1 not closed until these are recorded)

- [x] §5 determinism result — PASS (above)
- [ ] One `parity-device` encode on a physical iPhone (needs the device; binary is built)
- [ ] `bloomCIImage` Mac-vs-device f16 max-abs-diff → sets the CI-parity tolerance for P2's test ladder
