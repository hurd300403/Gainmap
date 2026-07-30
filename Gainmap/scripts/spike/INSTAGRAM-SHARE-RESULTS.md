# Instagram Carousel Share Spike Results

Date: 2026-07-29

Status: **INCOMPLETE — ORDERED INSTAGRAM COMPOSER PASSED · LIVE HDR TEST PENDING**

This document intentionally excludes account identifiers. The Debug probe uses
only the public iOS activity sheet and ordered file URLs; it does not select
Instagram automatically, authenticate with Instagram, or delete posts.

## Environment

| Component | Version |
| --- | --- |
| Device | iPhone 15 Pro (iPhone16,1) |
| iOS | 27.0 (24A5390f) |
| Instagram | 438.0.0 (1015949731) |
| Gainmap | 1.6 (8), Debug build under test |
| Xcode | 26.5 (17F42) |
| Build SDK | iPhoneOS 26.5 |

Instagram login and private-test-account state: confirmed manually; no account
identifier is recorded here.

## Attempt 0 — Invalid Single-Photo Path

Result: **NOT PART OF THE DECISION GATE**

- The session contained four photos, outside the Debug probe's required
  two-or-three-photo range.
- The existing top-right selected-photo share button was used. That production
  control is intentionally unchanged and exports only the selected photo.
- Before Instagram was selected, the iOS share sheet displayed one JPEG
  filename and one thumbnail.
- Instagram's destination chooser and composer then displayed that same single
  photo.
- No `[InstagramCarouselProbe]` presentation or completion entry was emitted.

Conclusion: this attempt confirms the existing single-photo route, but does not
test whether Instagram accepts or rejects an ordered multi-file payload.

## Automated Validation

| Check | Result | Evidence |
| --- | --- | --- |
| GainmapCoreTests — macOS | Pass — 187 tests, 0 failures | `/tmp/gainmap-instagram-spike-mac-tests/Logs/Test/Test-GainmapCore-2026.07.29_19-10-47--0400.xcresult` |
| GainmapCoreTests — iOS Simulator | Pass — 187 tests, 0 failures | `/tmp/gainmap-instagram-spike-ios-tests/Logs/Test/Test-GainmapCore-2026.07.29_19-11-16--0400.xcresult` |
| GainmapIOS Debug build | Pass — signed for Team `S8HQ5TEYDE` | `/tmp/gainmap-instagram-spike-ios-debug/Build/Products/Debug-iphoneos/Gainmap.app` |
| Debug contains probe control | Pass | Exact control copy and `[InstagramCarouselProbe]` marker found in `Gainmap.debug.dylib` |
| GainmapIOS Release build | Pass | `/tmp/gainmap-instagram-spike-ios-release/Build/Products/Release-iphoneos/Gainmap.app` |
| Release excludes probe control/copy | Pass | Exact control copy and `[InstagramCarouselProbe]` marker absent from the Release app bundle |
| Existing selected-photo export | Pending manual check | |

## Test Session

Filmstrip screenshot: **pending**

Use one freshly created A → B → C session with unique source filenames. Do not
change any look controls between the Files/AirDrop preflight and the Instagram
handoff; the second run intentionally reuses successful ordered exports under
the existing batch-export semantics.

| Position | Visual marker | Ordered export filename |
| --- | --- | --- |
| A — 1 | Pending | Pending |
| B — 2 | Pending | Pending |
| C — 3 | Pending | Pending |

## Files or AirDrop Metadata Preflight

Inspect each exact exported JPEG before selecting Instagram.

| Position | JPEG opens | MPF | `hdrgm:Version` | ISO 21496-1 | Notes |
| --- | --- | --- | --- | --- | --- |
| A — 1 | Pending | Pending | Pending | Pending | |
| B — 2 | Pending | Pending | Pending | Pending | |
| C — 3 | Pending | Pending | Pending | Pending | |

Metadata command/output summary: **pending**

## Activity Sheet Result

Ordered filenames logged by Gainmap: the retained console log was unavailable
after Instagram took focus. The tester visually confirmed that the three
photos arrived in the same A → B → C order shown in Gainmap.

| Field | Value |
| --- | --- |
| Activity type | Instagram selected manually from the public iOS activity sheet |
| Completed | Composer opened successfully |
| Error | None observed |

## Instagram Composer

| Criterion | Result |
| --- | --- |
| Opens a feed composer | Pass |
| Carousel mode active | Pass |
| All three images preselected | Pass |
| A → B → C order preserved without reselection | Pass — tester confirmed |

Composer screenshots: observed on the physical test device. Captures are kept
outside this repository because the Instagram destination UI contains account
information.

If any criterion fails, do not publish. Record the exact behavior here:
not applicable to the ordered-composer gate.

Aspect-ratio observation: Instagram used the first slide's 3:4 presentation
for the mixed-ratio carousel. A device-container audit confirmed Gainmap's
corresponding UltraHDR export retained its source dimensions (4032 × 3024 with
a 90-degree orientation tag); Gainmap did not pre-crop that file. The remaining
crop behavior is therefore attributed to Instagram's carousel composer unless
a later controlled test disproves it.

## Published Private Test

Temporary post published: **pending**

Live carousel order A → B → C: **pending**

Visible HDR bloom on at least one slide, at moderate display brightness with
Low Power Mode and Reduce White Point disabled: **pending**

Source-versus-live comparison notes/screenshots: **pending**

Temporary post manually deleted after evidence capture: **pending**

## Instagram Web Rendition

Largest authenticated rendition captured: **pending**

| Metadata signal | Result |
| --- | --- |
| MPF | Pending |
| Google/Adobe gain-map metadata | Pending |
| ISO 21496-1 gain-map metadata | Pending |

Inspection command/output summary: **pending**

Absence from the web rendition is inconclusive when the iOS post visibly
renders HDR because Instagram's web CDN may serve an SDR derivative.

## Decision

Conclusion: **INCOMPLETE — ORDERED CAROUSEL PASSED; LIVE HDR PENDING**

- Pass requires both a preselected ordered carousel and live HDR.
- Incomplete means the ordered-composer gate passed, but the live HDR gate has
  not yet been tested.
- Partial means carousel succeeds but live HDR does not.
- Fail means Instagram drops items, changes order, or does not open a feed
  carousel. Do not use undocumented URL schemes as a workaround.

The native ordered file-URL handoff has cleared its composer gate and is
suitable for a generic production “Share Session” UX. This is not yet a full
spike Pass because a published private carousel still needs visual HDR and
metadata validation.

## Implementation Disposition

The tester reviewed and accepted the ordered-composer result. The Debug-only
probe was subsequently promoted to a target-agnostic production **Share
Session** control that sends separate UltraHDR file URLs in filmstrip order.
The existing selected-photo share remains unchanged. Instagram is still chosen
manually from the public iOS activity sheet.
