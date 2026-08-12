# Gainmap release and download runbook

Last verified: August 12, 2026, with Gainmap 1.6 build 12.

This is the authoritative handoff for Codex, Claude Code, and humans releasing Gainmap. It distinguishes committing code, publishing app binaries, distributing a TestFlight build, and updating the public download page. Those are separate operations.

## Distribution map

| Surface | Permanent public URL | What advances it |
| --- | --- | --- |
| Download page | `https://gainmap-production.web.app/download/` | A Firebase **Hosting-only** deployment |
| iPhone beta | `https://testflight.apple.com/join/NYqq11HH` | Making a processed build available to the external TestFlight group that owns this public link |
| Mac download | `https://github.com/hurd300403/Gainmap/releases/latest/download/Gainmap.dmg` | Publishing a newer normal GitHub Release with an asset named exactly `Gainmap.dmg` |
| Mac Sparkle feed | `https://github.com/hurd300403/Gainmap/releases/latest/download/appcast.xml` | The same normal GitHub Release, with the generated and signed `appcast.xml` |

The download page is **Firebase Hosting**, not Vercel (sometimes dictated as “Versal”). `.firebaserc` maps this repository to the dedicated `gainmap-production` project, and `firebase.json` serves the `hosting/` directory.

The two app buttons are already correctly wired in `hosting/download/index.html`:

- iPhone uses the permanent TestFlight public-group link.
- Mac uses GitHub's permanent `releases/latest/download/Gainmap.dmg` alias.

Routine build-number releases do not require changing or redeploying those URLs.

## What is and is not automatic

A commit, merge, or push to `main` does **not** publish Gainmap. This repository currently has no GitHub Actions release workflow.

- The Mac button advances only after `Gainmap/scripts/release.sh` successfully creates a normal, non-draft, non-prerelease GitHub Release containing `Gainmap.dmg`.
- The TestFlight URL stays constant, but an uploaded iOS build must finish processing, be associated with the public link's external testing group, pass TestFlight review when required, and enter `Testing` status.
- The visible version and OS requirement text on the page is static HTML. A build-only update such as 12 to 13 needs no page change. A marketing-version or requirements change such as 1.6 to 1.7 does.
- A GitHub draft or prerelease intentionally does not replace `releases/latest`. Do not expect a private Mac feature build to change the public Mac button.

## Release-wide preflight

Do this before either platform release:

1. Review the diff and tests appropriate to the change.
2. Set `MARKETING_VERSION` and a unique, strictly increasing numeric `CURRENT_PROJECT_VERSION` in `Gainmap/project.yml`, then regenerate the Xcode project when that specification changes.
3. Commit and push the intended release source.
4. Fetch `origin` and confirm all of the following:
   - the active branch is `main`;
   - the worktree is clean, excluding deliberately ignored release artifacts;
   - local `HEAD` exactly equals `origin/main`;
   - the version/build in the generated Xcode project matches `Gainmap/project.yml`.
5. If the app depends on new Firebase Functions, Firestore/Storage rules, indexes, or configuration, deploy and smoke-test those required backend changes **before** distributing the clients. Use narrowly scoped Firebase deploy targets; a hosting deployment does not deploy backend code.

The clean/synchronized-main check is mandatory. The Mac script builds the local checkout, while GitHub can create a missing release tag from remote `main`. Without this check, the downloadable binary and tagged source can silently disagree.

## Publish the Mac app

Prerequisites are enforced by `Gainmap/scripts/release.sh`: an unexpired `Developer ID Application: Sam Hurd (S8HQ5TEYDE)` identity and private key, the `Gainmap Developer ID` provisioning profile, the `legacylab-notary` Keychain profile for Team `S8HQ5TEYDE`, the Sparkle signing key, GitHub CLI authentication, and required build tools.

From the repository root:

```bash
Gainmap/scripts/release.sh --preflight-only
Gainmap/scripts/release.sh
```

The full script archives the Mac app, signs it, creates the DMG, notarizes and staples it, validates Gatekeeper/signing, generates the EdDSA-signed Sparkle feed and safe delta when possible, and publishes a GitHub Release named/tagged `v<marketing>-b<build>`.

It writes authoritative local artifacts beneath:

```text
dist/releases/v<marketing>-b<build>/
```

Do not publish the loose top-level `dist/Gainmap.app` or another stale artifact. For the 1.6 build 12 release, that loose app remained 1.5 build 7 while the correct release lived in `dist/releases/v1.6-b12/`.

After publishing, verify with remote evidence:

1. `gh release view v<marketing>-b<build> --repo hurd300403/Gainmap` reports a non-draft, non-prerelease release.
2. It contains exact-case `Gainmap.dmg` and `appcast.xml` assets (plus the delta when generated).
3. `https://github.com/hurd300403/Gainmap/releases/latest/download/Gainmap.dmg` resolves to the new tag and downloads successfully.
4. The downloaded DMG contains the expected marketing version/build, Team `S8HQ5TEYDE`, arm64 architecture, and macOS requirement; Gatekeeper accepts it and `xcrun stapler validate` succeeds.
5. The latest public `appcast.xml` top item names the same version/build and enclosure.
6. Treat a failed Sentry dSYM upload as a release follow-up even though the current script logs that failure and continues.

### Mac feature builds

The current script is a public stable-release script. Running it moves the public `latest` download and Sparkle feed. Do not use it for an experimental/private feature build unless that public rollout is intentional. A GitHub prerelease will not move the page's `latest` button; a separate feature channel would require an intentionally separate URL and update feed.

## Publish the iPhone TestFlight build

The currently proven path uses Xcode automatic App Store Connect signing under Apple account `samhurd+apple2@gmail.com`, Team `S8HQ5TEYDE`. `Gainmap/scripts/ExportOptions-TestFlight.plist` is configured for an App Store Connect upload and preserves the source-controlled build number, but upload is only the first half of external TestFlight distribution.

1. Archive the shared `GainmapIOS` scheme in Release configuration for a generic iOS device. Confirm the archive reports bundle `com.legacylab.gainmap.ios`, the intended marketing version/build, arm64, and Team `S8HQ5TEYDE`.
2. Upload through Xcode Organizer (or an equivalent authenticated `xcodebuild -exportArchive` flow using `Gainmap/scripts/ExportOptions-TestFlight.plist`). Do not call it released merely because the archive exists.
3. Confirm Xcode reports `Uploaded to Apple` with no errors.
4. Wait until App Store Connect finishes processing the exact build. Confirm the build/upload status is complete rather than relying on local logs alone.
5. In App Store Connect, locate the external testing group whose public link is `NYqq11HH` and add the exact processed build to that group.
6. Supply/update `What to Test` and required beta metadata. Choose automatic tester notification when appropriate.
7. Submit for TestFlight Beta App Review when required, or start testing when Apple permits it. Later builds of the same version may avoid a full review, but this is not guaranteed.
8. Confirm the group lists the exact build and its status is `Testing`. If automatic notification was not selected, explicitly notify testers after approval.
9. Verify using an external tester or public-link enrollment—not only Sam's internal App Store Connect tester account. The public TestFlight webpage identifies the app but does not reveal which build the group currently serves.

The public TestFlight URL should not be changed for routine updates. Once the new build is genuinely attached to that same group and testing, existing testers can see it through the stable link; installation may update automatically according to each tester's TestFlight settings.

## Update or deploy the download page

The page normally needs no deployment for a build-number-only app release because its button targets are permanent.

Edit `hosting/download/index.html` and deploy Hosting when any static presentation changes, including:

- marketing-version labels;
- minimum OS or hardware requirements;
- availability wording;
- platform icons or layout;
- the “Back to the Patreon post” destination.

Review every change under `hosting/`, because Hosting deploys that entire directory. Then deploy only Hosting from the repository root:

```bash
firebase deploy --only hosting --project gainmap-production
```

Never use bare `firebase deploy` for a page-only update: this repository also configures Functions, Firestore, indexes, and Storage rules. After deployment, verify the live page is HTTP 200, its HTML contains the intended permanent URLs, both buttons resolve, and the displayed version/requirements match the released apps. Firebase's cache can leave returning clients on the prior HTML for up to roughly one hour.

## End-to-end definition of “fully deployed”

Do not report a release complete until the applicable items are true:

- Intended source is committed and pushed on synchronized `main`.
- Required backend changes are already live and smoke-tested.
- Mac: signed/notarized stable GitHub release is public, the latest DMG and Sparkle feed resolve to it, and the artifact is verified.
- iOS: exact build is processed, attached to the public-link external group, approved when required, and in `Testing`; external availability is verified.
- Download page button URLs work. Static version/requirements copy is accurate, with a Hosting-only deploy completed if it changed.
- Release notes, Patreon copy, or support copy do not claim more availability than the remote evidence proves.

## Current verified baseline

As of August 12, 2026:

- Git `main`/`origin/main`: `8e2293c` (`Publish Gainmap 1.6 downloads`).
- Mac: Gainmap 1.6 build 12, GitHub release `v1.6-b12`, signed/notarized/stapled and public.
- iOS: Gainmap 1.6 build 12 was uploaded, processed, and internally installable. The public link is live; always verify external-group build assignment before naming build 12 as the public build.
- Download page: live on Firebase Hosting with both stable button URLs and static `Version 1.6` labels.

This baseline is historical evidence, not a substitute for checking the current remote state during the next release.
