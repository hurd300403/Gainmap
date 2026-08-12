# SDR→HDR — UltraHDR for macOS (Legacy Lab)

A macOS port of [filippo-nassini/lightroom-ultrahdr](https://github.com/filippo-nassini/lightroom-ultrahdr).
Fuses a Lightroom **SDR** edit and its **HDR** edit into one UltraHDR (ISO 21496-1)
gain-map JPEG — HDR where supported, a clean SDR fallback everywhere else.

Two deliverables share one native engine (`uhdrtool`, built on Google's libultrahdr):

| | What | Artifact |
|---|---|---|
| **A. Lightroom plugin** | The original integrated workflow, now with a Mac binary. Select the SDR photo + its HDR virtual copy → File ▸ Plug-in Extras ▸ Merge. | `dist/Lightroom-UltraHDR-mac.zip` |
| **B. Gainmap.app** | A standalone, branded SwiftUI app. Drop the exported HDR `.tif` + SDR `.jpg`, click Merge. | `dist/Gainmap.dmg` |

## Layout

```
sdrhdr/
  upstream/                     # the original repo (C++ tool + Lua plugin)
  build/                        # cmake build output (uhdrtool)
  mockups/gainmap.html          # the design spec for the app UI
  Gainmap/                      # the standalone macOS app (open Gainmap.xcodeproj)
    project.yml                 # XcodeGen spec (regenerate with `xcodegen generate`)
    Gainmap.xcodeproj           # ← open this in Xcode; ⌘R to run, ⌘U to test
    Sources/                    # SwiftUI app + UHDRRunner engine wrapper
    Tests/GainmapTests/         # XCTest unit tests (the ⌘U suite)
    Resources/                  # Assets.xcassets (icon), Fonts/, Helpers/uhdrtool
    Icon/                       # gainmap-icon.svg → rendered AppIcon PNGs
    scripts/build-binary.sh     # build + Developer-ID-sign uhdrtool, stage into both bundles
    scripts/release.sh          # archive → DMG → notarize both artifacts
  dist/                         # distributable outputs
```

## Build / run / test the app

Open `Gainmap/Gainmap.xcodeproj` in Xcode and use **⌘R** (run) / **⌘U** (test).
The unit tests cover the engine logic (argv, file-role, output paths, stderr parsing).

From the terminal (equivalent):

```bash
xcodebuild -project Gainmap/Gainmap.xcodeproj -scheme Gainmap -destination 'platform=macOS' test
```

## Rebuild the native binary

```bash
brew install nasm        # one-time (libjpeg-turbo SIMD)
Gainmap/scripts/build-binary.sh
```

This builds `uhdrtool` (arm64, Release), Developer-ID-signs it, and copies it into
both the app's `Resources/Helpers/` and the plugin's `bin/mac/`.

## Release (notarized)

For the complete Mac + TestFlight + Firebase download-page workflow, release
gates, and permanent URL behavior, read
[`docs/gainmap-release-and-download.md`](docs/gainmap-release-and-download.md).

```bash
# One-time: install the portal-created "Gainmap Developer ID" provisioning
# profile, then store an app-specific password in the canonical Keychain profile.
xcrun notarytool store-credentials "legacylab-notary" \
    --apple-id "samhurd+apple2@gmail.com" --team-id S8HQ5TEYDE \
    --password <app-specific-pw>

# Read-only release preflight (identity/profile/notary/Sparkle/GitHub):
Gainmap/scripts/release.sh --preflight-only

# Archive, sign, notarize, generate an isolated Sparkle feed, and publish:
Gainmap/scripts/release.sh
```

Release artifacts are written to `dist/releases/v<marketing>-b<build>/`. The
script never feeds stale top-level `dist/` files to Sparkle and refuses to
overwrite an existing release directory or GitHub tag.

## CLI contract (`uhdrtool`)

```
uhdrtool --hdr <in.tif> --sdr <in.jpg> --out <out.jpg> [--cgamut 0|1|2] [--sgamut 0|1|2]
```

`--hdr` = 32-bit float HDR TIFF (Lightroom "Maximize Compatibility" OFF); `--sdr` =
a JPEG of the **same** pixel dimensions. Progress + the computed gain-map clamps
print to stderr; exit 0 on success.

## Licensing

`uhdrtool` statically links libultrahdr (Apache-2.0) and libjpeg-turbo (BSD/IJG/zlib);
see `upstream/licenses/NOTICE.md`. Both permit free redistribution.
