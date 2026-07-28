# S3 auth + attestation spike — evidence record

Date: 2026-07-27 · Vehicle: `AuthSpike/` (Mac + iOS targets on the REAL App IDs)
Target project: **gainmap-production** (plan amendment from "throwaway project" —
Sam's call; providers were already configured there and spike users are deleted
afterward, signups closed throughout).

## Mac (notarized Developer ID build) — ALL PASS

| Test | Result |
|---|---|
| Notarized, stapled, hardened-runtime build launches clean (spctl: Notarized Developer ID) | **PASS** |
| Google Sign-In → Firebase uid | **PASS** (`xJYirhzjh…`, samhurd@gmail.com) |
| **Keychain persistence across relaunch — the -34018 risk, #1 Mac unknown** | **PASS** — second launch: `LAUNCH/persisted: uid xJYirhzjh… [google.com]` |
| Apple sign-in (web flow) → Firebase uid | **PASS** (`dYcD672…`) |
| Apple user carries verified email | **PASS** (`samhurd+apple2@gmail.com`, emailVerified) |
| App Check: `DCAppAttestService.isSupported` | **false** (recorded; enforcement decision awaits the iOS verdict) |
| Email-collision → recovery/link UI | **NOT live-fired** — both Apple attempts used the +apple2 Apple ID (no email collision with the Google account). Covered by client logic + P4 emulator link tests. |

## Platform findings (each one load-bearing)

1. **Sign in with Apple is NOT a supported capability for Developer ID
   distribution.** The portal deliberately omits `applesignin` from Developer ID
   provisioning profiles (dev profiles carry it; Developer ID never does, and
   `-exportArchive` cannot mint one). ⇒ the shipping Mac app uses a web-based
   Apple flow; native SIWA is iOS-only.
2. **FirebaseAuth's built-in provider web flow is `#if os(iOS)`-gated** —
   `OAuthProvider.getCredentialWith` does not exist on native macOS. The Mac
   flow is hand-rolled: ASWebAuthenticationSession → appleid.apple.com →
   `OAuthProvider.appleCredential(withIDToken:rawNonce:)` (cross-platform).
3. **ASWebAuthenticationSession's `.https` callback requires the Associated
   Domains entitlement** (`webcredentials` + AASA publication) — runtime error
   otherwise. Sidestepped with a custom-scheme callback (`gainmapauth://`),
   which needs no entitlement.
4. **A scope-less Apple authorize yields an id_token with NO email claim** →
   Firebase mints an email-less user, silently splitting identity against
   one-account-per-email. Requesting `scope=name email` forces
   `response_mode=form_post`, which a static page cannot receive ⇒ the
   `appleReturn` Cloud Function (behind the Hosting rewrite at
   `/auth/apple-return`) receives Apple's POST and bounces the fields to the
   custom scheme. Token size observed: 806 chars scope-less vs 882 with email.
5. **Apple remembers the per-app grant**: after the first authorization the
   sheet auto-signs with the remembered Apple ID and won't re-show the
   name/email consent. Reset via System Settings → Apple ID → Sign in with
   Apple → Stop Using (needed during testing; irrelevant for fresh users).
6. Developer ID **provisioning profiles are Account-Holder-only, portal-only**
   artifacts (`xcodebuild -allowProvisioningUpdates` cannot create them), and
   the export must pin the certificate by SHA-1 when two Developer ID certs
   exist (`Gainmap Developer ID` profile embeds cert `38FED0F2…`).

## Deployed alongside the spike (production)

- `appleReturn` CF (us-central1) + Hosting rewrite `/auth/apple-return` —
  part of the shipping auth design, not spike-only.
- Firebase apple.com provider: clientId = Services ID
  `com.legacylab.gainmap.auth`; code-flow config teamId `S8HQ5TEYDE`, key
  `NGYK4L9ML6` (.p8 held locally, never committed); bundleIds registered for
  the native iOS flow.
- Apple portal (Sam): Services ID `com.legacylab.gainmap.auth` (domain
  `gainmap-production.firebaseapp.com`, return URL
  `https://gainmap-production.firebaseapp.com/auth/apple-return/`), SIWA key
  `NGYK4L9ML6`, Developer ID provisioning profile `Gainmap Developer ID`.

## iOS (iPhone 15 Pro, Debug build via devicectl) — ALL PASS

| Test | Result |
|---|---|
| Native Sign in with Apple sheet → Firebase | **PASS** — sub `001902.60a17…`, email delivered natively |
| **Cross-platform identity: native iOS flow and Mac web flow → SAME uid** (`dYcD672…`) | **PASS** — App ID grouping + provider config verified end-to-end |
| Google Sign-In → Firebase | **PASS** (same uid as Mac, `xJYirhzjh…`) |
| Persistence across swipe-quit + relaunch | **PASS** (Sam confirmed) |
| App Check: `DCAppAttestService.isSupported` | **true** |

## App Check decision (per the plan's rule)

Mac notarized = `false`, iOS = `true` ⇒ enforcement is OFF the table (a
notarized Mac cannot attest). **App Check = monitor-only / deferred.** Cost
protection remains the reservation quota + admission cap + kill switch.

## Cleanup ledger

Email-less strays `B2FjCnvgkm…`, `NBzOpSsro…` deleted 2026-07-27. Spike users
`xJYirhzjh…` (google) and `dYcD672…` (apple) deleted at close — production
Auth is empty again.

**S3 CLOSED 2026-07-27.** Plan risk #4 (macOS keychain/-34018 on notarized
builds) retired; auth architecture settled: native SIWA on iOS, hand-rolled
web flow + appleReturn CF on Mac, Google native SDK both platforms.
