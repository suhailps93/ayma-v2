# Staging backend config

Staging mirrors prod (`docs/deploy.md`, `scripts/deploy-api.sh`,
`scripts/deploy-agent.sh`): same GCP project (`ayma-ai`) and region
(`us-central1`), two Cloud Run services, `min-instances 0` on both.

| Staging service | Mirrors prod | Build |
|---|---|---|
| `ayma-api-staging` | `ayma-api` | `--source functions/bootstrap` (same) |
| `ayma-agent-staging` | `ayma-agent` | `Dockerfile.agent`, tagged `:staging` (prod uses `:latest`) |

Deploy: `scripts/deploy-staging.sh --check`, then
`scripts/deploy-staging.sh --full` (first time) or bare for code-only.
Execution commands + pre-flight: `docs/agents/handoffs/staging-deploy-prep.md`.

## Secrets (all mounted from Secret Manager, never plaintext)

| Env name | Secret mounted | Staging-specific or shared? | Notes |
|---|---|---|---|
| `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` | same prod secrets | **Shared** | Same LiveKit Cloud project; staging rooms are namespaced by `LIVEKIT_ROOM_PREFIX=ayma-staging-` instead |
| `CRON_SECRET` | `CRON_SECRET_STAGING` | **Staging-only** | Must differ from prod so a leaked staging value can't hit prod `/cron/*` |
| `ADMIN_PASSWORD` | `ADMIN_PASSWORD_STAGING` | **Staging-only** | |
| `DEV_PANEL_PASSWORD` | `DEV_PANEL_PASSWORD_STAGING` | **Staging-only** | |
| `REVENUECAT_WEBHOOK_SECRET` | `REVENUECAT_WEBHOOK_SECRET_STAGING` | **Staging-only** | Point a separate RevenueCat webhook (test store) at staging |
| `GOOGLE_IMPORT_CLIENT_SECRET` | same prod secret | **Shared** | Same Google OAuth client; staging's redirect URI must be registered on it (the deploy script prints it) |
| `INSTAGRAM_APP_SECRET` | same prod secret | **Shared** | Placeholder (V2), same as prod |
| `GOOGLE_API_KEY` (agent) | same prod secret | **Shared** | Same Gemini Developer API key; voice usage bills the same key |
| `SENTRY_DSN` | *(not mounted)* | **n/a — Sentry OFF** | Unset = Sentry fully off (same rule as prod). To enable: create `SENTRY_DSN_API_STAGING` / `SENTRY_DSN_AGENT_STAGING` secrets and add mounts; `SENTRY_ENVIRONMENT=staging` is already set |

Each new `*_STAGING` secret needs the same `secretAccessor` IAM grant for the
Cloud Run runtime service account as prod (`docs/deploy.md` §Secrets), or the
revision fails to start.

## Plain env vars (non-secret, set by `--full`)

| Var | Staging value | Staging-specific or shared? |
|---|---|---|
| `GOOGLE_CLOUD_PROJECT` | `ayma-ai`, or `--firebase-project` value | **Configurable** (default = shared/prod) |
| `STORAGE_BUCKET` | `<data-project>.firebasestorage.app` | **Follows data project** |
| `AYMA_AGENT_URL` (both services) | `ayma-agent-staging` Cloud Run URL | **Staging-only** (resolved pass 2) |
| `GOOGLE_IMPORT_REDIRECT_URI` | `<staging-api-URL>/google/oauth-complete` | **Staging-only** (resolved pass 2) |
| `LIVEKIT_ROOM_PREFIX` | `ayma-staging-` | **Staging-only** (prod default `ayma-`) |
| `SENTRY_ENVIRONMENT` | `staging` | **Staging-only** (prod default `production`) |
| `USE_VERTEX`, `VERTEX_LOCATION` | `true`, `us-central1` | Shared (same as prod) |
| `LIVEKIT_URL`, `LIVEKIT_PROJECT_ID` | same LiveKit Cloud project | Shared |
| `GOOGLE_IMPORT_CLIENT_ID` | same OAuth client id | Shared (public value, same as prod) |
| `CONTEXT_OPT_LEVEL`, `CONTEXT_OPT_MEASURE` | `3`, `true` | Shared (same as prod) |
| `GEMINI_LIVE_USE_DEV_API` (agent) | `true` | Shared (same as prod) |
| `IMAGE_VARIANTS_ENABLED` (api) | `true` | **Staging-only** — cloud profile-photo variants (Perf Phase 2 PREP chunk A); set only when the data plane is `ayma-staging` (see `docs/perf/image-variants.md`); unset everywhere else (fail closed) |
| `IMAGE_VARIANTS_PUSH_SA` (api) | `pubsub-push-invoker@ayma-staging.iam.gserviceaccount.com` | **Staging-only** — Pub/Sub push OIDC identity pinned by the variant endpoint |
| `OPEN_WEIGHTS_BASE_URL` (api) | Modal `…/v1` endpoint | **Staging-only** — wires the open-weights cheap path (hackathon); routes **nothing** on its own (a surface reaches it only when its `LLM_PROVIDER_*` flag is `open-weights`; default stays `gemini`). Credit-guarded — see `scripts/modal_open_weights.py` |
| `OPEN_WEIGHTS_COLD_START_TIMEOUT_S` (agent) | `120` | First-token timeout (seconds) for the VOICE cascade's **open-weights** LLM leg only (Modal scale-to-zero cold start ~100s). Widens *only* that leg from the 10s LiveKit default so a cold Modal still replies; Meta/Inference legs keep the default. See ARCHITECTURE.md §13.9 cold-start handling. |

Model ids / voices / Vertex locations stay locked in
`functions/bootstrap/config.py` — never env vars, same as prod. `LLM_PROVIDER`
is untouched: Gemini remains the default everywhere.

Everything else the code reads (`RATE_*`, credit/economy tunables,
`SHARE_*`, `REENGAGE_*`, voice timeouts, `IMAGE_SEARCH_*`,
`REVENUECAT_SECRET_API_KEY`, …) keeps its code default on staging exactly as
on prod — the prod scripts don't set them either.

## Staging phone build (both axes)

A phone build must match the staging backend on **two** axes or auth breaks: the
app signs into Firebase with the Dart config in `firebase_options.dart`
(`Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)`), and
it calls the API at `AYMA_API_BASE_URL` (`env.dart`). If Firebase stays prod
(`ayma-ai`) while the API points at staging, the app mints a **prod** ID token
that the staging backend rejects → history load fails, long cold start, error
block. (Root cause of the 4264706 build failure, 2026-11-01.)

Build a correct staging phone APK with:

    scripts/build-apk.sh --debug --staging

`--staging` (dev builds only) does both axes from one committed source of truth,
`ayma_flutter/android/app/google-services.staging.json` (the ayma-staging
Android app, package `com.ayma.ayma_flutter`, public client config — not a
secret):
- swaps that file in as the native `google-services.json` for the build
  (restored afterwards via an EXIT trap), and
- injects the matching `--dart-define`s: `AYMA_API_BASE_URL=<staging api>` plus
  `FB_PROJECT_ID`, `FB_MESSAGING_SENDER_ID`, `FB_STORAGE_BUCKET`,
  `FB_ANDROID_APP_ID`, `FB_ANDROID_API_KEY` (read from that JSON), which
  `firebase_options.dart` reads with prod defaults so prod/store builds are
  unchanged.

Verify the artifact before delivery: `strings`/`aapt dump` the APK must show
`ayma-staging` for the Firebase project **and** the staging API host, never
`ayma-ai`. The two Firebase axes live in **different parts** of the APK and must
BOTH be staging — check them separately (Scout NOTE 263, build 2515: a mixed
APK had Dart=staging but native=prod, so every authed call 401'd):

    unzip -p app.apk resources.arsc        | strings | grep -oE '1:[0-9]+:android:[a-z0-9]+'   # NATIVE (google-services) — the one that mints tokens
    unzip -p app.apk lib/arm64-v8a/libapp.so | strings | grep -oE '1:[0-9]+:android:[a-z0-9]+'   # DART (firebase_options)

The **native** id is authoritative: on Android it auto-creates the `[DEFAULT]`
FirebaseApp before Dart runs, so a prod native config mints prod-aud tokens even
when `firebase_options.dart` is staging. Staging = `1:187469876115:…`
(ayma-staging); prod = `1:235381544962:…` (ayma-ai). If they disagree the APK is
mis-built — rebuild with `scripts/build-apk.sh --staging` (don't ship a plain
`flutter build apk`, which bakes the repo-default **prod** `google-services.json`).
At runtime `FirebaseConfigGuard` (startup DAG N7 → splash) now catches this
mismatch and shows an honest blocking diagnostic instead of a silent
401→sign-in loop — so a mixed APK fails loud, but the fix is still to install a
correctly built one. **Standing rule (from the 4264706 failure): Scout bench-verifies the
exact staging artifact on the emulator — sign in, cold start, chat history, no
error block — before it is offered to the founder. No exceptions.**

### Google Sign-In: dedicated staging keystore (third axis)

Google sign-in needs a **third** thing beyond the two axes above: an **Android
OAuth client** on the Firebase Android app, keyed by `(package, signing-SHA-1)`.
Those clients are **globally unique** per `(package, SHA-1)` across all of
Google Cloud, and prod (`ayma-ai`) already globally owns the pair
`(com.ayma.ayma_flutter, 47:95:21:…:3F:5D)` — the **shared default debug
keystore** SHA-1. So ayma-staging could never create an Android OAuth client for
that pair: `google-services.staging.json` had only a `client_type: 3` (web)
entry, no `client_type: 1` (android), and on-device Google sign-in failed with
`GoogleSignatureVerifier: package info is not set correctly` / `unknownError`.

Fix: `--staging` builds are signed with a **dedicated staging debug keystore**
with a **different SHA-1**, so ayma-staging owns its own Android OAuth client.

- Keystore: `ayma_flutter/android/ayma-staging-debug.keystore`, alias
  `aymastaging`, store/key password `ayma-staging` (committed — it only ever
  signs dev/staging test builds, never a store release, exactly like Android's
  shared default debug keystore; it carries no release trust).
  - SHA-1: `0D:AA:76:6D:4F:17:E3:BB:07:66:2E:E1:33:0D:30:31:26:2F:F3:C2`
  - SHA-256: `90:65:5F:15:65:C0:29:9C:01:8F:B1:1B:ED:D4:C2:31:DD:27:AA:11:FC:F9:E7:D8:9B:2F:54:ED:49:18:94:28`
- Both SHAs are registered on the ayma-staging Android app (App ID
  `1:187469876115:android:adb41422d11627ddcd3666`); Firebase then created the
  staging Android OAuth client
  (`187469876115-fosufjrncr5cingnvs2aa47l13pumd79.apps.googleusercontent.com`),
  now present in `google-services.staging.json` as the `client_type: 1` entry
  whose `certificate_hash` is the staging SHA-1 (lowercased, no colons).
- Wiring: `build.gradle.kts` defines a `stagingDebug` signing config and applies
  it to the `debug` **and** `profile` build types when the Gradle property
  `aymaStagingSign` is present; `build-apk.sh --staging` passes
  `-PaymaStagingSign=true` plus the keystore path/alias/passwords. With the
  property absent (normal/prod/default `--debug`), nothing changes and the build
  stays on the shared default debug keystore. (`profile` is staging-signed so the
  AOT boot-gate APK below matches the debug APK's signature — Scout can
  `adb install -r` between them without losing the signed-in fixture.)

Verify a `--staging` APK is staging-signed:

    apksigner verify --print-certs app-debug.apk
    # Signer #1 SHA-256 must equal the staging keystore's 90655f15…189428,
    # NOT the default debug keystore's 16581138…10b5.

> **⚠️ Reinstall caveat.** The staging APK's signature now **differs** from any
> previously-installed build (which used the default debug keystore). `adb
> install -r` will FAIL with `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (signature
> mismatch). To install the new staging build, first
> `adb uninstall com.ayma.ayma_flutter`, then `adb install app-debug.apk`.
> Uninstall wipes local app data, so the user signs in fresh.

### AOT build for the boot / first-launch gate (NOTE 226)

The `--debug --staging` APK is a **JIT** build: `flags=[ DEBUGGABLE ]`, a ~113 MB
`assets/flutter_assets/kernel_blob.bin`, no AOT `libapp.so`. On first launch the
Dart VM loads and JIT-compiles that kernel **on the main thread** (ANR traces
across v2439/v2442/v2452: main thread in native Dart-VM code, ~160 % CPU, 27k+
page faults), which trips the 5 s input-dispatch watchdog on a loaded emulator →
the "Input dispatching timed out … FocusEvent" freeze Scout reported (NOTE 226).
**This is a debug-build artifact, not an app bug** — the release build real users
install from Play is AOT and starts in seconds.

So the **boot / first-launch gate runs on an AOT build**, built per staging batch
alongside the debug APK:

    scripts/build-apk.sh --profile --staging

`--profile` is AOT (real `libapp.so`, no `kernel_blob.bin`) and — because the
`profile` build type is staging-signed too (see above) — carries the **same
staging signature** as the debug staging APK, so Scout can `adb install -r`
between the two without uninstalling (the signed-in fixture is preserved).
Subscription legs STAY on the `--debug` APK: the RevenueCat TEST key only
activates subscriptions in a debug build.

Verified on a staging tip (f730a7d1 / versionCode 2453, emulator-5554):

| | `--debug --staging` (JIT) | `--profile --staging` (AOT) |
|---|---|---|
| APK | 231 MB, `kernel_blob.bin`, DEBUGGABLE | 164 MB, `libapp.so`, no kernel_blob |
| `am start -W` cold | **Status: timeout**, 12–21 s | **Status: ok**, ~11 s (one-time dexopt) |
| warm | — | **Status: ok**, ~42 ms |
| first-launch ANR | yes (FocusEvent) | **no** |

Per batch (owned by the sweep that publishes the staging release): run
`scripts/build-apk.sh --profile --staging`, then publish the AOT APK next to the
debug one, e.g. `gh release upload staging-<tip> app-profile.apk` renamed
`ayma-staging-<tip>-aot.apk --clobber`. Scout's per-batch brief then points the
**boot / first-launch leg** at the `-aot` APK (`adb install -r` over the
signed-in debug build, then first launch) and keeps **subscription / RevenueCat
legs** on the debug APK.

## Opening + unlocking the Developer panel (to see owner-only `ayma_only` photos)

The hidden Developer panel is how a tester reveals owner-only content such as the
retained **"Ayma-only Photos"** group in the Story editor (a deleted-but-retained
photo moves to `ayma_only`; it never renders on the story body or any public
surface, and a normal locked user never sees it — `story_editor_screen.dart`
gates the group on `DevPanelSession.unlocked`). Revealing it is a **two-step**
unlock, not one:

1. **Open the panel** — Settings → scroll to the bottom **Version** row (widget
   key `build-stamp`, label `Version <x.y.z>+<build> · staging`) and tap it
   **7 times, each tap within 2 s of the previous one** (`_tapsToUnlock = 7`,
   `_tapWindow = 2 s` in `settings_screen.dart`), or **long-press** it once.
   The panel opens to a **password field** titled *Developer* with the text
   *"Enter the developer password to continue."* (key `dev-locked`) — seeing
   that screen IS "the panel opened".
2. **Unlock the contents** — enter the developer password and submit; the app
   calls `POST /dev/verify` against the `DEV_PANEL_PASSWORD` secret (ayma-api).
   On success `DevPanelSession.unlocked` flips true (in memory only; a restart
   or a 5-min backgrounding re-locks). Only then does the Story editor render
   the **Ayma-only Photos** group.

**Automation / adb gotchas (NOTE 262, build 2514 — Scout "panel won't open"):**
the open gesture, the `ENABLE_DEV_MODE` flag and the `/settings/developer` route
are all **intact and unchanged** across 2511→2514 (no code regression). Two real,
non-code reasons the 7-tap fails under automation on a **`--debug` (JIT) APK**:

- **Per-tap window.** EACH tap must land within 2 s of the previous one, or the
  run counter resets to 1 and never reaches 7. Slow `adb input tap` / uiautomator2
  taps (>2 s apart) silently reset — send the 7 taps with a tight cadence
  (≤1.5 s apart), e.g. a single `for` loop with no per-tap sleep.
- **First-launch JIT ANR.** On the debug JIT APK the first-launch ANR
  (see the AOT section above, NOTE 226) eats input dispatch on a loaded
  emulator, so the navigation/taps don't register. **Verify the gesture on the
  `--profile` (AOT) staging APK**, which launches clean — the gesture code is
  byte-identical between the debug and AOT builds.

## Data isolation

- **Default (no `--firebase-project`): staging shares prod Firestore/Auth/Storage.**
  Good enough for a deploy smoke test; do not run destructive tests this way.
- **Preferred: separate staging Firebase project** (pass `--firebase-project`).
  Then also: deploy firestore rules/indexes to it, and grant the Cloud Run
  runtime service account (`235381544962-compute@developer.gserviceaccount.com`,
  the same prod default compute SA) access in that project — it has **none** by
  default, so cross-project grants are required or every call is
  `PERMISSION_DENIED`. Roles granted for `ayma-staging`: `roles/datastore.user`
  (Firestore), `roles/storage.admin` (uploads bucket) and `roles/aiplatform.user`
  (Vertex Gemini runs under `GOOGLE_CLOUD_PROJECT`, so inference bills + auths in
  the data project). `firebase_admin` picks the project up from
  `GOOGLE_CLOUD_PROJECT` via ADC — verified 2026-11-01 with a service-mediated
  write probe (`POST /brain/preference` as demo-test1): the write landed in
  `ayma-staging` and prod `ayma-ai` was untouched.
- **Not staged (deliberately):** Cloud Scheduler jobs (no staging cron jobs —
  trigger `/cron/*` manually with the staging secret), Firebase Hosting
  rewrites, `justabot.info` domain mapping, RevenueCat production webhook.

## Prod → staging 1:1 data sync

`scripts/sync-prod-to-staging.sh` copies a **full 1:1 snapshot of production
(`ayma-ai`) into the staging data project (`ayma-staging`)** so staging holds
real accounts, profiles, conversations, photos and biometric data. Founder
decision 2026-11-01: a Full 1:1 copy.

> **⚠️ PRIVACY — read before touching this.** This pipeline **intentionally
> replicates real-user PII and biometric data** (profiles, conversations,
> uploaded photos, and the `verification/` face-biometric objects) into staging.
> That is the founder's explicit decision (2026-11-01), not an accident. Treat
> `ayma-staging` as holding production PII: same access discipline as prod, no
> wider sharing, no exports off these two projects.

### What it copies (three planes)

| Plane | Source (read-only) | Dest (writes) | Mechanism |
|---|---|---|---|
| **Firestore** | `ayma-ai` (default db) | `ayma-staging` (default db) | `gcloud firestore export` → staging-owned bucket → `gcloud firestore import`. Import is **overwrite-by-document-path (additive)** — any path present only in staging (e.g. staging-only `demo-*` / `demo-edge-*` docs absent from prod) is **left untouched**. |
| **Storage** | `gs://ayma-ai.firebasestorage.app` | `gs://ayma-staging.firebasestorage.app` | `gsutil -m rsync -r` (SOURCE → DEST). **No `-d`**, so the rsync is additive and never deletes staging-only objects. |
| **Auth users** | `ayma-ai` | `ayma-staging` | `firebase auth:export` → `firebase auth:import` with prod's **SCRYPT** hash params (algo/signer-key/salt-separator/rounds/mem-cost) read live from prod's Identity Platform config, so real passwords keep working. Import **upserts by uid**. |

The Firestore export lands in a dedicated **staging-owned** bucket
`gs://ayma-staging-prod-sync` (project `ayma-staging`, `us-central1`, 14-day
lifecycle) — prod's export data never lands in a prod bucket. The script
creates that bucket on first run and grants both projects' Firestore service
agents (`service-235381544962@…` prod, `service-187469876115@…` staging)
`roles/storage.admin` on it (IAM writes are on the staging bucket only).

**Post-import `wiki_pages` purge (person-graph switch, Phase 7).** The retired
`wiki_pages` store is deleted from staging after each Firestore import. The
import re-copies prod's still-live `wiki_pages` (prod runs flags OFF), and
managed import `--collection-ids` is include-only so it can't be excluded at
import time — so `sync_firestore` runs `scripts/purge_staging_wiki_pages.py`
**immediately after the import**, which recursively deletes every `wiki_pages`
document (both `users/{uid}/…` and `deleted_accounts/{uid}/…`) **and** its
`versions` subcollection. The purge is **staging-only**: the Python helper hard-
guards on project (refuses `ayma-ai`), and the sync calls it under the same
`assert_dest_is_staging` guard. In `--dry-run` it only counts. It touches
nothing on the prod side and does not change what the import pulls.

### One-way guardrails (ironclad)

This pipeline is **one-way, prod → staging, ONLY.** It never runs an
import/write/rsync whose target is `ayma-ai` or `gs://ayma-ai*`. The only prod
operations are read-only: `firestore export`, `gsutil rsync` with prod as
SOURCE, and `auth:export`. The script:

- hardcodes `SRC_PROJECT=ayma-ai` (read-only) and `DEST_PROJECT=ayma-staging`
  (the only write target) as `readonly` constants;
- runs `assert_dest_is_staging` at startup **and** immediately before every
  destructive gcloud/gsutil/firebase call — it aborts (`FATAL`) if any
  write/import/dest/export target resolves to `*ayma-ai*`, or to anything that
  is not `*ayma-staging*`;
- echoes the resolved SOURCE and DEST at the top of every run.

The password **signer key is never hardcoded** (AGENTS.md rule) — it is fetched
at runtime from prod's Identity Platform config and redacted in all logs.

### Cadence

Runs **nightly at 02:00 local** via cron on this machine, serialized with
`flock` so a long run never overlaps the next, with output appended to
`~/workspace/ayma-inbox/prod-sync.log`. The installed `crontab -l` entry is:

    # Ayma prod->staging 1:1 data sync — nightly 02:00, one-way, flock-guarded (docs/STAGING.md)
    0 2 * * * /usr/bin/flock -n /tmp/ayma-prod-sync.lock /bin/bash -c '[ -x /home/suhailps/workspace/ayma/scripts/sync-prod-to-staging.sh ] && /home/suhailps/workspace/ayma/scripts/sync-prod-to-staging.sh --execute || echo "[$(date -u +\%Y-\%m-\%dT\%H:\%M:\%SZ)] prod-sync skipped: script not yet merged to canonical path"' >> /home/suhailps/workspace/ayma-inbox/prod-sync.log 2>&1

The `[ -x … ]` guard makes the job a **clean no-op until this branch is merged**
and the script reaches the canonical `scripts/` path — so the nightly cron does
not run the unreviewed script against real PII before the lead engineer merges
it. It auto-activates the first night after merge; no cron edit is needed then.

Do **not** raise the frequency above nightly without asking the founder.
(A Cloud Scheduler job is an alternative, but cron-on-this-machine is simpler
and keeps the one-way logic in one audited script.)

### How to run manually

    # DRY-RUN first (no writes; shows resolved SOURCE/DEST + what would copy):
    scripts/sync-prod-to-staging.sh --dry-run

    # Execute the real sync (idempotent, safe to re-run):
    scripts/sync-prod-to-staging.sh --execute

    # Limit to one plane while debugging:
    scripts/sync-prod-to-staging.sh --execute --skip-storage --skip-auth

Prerequisites: `gcloud`/`gsutil`/`firebase` authenticated as a principal with
read on `ayma-ai` and write on `ayma-staging`, and ADC quota project set (the
script sets `GOOGLE_CLOUD_QUOTA_PROJECT` per firebase call automatically).
