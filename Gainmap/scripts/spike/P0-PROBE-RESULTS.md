# P0 real-project reservation-lifecycle probe — evidence record

Date: 2026-07-27 · Project: **`gainmap-probe-lab-7f3`** (throwaway, us-central1, Blaze
acct `0178A5-AD0977-C4588E`) · Bucket: `gainmap-probe-lab-7f3.firebasestorage.app`
Spec: `docs/superpowers/specs/2026-07-27-gainmap-ios-sync-design.md` ("Quota — reservation
state machine (r6)").

`gainmap-production` was never touched. Every command in this record ran against the
throwaway project above.

> **Production correction — 2026-07-29:** The IAM interpretation in provisioning
> finding 1 below is historical and must not be used as the current runbook. On
> `gainmap-production`, granting `roles/firebaserules.firestoreServiceAgent` only to
> `service-<NUM>@firebase-rules.iam.gserviceaccount.com` still left every authenticated
> upload denied. Current Firebase guidance and a live production recovery established
> that the role is required on the Firebase Storage service agent,
> `service-<NUM>@gcp-sa-firebasestorage.iam.gserviceaccount.com`. Adding that binding
> allowed all six queued uploads to complete. The original probe result is retained below
> as evidence of what was observed in the throwaway project.

**Question:** the spec's two-deadline reservation model rests on one platform claim —
*"Cloud Storage resumable sessions stay valid up to a week; rules are checked at upload
start, not finalize"* (spec line 43, restated in `storage.rules` lines 70–72). The emulator
cannot test this. Does an upload authorized inside the `startBefore` window still complete
after that window closes?

## Verdict: **the load-bearing claim is FALSE.** Assertion E FAILED.

Storage rules are evaluated at **finalize**, not at resumable-session start. `startBefore`
is therefore not an authorization window to *begin* an upload — it is a hard deadline by
which the upload must **finish**. This contradicts the spec and forces a design change
before anything is built on P0. Details and options in "Consequences" below.

---

## Assertion results

| # | Assertion | Result |
|---|---|---|
| A | `admitSyncUser` admits, provisions `users/{uid}` + zeroed `usage/storage` | **PASS** |
| B | `reserveUpload` → reservation doc, `startBefore`≈now+90s, `releaseAfter`=startBefore+600s, `reservedBytes` charged | **PASS** |
| C | Resumable session start inside the window returns a session URL | **PASS** (but see note — proves less than intended) |
| CTRL | Reserve → start → finalize **entirely inside** the window succeeds | **PASS** |
| D | Test clock genuinely past `startBefore`, still inside the lease | **PASS** |
| **E** | **Upload authorized inside the window COMPLETES after the window closed** | **FAIL — HTTP 403** |
| E2 | Re-reserving (refreshing `startBefore`) immediately before finalize rescues the same session | **PASS** |
| F | Reconciler on real Eventarc: `renditions.thumbs` written, reservation deleted, reserved→used | **PASS** |
| G | New upload on an expired reservation is rejected | **PASS** (rejected at finalize, not at start) |
| H | Upload to a never-reserved object name is rejected | **PASS** (rejected at finalize, not at start) |

Probe uid `plhLHo1WUkbPltQKfwoT0lKOVx13`; overrides `config/testing = {startWindowSec: 90,
leaseSec: 600}` — honoured, confirming the non-production override path in
`functions/lib/reserve.js:resolveDeadlines` works on a real project.

### E — the core claim (FAIL)

```
21:02:37.707  reserveUpload f1 (200000 B)  startBefore=21:04:07.379  releaseAfter=21:14:07.379
21:02:38.834  resumable session START      HTTP 200, upload URL captured   (89s before startBefore)
21:04:40.562  [waited 120s]                33.2s PAST startBefore, 566.8s BEFORE releaseAfter
21:04:41.376  finalize (PUT bytes)         HTTP 403 Permission denied      <-- spec says this must succeed
```

The CONTROL rules out every confound: an identical reserve → start → finalize sequence run
entirely inside the window returned **200**. The only variable between CONTROL and E is that
E crossed `startBefore` before finalizing. The clause that denies is
`request.time < reservation.data.startBefore` in `storage.rules` — `request.time` is the
*finalize* time, not the session-start time.

### Enforcement point (the underlying platform behaviour)

Bisected with a temporary diagnostic ruleset (deployed only to the throwaway project via a
separate `/tmp` `firebase.json`; the repo's `storage.rules` was never modified, and the real
ruleset was restored before the recorded run):

```
rule = auth only ............................ start 200, finalize 200
rule = auth + contentType/size ............... start 200, finalize 200
rule = + firestore.get(config/flags) ......... start 200, finalize 200
rule = + firestore.get(reservation) .......... start 200, finalize 200
never-reserved object, real rules ............ start 200, finalize 403
expired reservation, real rules .............. start 200, finalize 403
```

**Session start never evaluates Storage rules.** A session URL is issued for any object
name, including one with no reservation at all. `request.resource.size` / `contentType` are
populated at start (the payload clauses pass there), but the whole ruleset is only actually
enforced when the bytes land. Assertion C's 200 therefore proves only that a URL was issued.

### F — reconciler on real Eventarc (PASS)

Reconciled **10.9 s** after finalize, first poll:

```
users/{uid}/blobs/{hash}.renditions.thumbs = {
  generation: "1785186159628518"   (string — int64-safe, as designed)
  byteSize: 100000, counted: true, lastEvent: "finalized",
  uploadedAt: 2026-07-27T21:02:39.782Z
}
reservation doc users/{uid}/reservations/thumbs_{hash}  -> DELETED
usage/storage = {bytesUsed: 220000, objectCount: 2, reservedBytes: 350000}
```

`bytesUsed` 220000 = CONTROL 100000 + E2 120000; `reservedBytes` 350000 = the two
deliberately-unconsumed reservations (f1 200000 + f2 150000), which is correct — their
capacity leases had not yet expired, so `maintenance` had not released them. Reserved→used
conversion, reservation deletion, and the generation ledger all behave exactly as designed.

---

## Consequences for the design (this forces replanning)

1. **`startBefore` is a completion deadline, not a start deadline.** With the shipped default
   of 30 min, any upload that takes longer than 30 min from `reserveUpload` to finalize dies
   with a 403 **after the bytes have already been transferred**. A 64 MB original on a slow
   or interrupted connection is squarely in that range; this is a realistic user-facing
   failure, not a corner case.
2. **The r6 two-deadline rationale is inverted.** `releaseAfter = startBefore + 8 days` was
   sized so the capacity lease could outlive a week-long resumable session. But the session
   can never usefully outlive `startBefore` at all, so the 8-day lease currently just holds
   quota for uploads the rules will refuse.
3. **E2 shows the fix is bounded and cheap.** Re-calling `reserveUpload` for the same
   `(contentHash, tier, byteSize)` refreshes `startBefore` (`refreshed: true`, no
   double-count) and the *already-open* session then finalizes **200**. So the session
   itself stays valid across the window — only the rule check fails. Options, in rough order
   of preference:
   - **Drop the time comparison from `storage.rules`** and let the reservation's existence be
     the authorization, with `maintenance` deleting reservations after `releaseAfter`. The
     lease then becomes the single deadline and the rule stays within its 2-`get()` budget.
   - **Have `TransferQueue` refresh the reservation immediately before finalizing** (and on
     resume), keeping the rule as-is. Proven to work by E2, but it is a client-side liveness
     obligation, and a client that dies mid-upload still loses the bytes.
   - Keep both deadlines but compare against `releaseAfter` rather than `startBefore`.
4. **No upload can be rejected before its bytes are spent.** Since rules do not run at
   session start, an unauthorized or over-quota upload is only refused at finalize. The
   security posture is intact (the write *is* denied), but the client must treat a late 403
   as an expected outcome, and the spec's "unreserved/expired-reservation upload rejected"
   P0 exit criterion is satisfied at finalize rather than at start.

Two smaller spec/plan mismatches found while reading the code, corrected in this probe:
the authorized object is `users/{uid}/{tier}/{contentHash}.jpg` (no `_1024` suffix), and the
server-owned ledger key is `renditions.<tier>` (e.g. `renditions.thumbs`), not
`renditions.thumb1024`.

---

## Provisioning findings (fold into the P0 runbook before `gainmap-production`)

1. **Corrected production runbook: grant
   `roles/firebaserules.firestoreServiceAgent` to the Firebase Storage service agent.**
   Cross-service rules (`firestore.get()` inside `storage.rules`) require:
   ```
   gcloud projects add-iam-policy-binding <P> \
     --member="serviceAccount:service-<NUM>@gcp-sa-firebasestorage.iam.gserviceaccount.com" \
     --role="roles/firebaserules.firestoreServiceAgent" --condition=None
   ```
   Without the binding, every create can be refused with a bare `403 Permission denied`
   that names no failed clause. The emulator cannot catch this because it does not enforce
   IAM. The 2026-07-27 probe appeared to recover only after granting the role to
   `service-<NUM>@firebase-rules.iam.gserviceaccount.com`, while granting it to the Storage
   agent appeared ineffective. That attribution was disproved by the 2026-07-29 production
   incident: the Rules-agent-only configuration failed, and the Storage-agent binding
   restored every queued upload.
2. **Firebase Auth config must be initialised before any provider can be enabled.**
   `PATCH .../admin/v2/projects/<P>/config` returns `404 CONFIGURATION_NOT_FOUND` on a fresh
   CLI-created project. Fix: `POST https://identitytoolkit.googleapis.com/v2/projects/<P>/identityPlatform:initializeAuth`
   with `{}` first, then the anonymous/provider PATCH succeeds.
3. **Propagation delays are long enough to produce false failures.** Callables returned an
   HTML `401 Unauthorized` from the Google frontend for ~2 min after deploy despite
   `allUsers`/`roles/run.invoker` already being present, and a Storage-rules redeploy caused
   ~30 s of spurious `403`s at session start. Allow ~2–3 min to settle before verifying, and
   re-test before believing any post-deploy failure.
4. `gcloud beta services identity create` ignores a trailing `--quiet` for the
   component-install prompt; use `CLOUDSDK_CORE_DISABLE_PROMPTS=1`.
5. Pre-granting `roles/eventarc.serviceAgent` and `roles/pubsub.publisher` **before** the
   first deploy worked — all 6 handlers (incl. both `usageReconciler*`) were created on the
   first attempt with no Eventarc validation retry.
6. Harness note for whoever writes the client: the resumable **finalize** request must carry
   `Authorization: Firebase <idToken>`, exactly as the session-start request does. Omitting
   it yields the same undifferentiated `403` and is easy to misread as a rules failure.

## Reproduction

Probe scripts and full timestamped logs: `/tmp/gainmap-probe/` (`probe2.mjs`, `probe3.log`,
`diag*.mjs`). Not committed — they hardcode the throwaway project's public web API key.

## Wrap-up

Project left provisioned (useful for S3) with **`config/flags.syncEnabled = false`**, so
`reserveUpload` refuses and Storage rules deny every create until it is flipped back.

**P0 probe result: assertion E FAILED — the reservation state machine needs a design change
before P4 builds on it. All other assertions PASS.**

---

## Re-probe (r7 single-deadline design) — 2026-07-27 21:40Z

After the E failure the backend was reworked to single-deadline reservations
(`expiresAt = now + lease`; commit `cdfcc8e`) and redeployed to this probe project
(`config/testing.leaseSec = 120`). All assertions PASS:

| # | Assertion | Result |
|---|---|---|
| R1 | reserve → start resumable → wait past `expiresAt` (+30 s) → finalize | **PASS — 403** |
| R2a | re-reserve after the 403 is an idempotent refresh (`refreshed: true`, new `expiresAt`) | **PASS** |
| R2b | reusing the 403-terminated session | **PASS — 400 "Upload has already been terminated"** |
| R2c | re-reserve → NEW resumable session → finalize | **PASS — 200** |
| R3 | control: fresh reserve → immediate upload inside the lease | **PASS — 200** |
| R4 | reservation doc carries `expiresAt`; no `startBefore`/`releaseAfter` remain | **PASS** |

```
21:40:11.551  reserveUpload (200000 B)   expiresAt=21:42:11.317 (120s lease)
21:40:11.888  resumable session START    HTTP 200, upload URL captured
21:42:42.340  finalize (31s past lease)  HTTP 403                          <- R1
21:42:42.729  re-reserve                 refreshed:true, new expiresAt     <- R2a
21:42:42.829  finalize, SAME session     HTTP 400 "already terminated"     <- R2b
21:42:44.021  finalize, NEW session      HTTP 200                          <- R2c
```

**New platform fact (R2b), refining the original E2:** a rules-DENIED finalize
terminates the resumable session. E2's "refresh revives the session" holds only when
the refresh lands BEFORE a denied finalize. Client contract, final form: on a
finalize 403, re-reserve and start a NEW upload session (do not retry the old URL).

Probe uid `b3Qv0wNxeggCYX1nBAgJHduSWIL2`; script `reprobe.mjs` (session scratchpad,
not committed — hardcodes the throwaway project's web API key). Project re-parked:
`syncEnabled=false`, `signupsOpen=false`.

**Re-probe verdict: the r7 single-deadline design is verified against the real
platform. P0 backend is clear to deploy to gainmap-production.**
