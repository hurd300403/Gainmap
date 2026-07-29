# Gainmap iOS + Firebase Session Sync — Implementation Plan (r7)

> **r7 (2026-07-27, post-probe; IAM correction 2026-07-29):** the real-project probe FALSIFIED the two-deadline reservation design — Cloud Storage evaluates rules at **finalize**, not at resumable-session start, so `startBefore` was a completion deadline in disguise (any upload slower than 30 min would 403 after its bytes were spent). Replaced by **single-deadline semantics**: reservation carries only `expiresAt = now + 8 days`; Storage rules check reservation match + `request.time < expiresAt` (still 2 gets); maintenance releases capacity after `expiresAt + 1h`. A finalize-time 403 = lease expired mid-upload → client re-reserves (idempotent refresh) and starts a NEW upload session — a denied finalize terminates the old resumable session (re-probe R2b: reusing it returns 400); a refresh landing BEFORE any denied finalize keeps a still-open session usable (probe E2). Verified end-to-end on the probe project 2026-07-27 21:40Z (re-probe R1–R4 all PASS; commit `cdfcc8e`). Production-critical IAM guidance was corrected after a live failure on 2026-07-29: **`roles/firebaserules.firestoreServiceAgent` must be granted to the Firebase Storage service agent, `service-<projectNumber>@gcp-sa-firebasestorage.iam.gserviceaccount.com`,** for cross-service `firestore.get()` calls in Storage rules. The earlier grant to the `firebase-rules` service agent alone left every upload denied; granting the role to the Storage service agent restored all six queued production uploads. Evidence and the superseded probe interpretation are recorded in `Gainmap/scripts/spike/P0-PROBE-RESULTS.md`. Sections below referring to `startBefore`/`releaseAfter` are superseded by this note.

## Context

Gainmap today is a macOS-only SwiftUI UltraHDR editor (`/Users/iamthesam/sdrhdr/Gainmap`, ~3.2k LOC + 62 XCTests): import JPEGs, dial an HDR "look" (`AutoHDR.BloomParams`), export UltraHDR JPEGs by spawning a bundled `uhdrtool` CLI (libultrahdr). Nothing persists — the queue dies on quit. Sam wants an iOS peer app where a session started on the Mac is "just already there" on the phone: browse sessions as thumbnail grids, tweak with the full editor, export to Photos — synced per-user through a new Firebase backend. Review history: r2 = lifecycle/cost/conflicts/rules; r3 = Apple grouping + quota/cap; r4 = admission, reservations, revisions, ack-aware reconcile, blob GC. r5 = reservation state machine, server-owned completion ledger, no client hard-deletes, preserve-the-loser conflicts, rules-enforced revisions. **r6 = review round 4: two-deadline reservations (start window vs capacity lease), post-deletion upload cleanup, three-state blob GC, delete-wins exceptions to revision mismatch.**

## Locked decisions

| Decision | Choice |
|---|---|
| Distribution | **Public TestFlight link**, announced to patrons first — never payment-gated or called a patron perk (2.2). Mac stays Sparkle. |
| Auth | **Apple (primary) + Google — BOTH platforms**, one-account-per-email + catch-and-link. **Apple App IDs grouped (Mac primary, iOS grouped) before any Sign-in-with-Apple-enabled build ships** (the Mac app already ships today without it). Sync admission separate from Auth (no blocking functions/Identity Platform needed). |
| Payload | Full-res original JPEGs + client-generated 1024px thumbs, content-addressed + immutable in Storage. Never Gainmap exports. |
| Sync | Bidirectional, auto-sync everything. |
| iOS downloads | Auto-download all originals: thumbs first, Wi-Fi default, cache budget 25 GB default (Settings) + 2 GB floor + LRU + "Remove downloads". |
| Quota | **5 GiB/user default, hard-enforced via upload reservations** (state machine below). `quotaBytes` server-owned, per-user raises. **Signup cap** via `admitSyncUser` (maxUsers ≈ 200, authoritative counter, waitlist state; app fully usable offline — including photos too large to sync). |
| Deletion model | **Clients never hard-delete anything** — they only set `deletedAt` tombstones (allowed even under the kill switch). Physical deletion is exclusively server-side (`maintenance`, `deleteAccount` via Admin SDK). |
| Scope | iOS full parity + session grid; Mac keeps editor, gains parity session grid. |
| Firebase | NEW project `gainmap-production`, Blaze (acct `0178A5-AD0977-C4588E`), **us-central1** (irreversible — final confirm at P0), uid-keyed. |
| App Check | Empirical S3 test; enforce only if notarized-Mac + iOS both pass; else monitor/deferred. |
| Patron gating | Dormant hook; likely future shape = larger quota; activation = separate StoreKit/App-Review decision. Task #316. |
| Targets | macOS 14, iOS 17, arm64. `com.legacylab.gainmap` / `.ios`, team S8HQ5TEYDE. |

## Architecture

- **`GainmapCore`** — one XcodeGen multiplatform framework target (`supportedDestinations: [macOS, iOS]`; fallback `platform:` expansion + pinned `PRODUCT_MODULE_NAME`). Look engine (AutoHDR untouched), MergeModel state machine, session model, sync engine, shared UI, Obj-C++ encoder bridge. Framework, not SPM (no mixed Swift/`.mm` targets in SPM).
- **`GainmapUHDR.xcframework`** — libuhdr + libjpeg-turbo static slices (ios-arm64, ios-arm64-simulator, macos-arm64), pinned `13a058f`; `encoder.cpp` compiles in GainmapCore. Committed artifact + rebuild script.
- **In-process encoding BOTH platforms** via DI seams (`MergeModel.swift:505-509`); Process machinery deleted (CLI kept for Lightroom plugin + parity oracle).
- **Firestore** metadata/looks; **Storage** immutable bytes; **local stores** uid-namespaced JSON + blob cache; **SyncEngine + ChangeJournal + TransferQueue** mediate.
- **Server surface = 5 Cloud Functions** (+1 dormant): `admitSyncUser`, `reserveUpload`, `usageReconciler` (finalize/delete → generation-ledgered accounting; sole writer of rendition completion state), `maintenance` (scheduled: tombstone purge, capacity-lease release, **three-state two-pass blob GC**), `deleteAccount`. Dormant: patron claim setter.

## Identity & account lifecycle

- **Apple App ID grouping (P0, before any Sign-in-with-Apple-enabled build ships):** `com.legacylab.gainmap` primary, `.ios` grouped; one Sign in with Apple key. Same `sub` + relay email both platforms → one uid.
- **Admission:** first sign-in calls `admitSyncUser` (transaction): checks `config/flags.{signupsOpen,maxUsers}` + `config/counters.admittedUsers` → creates `users/{uid}` (`quotaBytes`, `syncAdmitted`) + zeroed `usage/storage` → increments counter → or returns waitlist state. All user-tree writes require `syncAdmitted`.
- **Happy path** one-account-per-email + catch-and-link; **cross-provider split** → first-run copy, link nudge, Settings linking; **two-existing-uids** → explicit choose-library UI + documented support-driven merge (not automated v1).
- **Account deletion (5.1.1(v)):** uid exclusively from the verified token; recent-auth enforced server-side (`auth_time` ≤ ~5 min); Apple token revocation; recursive purge of Firestore tree + Storage prefix + Auth user; **decrements `admittedUsers` exactly once**; **deletion marker lives OUTSIDE the user tree** (`deletedAccounts/{uid}`, **TTL ~30 days — longer than the max upload-session lifetime + event-delivery margin**) so recursive deletion can't remove its own guard; **the reconciler doesn't merely no-op on the marker — it deletes any object a late-completing resumable session finalizes into the purged prefix** (acceptance test: start resumable upload → delete account → complete upload → prefix stays empty, no Firestore subtree reappears). Local uid-namespaced wipe; Mac originals untouched.
- **Local stores uid-namespaced** (`users/{uid}/{sessions,blobs,journal,queue}`, `users/local` pre-sign-in with one-time adoption). Sign-out: tear down, drain, clear iOS blob cache, keep Mac files.
- **Privacy:** hosted policy + App Store answers declare full-res upload **incl. EXIF/GPS**; rewrite the in-app "no photos are ever sent" claim with the first syncing build (P4), re-verified P8.

## Quota — reservation state machine (r6)

The reservation must outlive the upload it authorizes (Cloud Storage resumable sessions stay valid up to a week; rules are checked at upload start, not finalize):

1. **`reserveUpload(contentHash, tier, byteSize)`** — callable transaction; **idempotent**: re-reserving the same `(contentHash, tier, size)` **atomically refreshes BOTH deadlines** — `startBefore = now + 30 min` AND `releaseAfter = startBefore + 8 days` — and never double-counts `reservedBytes` (dedicated test: a refreshed authorization window also extends its capacity lease). Verifies `syncAdmitted`, **rejects while sync is disabled (`syncEnabled == false`)** — a killed switch must not accumulate week-long capacity leases — and checks `bytesUsed + reservedBytes + byteSize ≤ quotaBytes`. **Two deadlines (r6)** — expiry is measured from the right events: `startBefore = now + 30 min` (the authorization window to *begin* an upload; identical for fresh reserves and refreshes) and `releaseAfter = startBefore + 7 days + 1 day margin` (the capacity lease — an upload started at the last minute can still take the full resumable-session lifetime to complete). Typed quota-exceeded error otherwise.
2. **Storage rules (exactly 2 `get()`s):** create allowed iff matching reservation (path + size) with **`request.time < startBefore`** AND `config/flags.syncEnabled`. Quota math lives in the callable only.
3. **`usageReconciler` on finalize:** **the sole writer of completion state.** Writes server-owned `renditions.<tier> = {generation, byteSize, counted: true, uploadedAt}` on the blob doc — a **persisted generation ledger**, so duplicate finalize (same generation) is a no-op, duplicate delete is a no-op, and delete-before-finalize resolves by generation comparison (Eventarc is at-least-once and unordered). Converts reserved → used (`bytesUsed += size`, `reservedBytes -= size`, reservation doc deleted). Finalize after `releaseAfter` (pathological) → count-and-heal remains as defense-in-depth, but the lease design makes it practically unreachable. **Post-deletion uploads (r6): if `deletedAccounts/{uid}` exists or the user doc is absent, the reconciler immediately DELETES the newly finalized object and writes no blob or usage state** — an already-authorized resumable session completing after account deletion cannot leave an orphan.
4. **`maintenance`:** releases reservations only after `releaseAfter` (`reservedBytes -=`); nightly recompute from bucket listing heals all drift.
5. **Blob GC — three-state (r6):** server-owned `state: active → gcCandidate → deleting`. Pass 1 marks `gcCandidate` when no live photo doc, no retained tombstone, **and no active reservation/upload** references the hash; pass 2 (≥24h later) re-checks references, then **atomically marks `deleting` before physical deletion — and Firestore rules reject new photo docs referencing a blob in `deleting`**, closing the recheck-then-reference race completely. A client that loses that race re-reserves and re-uploads. Session/photo deletes therefore DO reclaim quota after the tombstone window.
- **64 MB per-object limit enforced at sync-scheduling, not import**: oversized photos import and edit normally but are **entirely local (r6)** — no bytes uploaded, no remote photo document journaled or created, excluded from remote `photoCount` and `covers`; the visible badge explains why the session will differ on other devices. Offline functionality stays complete for everyone including waitlisted users. (Thumbnail-only remote placeholders considered and rejected for v1 — a permanently-broken-looking photo on peers is worse than an explained local-only one.)
- Quota-exceeded is a first-class terminal state in the TransferQueue; usage shown in Settings. **Kill switch** (`syncEnabled=false`) blocks creates and updates (including `reserveUpload`) **except tombstone-only updates** (affectedKeys ⊆ {deletedAt, rev metadata}) — users can always delete and always leave. Budget alerts $25/$50/$100 monitoring-only. **The real-project reservation-lifecycle test (start upload → pass `startBefore` → complete; finalize path verified) runs in P0, not P4 — its result shapes the backend design.**

## Phases

`[C]`=critical path. 62 existing tests green at the end of every phase.

### S1 [C] — Encoder spike (timebox 2 days)
`scripts/build-uhdr-xcframework.sh`: per-slice CMake (separate device/sim builds → `-create-xcframework`); likeliest snag = libjpeg-turbo sub-build not inheriting the iOS sysroot → CMake toolchain file (forwarded via `UHDR_CMAKE_ARGS`), fallback `leetal/ios-cmake`, pre-seed `TRY_RUN` vars; no NASM (arm64/NEON). In-process Mac encode byte-compare vs CLI; `bloomCIImage` Mac-vs-iOS f16 diff (parity tolerance); confirm no tiled-encode API.
**Exit:** 3-slice xcframework reproducible; Mac in-process bytes == CLI bytes; **AND a scratch iOS app links the xcframework + Obj-C++ bridge and completes one encode on simulator and one on a physical device** — producing slices alone doesn't prove the combined static archive links. **Kill:** no working iOS link-and-encode in 2 days → iOS viewer/tuner, re-plan.

### S2 [C for iOS export] — Photos round-trip spike (half day)
AirDrop fixture → `PHAssetCreationRequest` → re-fetch → byte-compare + ISO gain map survives → eyeball HDR on XDR. **Exit:** yes/no + fixture archived. **Kill:** Photos re-encodes → share-sheet/Files export.

### S3 — Auth + attestation spike
Throwaway project. Apple + Google, macOS + iOS. **macOS keychain = #1 risk:** `keychain-access-groups` + `applesignin` entitlements, Keychain Sharing capability, embedded provisioning profile, persistence across relaunch **on a signed NOTARIZED build** (`-34018` = silent sign-out). Firebase Apple-provider console needs. App Check empirical test. Catch-and-link + recovery skeleton.
**Exit:** notarized Mac + iOS; happy path one uid; split path reaches recovery UI; App Check verdict recorded.

### P0 — Firebase provisioning + rules + functions (parallel with spikes)
Runbook: `projects:create` → billing link → enable APIs → Firestore `us-central1` (**irreversible — final confirm**) → default bucket → `apps:create IOS` ×2 + sdkconfig (plists public config; commit) → Google provider via CLI. **Console/portal:** Apple provider, **App ID grouping**, capabilities, OAuth consent, Blaze verify. Budget alerts. Deploy the 5 CFs. Rules + emulator + Node rules tests **before client code**; cross-service `get()` emulator gaps → verify reservation rule against the real project once. **The real-project reservation-lifecycle probe runs HERE: start upload → pass `startBefore` → complete; confirm the finalize/reconciler path — the result shapes the backend before anything is built on it. Deadlines are config-overridable so the probe (and CI) use shortened test-only values rather than literally waiting 30 minutes / 8 days.**
**Exit:** emulators run; rules tests green — owner/stranger/unauth; blob no-update; server-owned-field protection; unreserved/expired-reservation upload rejected; **client Storage delete DENIED; client Firestore hard-delete DENIED; maintenance (Admin SDK) deletion succeeds**; `rev == old.rev + 1` enforced; killswitch blocks creates/updates but allows tombstone-setting; waitlist; schemaVersion 2 rejected. `admitSyncUser` provisions + caps; `deleteAccount` purges a seeded user, decrements the counter once, and delayed events don't resurrect; budget alert fires synthetically; **and the real-project reservation-lifecycle probe has a recorded PASS — a contradictory platform result forces replanning before anything builds on P0.**

### P1 [C] — Core extraction (macOS-only release)
`Sources/` → `Core/` + `Mac/`; GainmapCore target; `UHDRRunner.swift` split; `LookControls` extraction (parity mechanism); `ImageInfo.thumbnail` → `CGImage`; Theme runtime fonts + `UIFont` branch; CrashReporting iOS redaction; VersionGate per-platform key. Tests → `GainmapCoreTests`. **`RawBuffer` URL-backed through P1**; Data-backed in P2 with temp-file adapter for the CLI oracle. `build-binary.sh` dynamic identity resolution.
**Exit:** 62/62; app identical; ship as a Mac release.

### P2 [C] — In-process encoder (macOS release behind a flag)
`encodeUltraHdrToMemory` + **histogram `computeClamps`** (bit-exact, 585 MB → 256 KB — iPhone viability). `GMUltraHDR` bridge, verbatim errors. `InProcessEncoder` at the `runTool` seam; `HDRPreview.renderExport` to the seam. Zero-copy f16. `Task.isCancelled` pre-encode. Mac behind a flag one release (CLI = rollback), deletions next.
**Exit:** 62/62 + golden parity tests (bytes + clamps incl. negatives/NaN/subnormals).

### P3 — Session model + local persistence (parallel with P2; Mac release)
`Session` (+ session-scoped `sameLookForAll` seeded from UserDefaults, `runningLook`) + `PhotoRecord` (UUID at import, SHA-256 `contentHash`, `Origin.linked/.managed`, `look: BloomParams?` nil = inherit, Codable `ClampReadout`, pixelSize, **`tooLargeToSync` flag for > 64 MB files** — imported and editable, entirely local per the r6 rule: never journaled to the cloud, excluded from remote photoCount/covers, visible badge). Atomic JSON per session, uid-namespaced; `FileSessionStore` actor; `OutputPolicy`. MergeModel `init(session:store:output:)`; `BatchItem` view-facing; debounced `syncToSession()`; **live-look flush** on background/quit + before drains. contentHash dedup. `SessionNaming.suggest`. Signature → `signature.json` (fallback one release, bake normalization preserved).
**Exit:** 62/62; sessions survive relaunch; round-trip/crash-safety/naming/dedup/live-flush/too-large-badge tests green.

### P4 — Sync engine (needs P0+P3; schema freeze here)
**Schema** (uid-keyed, `schemaVersion 1`, tolerant decoders; `BloomParams` IS the look payload):
- `users/{uid}`: signatureLook (normalized) + hasCustomDefault — **synced as one whole-map group under explicit commit-order LWW (no rev group; user-scoped, rarely contended)**; profile fields; `quotaBytes`/`syncAdmitted`/`entitlement` (server-owned).
- `users/{uid}/usage/storage` (+ `reservations/{id}`): CF-owned.
- `users/{uid}/blobs/{contentHash}`: client-created shell (byteSize); **`renditions.*` entirely server-owned** — `{generation, byteSize, counted, uploadedAt}` written only by `usageReconciler` (the generation ledger); `gcCandidateAt` by `maintenance`. Client treats `renditions.<tier>.uploadedAt` as the completion signal it can trust but never write.
- `users/{uid}/sessions/{sessionId}`: title, `sameLookForAll`, `runningLook` (invariant `runningLook == bloom` in same-look mode), **`covers: [{photoId, contentHash}]` (≤4)** — mosaic renders straight from thumb paths, no extra queries; photoCount (UI-only), createdAt/updatedAt, `deletedAt`, per-group `rev` metadata.
- `…/photos/{photoId}`: **`deletedAt` tombstone (r5 — photos are individually removable and need it)**; `contentHash` **immutable** (replaced source file = new photo record); `look` map or literal null = inherit (decoder maps missing AND null → nil); `orderKey` (tiebreak `(orderKey, createdAt, photoId)`); gamut; pixel dims; looksMerged; `lastExport` informational; per-group `rev` metadata.
- **Conflict protocol — revisions as a rules-enforced invariant:** mutable groups (`look`, `{runningLook,sameLookForAll}`, `orderKey`, `title`, `deletedAt`) carry `rev: Int` + deviceID + mutationID; **rules enforce `new.rev == old.rev + 1` and protect mutation metadata**; deletion/undo have their own rev semantics (tombstone set/clear each bump the group rev). Journal stores field group + baseRev + mutationID + **the coalesced local VALUE** (not names-only — needed for the overlay and conflict preservation). Drain = online transaction (Firestore transactions fail offline — stated): remote `rev == baseRev` → write, rev+1. **On mismatch (r5 — the chosen outcome): adopt the committed remote value AND preserve the losing local value in a recoverable conflict record** — surfaced as "Your edit was superseded by your other device — Restore?" (restore re-applies it as a NEW mutation on the current rev). **Inbound snapshots never overwrite dirty field groups**: the UI reads a dirty-field overlay from the journal until the group's transaction resolves. Non-look scalars: commit-order LWW, deliberate. **Delete-wins with explicit exceptions to ordinary mismatch handling (r6):** a *pending tombstone* hitting a rev mismatch (an edit committed first) does NOT lose — it reloads and retries against the current rev, so the delete still wins; a *pending edit* hitting a remote tombstone loses — the tombstone wins and the edit is preserved only as a recoverable conflict record; *undo* clears only the tombstone revision it observed and surfaces a conflict if deletion state changed again. **Ack-aware full reconcile** (per-record `everAcked`; >30-days-offline: acked-but-absent → purged locally; never-acked pending create → preserved and uploaded; dedicated offline-created-session test).
- NOT synced: intensity/anchorLook (concrete looks only; adopt via `loadAsAnchor`), selectedID, clipboard, local status/error/outputURL.
**Engine:** `SyncEngine` actor — listeners: user, usage, sessions, blobs; photos listeners = open session + 5 most recent, rest on open; tombstones filtered client-side. `ChangeJournal` atomic with the local edit. `TransferQueue`: reserve → upload (thumb-first) → server finalize; skip-if-exists via ledger + `getMetadata`; backoff → park visible; quota-exceeded terminal; Wi-Fi gate; restart incomplete uploads on relaunch (#147). Mac rehydration via path↔hash index. Storage paths + `cacheControl: immutable` + `gm-sha256`; thumbs client-side 1024px q0.72 sRGB.
**Exit:** two peers converge (metadata/order/looks/nil-inheritance); rev-guard verified incl. **conflict-record preservation + restore**; delete-wins + ack-aware reconcile verified; kill-mid-upload recovers; reservation-expiry-mid-upload verified against the real project; session delete → GC reclaims quota (two-pass) in emulator; suite green in CI; **privacy copy rewrite ships with this build**.

### P5 [C] — iOS shell + editor MVP (needs P1, P2, P4)
`GainmapIOS` target; NavigationStack/SplitView; shared `SessionGridView` (mosaics via `covers`, sync badges); editor regular = Mac layout, compact = persistent bottom sheet (150pt/50%/large) with **tabbed advanced groups (concept D — decided)**; `GMSlider`, EDR UIView twin + "SDR SCREEN" badge, haptics shim, press-and-hold compare verbatim. Auth UI (both providers, linking, nudge, recovery, waitlist). Share-sheet export proves on-device encode.
**Exit:** internal TestFlight; Mac session tuned on iPhone → lands on Mac; 62/62 on iOS sim; EDR correct/graceful.

### P6 [C] — iOS import/export parity (needs P5, S2)
`PHPhotoLibrary.requestAuthorization`; granted → `PHImageManager.requestImageDataAndOrientation` (`isNetworkAccessAllowed`, progress, cancel; evicted-iCloud tested); denied/limited → `loadTransferable(Data.self)` fallback. **Import contract (pure, tested):** tone-mapped SDR JPEG q0.95 in source gamut, metadata via `carriedProperties`, source gain map discarded, `looksLikeMergedOutput` suppressed for Photos imports, iOS 18 availability on ISO probe, >64 MB → `tooLargeToSync` (not rejected). Memory: increased-memory-limit + soft dynamic cap (keep halving below 4032; graceful failure, never crash). Export: `PHAssetCreationRequest` (per S2), auto-save toggle, `ShareLink` + AirDrop hint.
**Exit:** acceptance script passes on device matrix incl. SE + evicted-iCloud + denied-permission.

### P7 — Mac session grid (parallel after P3)
`Mac/RootView.swift`: NavigationStack in existing window; shared grid → editor push. Drop on grid = auto-named session into editor; drop in editor = adds. `sizeWindowToAspect` → `.onAppear`. Sync badges + footer status.
**Exit:** 3 batches → 3 sessions; relaunch intact; 500-session grid no hitch; tombstone delete/undo round-trips.

### P8 — Hardening + beta
Sentry iOS privacy options off **with asserting test**. `gate.json` per-platform, fail-open both shapes. Account deletion end-to-end. Privacy policy + App Store answers (photos + GPS). `PrivacyInfo.xcprivacy`, usage strings, `ITSAppUsesNonExemptEncryption = false`. **Pre-public checklist: reservation quota verified (concurrent-upload attack test), admission cap live, kill switch verified (blocks creates/updates, allows tombstones + account deletion), budget alerts armed.** **Provisioning-profile ops:** the archive-time validity check lands in `release.sh` **with the first profile-bearing Mac release (the P4-era sync build), not here** — P8 only verifies the 90/60/30-day expiry alerts and the planned Sparkle replacement release (an expired Developer-ID profile can stop an installed app launching). Patron scaffold dormant. Zero Patreon mentions. 90-day TestFlight expiry → quarterly cadence.
**Exit:** Beta App Review passed; ~10 testers a week; Sentry clean.

## Security rules (deploy in P0)

**Firestore:** owner-only + `syncAdmitted` on writes; dormant `entitled()`; `versionOK()`; server-owned fields client-unwritable (`quotaBytes`, `syncAdmitted`, `entitlement`, `usage/**`, `reservations/**`, **`blobs.renditions.*` + `blobs.state`**) with split create/update branches; **photo creates referencing a blob whose `state == 'deleting'` are rejected** (closes the GC race); `createdAt`/`contentHash` immutable; `look` map-or-null; **`new.rev == old.rev + 1` enforced per mutable group; mutation metadata protected**; **`allow delete: if false` on every client-facing doc** — clients only set `deletedAt` (tombstone-only updates allowed even under the kill switch); killswitch gates other creates/updates.
**Storage:** owner-only read; **create only — update AND delete denied for clients** (immutability + no client GC; physical deletion via Admin SDK bypasses rules); `contentType == 'image/jpeg'`; size < 64 MB; tier allowlist; **create requires a matching reservation within its authorization window (`request.time < startBefore`, path + size match) + `config/flags.syncEnabled`** — exactly 2 `get()`s.

## Verification

- **Regression net:** 62 tests on macOS + iOS simulator from P1; no phase merges red. CLI argv/stderr tests → bridge tests when the CLI leaves the app.
- **Parity ladder:** encoder bit-exact; clamps bit-exact; CI synthesis tolerance (S1 threshold, PSNR > 60 dB); end-to-end perceptual. Fixtures: `mockups/hdr-samples/` + Display P3 + 48 MP.
- **New pure tests:** ConflictPolicy table (rev match/mismatch, **conflict-record preservation + restore-as-new-mutation**, dirty-overlay reads, stale-drain, tombstone×edit both ways, both-tombstoned, self-ack via mutationID, ack-aware reconcile incl. offline-created-session), tolerant decode unknown keys, `look` nil/null round-trip, orderKey, journal value-coalescing + atomicity, memory-cap boundaries, HEIC transcode contract, too-large-to-sync flagging, SessionNaming, redaction, Sentry assertions, gate.json both shapes, OutputPolicy, uid-namespacing.
- **Emulator suite:** Node rules tests (P0 exit list incl. client-delete denial + rev-increment enforcement) + Swift integration (lifecycle, offline conflicts, two-peer convergence, delete-wins, reconcile modes, dedup no-op, reservation flow incl. **concurrent-upload attack, idempotent re-reserve, start-window expiry vs capacity lease, finalize-without-reservation**, lease release only after `releaseAfter`, three-state GC incl. the deleting-blob reference rejection + losing-client re-upload, **post-deletion late-finalize cleanup (start upload → delete account → complete → prefix empty)**, delete-wins exception cases (pending-tombstone retry, pending-edit-vs-tombstone, undo-vs-changed-deletion), `deleteAccount` purge + counter decrement + no-resurrection). `scripts/test-sync.sh`; CI on macOS runner.
- **Device matrix:** 15/16 Pro · 13/14 non-Pro · SE 3 · M-series Mac; + evicted-iCloud; + limited/denied permission.
- **Acceptance script (every beta):** Mac drop 24 MP → grid ≤1 s → edit → synced ≤30 s → iPhone cold-launch shows thumbnail → matching look, real EDR → iPhone edit lands on Mac ≤30 s **with any superseded local edit preserved in a visible, restorable conflict record** → Photos export visibly blooms → HEIC import without bogus warning → SE graceful → airplane-mode both-ends converges per rev policy → tombstone delete/undo round-trip → account deletion purges cloud+local, Mac originals untouched → over-quota surfaces terminal state → Sentry clean.

## Top risks

1. **libjpeg-turbo iOS cross-compile** (S1 timebox; toolchain file; viewer-only fallback).
2. **Photos re-encoding exports** (S2; share-sheet fallback).
3. **iPhone memory on full-res encode** (histogram fix + zero-copy + soft downscale).
4. **macOS keychain/provisioning for Firebase Auth** (S3 on notarized build; `-34018`; profile validity check ships with the first profile-bearing Mac release, expiry alerts verified in P8).
5. **App ID grouping missed before the first Sign-in-with-Apple-enabled build ships** (P0, ten minutes, permanent pain if missed).
6. **Public-TestFlight cost exposure** (reservation quota + admission cap + kill switch).
7. **Cross-provider identity split** (grouping + linking + recovery UI).
8. **>30-day-offline reconcile** (ack-aware mode — built, not assumed).
9. **Look parity across GPUs** (tolerance verification; Metal-kernel port if drift visible).

## Costs & ops

us-central1 (irreversible); ≈$0.15-0.75/user/mo at 5 GiB; egress free tier per-project — admission cap bounds exposure; re-verify pricing at implementation. firebase-ios-sdk bloats the Mac app (Sparkle deltas, signing — measure at S3/P1). Plists public config — commit. **Developer-ID provisioning profile expiry tracked (archive-time validation + 90/60/30-day alerts + replacement-release plan).** Post-implementation: update memories (`gainmap-repo-and-updates` + schema/provisioning/auth). Spec doc: after approval → `docs/superpowers/specs/2026-07-27-gainmap-ios-sync-design.md`, committed during implementation.

## Critical files

- `Gainmap/project.yml` — targets, xcframework, Firebase/GoogleSignIn packages
- `Gainmap/Sources/MergeModel.swift` — state machine + DI seams (`:505-509`); session refactor; live-look flush
- `Gainmap/Sources/UHDRRunner.swift` — pure/Process split; `Gamut`/`looksLikeMergedOutput` iOS handling
- `Gainmap/Sources/AutoHDR.swift` — untouched engine; `carriedProperties` (GPS disclosure); RawBuffer transition in P2
- `Gainmap/Sources/ContentView.swift` — LookControls extraction
- `Gainmap/Sources/HDRPreview.swift` — renderer seam + EDR UIView twin
- `Gainmap/Sources/Support/Gainmap.entitlements` — keychain-access-groups + applesignin
- `Gainmap/scripts/build-binary.sh` — dynamic signing-identity resolution
- `upstream/src/encoder.{h,cpp}` — memory API + histogram computeClamps
- `upstream/CMakeLists.txt` + new `Gainmap/scripts/build-uhdr-xcframework.sh` — the cross-compile
- New: `Gainmap/Core/**`, `Gainmap/iOS/**`, `firestore.rules`, `storage.rules`, `functions/{admitSyncUser,reserveUpload,usageReconciler,maintenance,deleteAccount}`
