#!/bin/bash
# Builds Gainmap/Vendor/GainmapUHDR.xcframework: libultrahdr + libjpeg-turbo
# merged into one static lib per slice (ios-arm64, ios-arm64-simulator,
# macos-arm64), from the pinned libultrahdr commit.
#
# libultrahdr FATAL_ERRORs on a multi-arch CMAKE_OSX_ARCHITECTURES, so each
# slice is a separate CMake build combined by xcodebuild -create-xcframework.
# All platform settings live in per-slice toolchain files (scripts/toolchains/)
# because only CMAKE_TOOLCHAIN_FILE is forwarded into the libjpeg-turbo
# ExternalProject sub-build.
#
# Usage: build-uhdr-xcframework.sh
#   UHDR_SRC=<path>  override the libultrahdr source checkout
set -euo pipefail

# Deterministic archives: without this, ar/libtool embed member mtimes and
# two identical builds hash differently, making reproducibility unverifiable.
export ZERO_AR_DATE=1

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN=13a058f452d846e43d4691f6885eeeaa8b0ea8d0
UHDR_SRC="${UHDR_SRC:-$ROOT/build/_deps/libultrahdr-src}"
WORK="$ROOT/build/uhdr-xcframework"
OUT="$ROOT/Gainmap/Vendor/GainmapUHDR.xcframework"
TOOLCHAINS="$ROOT/Gainmap/scripts/toolchains"
JOBS="$(sysctl -n hw.ncpu)"

if [[ ! -d "$UHDR_SRC" ]]; then
  echo "libultrahdr source not found at $UHDR_SRC" >&2
  echo "Fetch it: git clone https://github.com/google/libultrahdr \"$UHDR_SRC\" && git -C \"$UHDR_SRC\" checkout $PIN" >&2
  exit 1
fi
ACTUAL="$(git -C "$UHDR_SRC" rev-parse HEAD)"
if [[ "$ACTUAL" != "$PIN" ]]; then
  echo "libultrahdr at $UHDR_SRC is $ACTUAL, expected pinned $PIN" >&2
  exit 1
fi

build_slice() {
  local tag="$1" toolchain="$2"
  local bdir="$WORK/$tag"
  echo "=== [$tag] configure ==="
  cmake -B "$bdir" -S "$UHDR_SRC" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAINS/$toolchain" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF \
    -DUHDR_BUILD_DEPS=ON \
    -DUHDR_WRITE_XMP=ON \
    -DUHDR_WRITE_ISO=ON \
    -DUHDR_BUILD_EXAMPLES=OFF \
    -DUHDR_BUILD_TESTS=OFF \
    -DUHDR_BUILD_BENCHMARK=OFF \
    -DUHDR_BUILD_FUZZERS=OFF
  echo "=== [$tag] build ==="
  cmake --build "$bdir" --target uhdr -j "$JOBS"
  echo "=== [$tag] merge static libs ==="
  mkdir -p "$WORK/lib/$tag"
  libtool -static -o "$WORK/lib/$tag/libGainmapUHDR.a" \
    "$bdir/libuhdr.a" \
    "$bdir/turbojpeg/src/turbojpeg-build/libjpeg.a"
  lipo -info "$WORK/lib/$tag/libGainmapUHDR.a"
}

build_slice macos-arm64          macos.cmake
build_slice ios-arm64            ios-device.cmake
build_slice ios-arm64-simulator  ios-simulator.cmake

echo "=== headers ==="
mkdir -p "$WORK/include"
cp "$UHDR_SRC/ultrahdr_api.h" "$WORK/include/"

echo "=== create xcframework ==="
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
  -library "$WORK/lib/macos-arm64/libGainmapUHDR.a"         -headers "$WORK/include" \
  -library "$WORK/lib/ios-arm64/libGainmapUHDR.a"           -headers "$WORK/include" \
  -library "$WORK/lib/ios-arm64-simulator/libGainmapUHDR.a" -headers "$WORK/include" \
  -output "$OUT"

echo "=== done ==="
ls -la "$OUT"
