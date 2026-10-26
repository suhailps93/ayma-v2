# Agent handoff

Everything a new agent (Claude, Codex, Gemini CLI, Cursor) needs to operate on Ayma the way the
founder's main session does. Rules live in `AGENTS.md`; this file holds the details. If the two
disagree, `AGENTS.md` wins. Last updated 2026-10-25. **No secret values appear here, only secret names
and where they live.** Never add any.

Read order: `AGENTS.md` -> `PLAN.md` (Progress Log) -> this file -> `docs/deploy.md`, `docs/agent.md`,
`docs/ARCHITECTURE.md` as needed.

---

## 1. Product and architecture

Ayma is an AI matchmaker/dating app. An AI persona ("Ayma") interviews users by text and voice, builds a
profile wiki, and scores matches. Users see **credits**, never dollars.

| Piece | Where | Notes |
|---|---|---|
| Mobile app | `ayma_flutter/` (Flutter, Android + iOS, package `com.ayma.aymaFlutter`) | version in `pubspec.yaml` (`1.30.0+2077` at time of writing) |
| Main API | `functions/bootstrap/` (FastAPI, `main.py`), Cloud Run `ayma-api` | min-instances 0 |
| Voice agent | `functions/bootstrap/agent.py`, Cloud Run `ayma-agent` (LiveKit worker) | scale-to-zero is intended; woken by `agent_wake.py` ping; each call holds a `/keepalive` request (`agent_keepalive.py`) so it is not reaped mid-call |
| Data | Firestore only (no mock/local DB, ever). Rules `firestore.rules`, indexes `firestore.indexes.json` | |
| GCP/Firebase project | `ayma-ai`, region `us-central1` | |
| Voice infra | LiveKit Cloud project `aimma-wt34nu3l` | |
| Billing/IAP | RevenueCat; webhook `POST /webhooks/revenuecat` (prod source of truth) + `POST /billing/sync` (app-driven, grants the pool for Test Store/sandbox and as resilience; see Credits section). Tiers in `config.py` `PLAN_TIERS` (plus $10, pro $20, max $100; prices agreed, do not re-ask) | |
| CI | `codemagic.yaml`: `ios-testflight` (manual, on request) and `android-firebase`. Android is normally built locally | |
| Errors | Sentry (DSN-gated, `sentry` flag) + Crashlytics | handled voice-start failures reported with id-only tags |
| Gates | biometric consent (app-wide 403 `biometric_consent_required`), 18+ (`age_gate.py`) | see `docs/ARCHITECTURE.md` section 0 |

**Locked Gemini models** (`functions/bootstrap/config.py`, "LOCKED MODELS" block; the only file allowed to
name a model): text/wiki/matching `gemini-3.7-flash` @ Vertex `global`; embeddings `gemini-embedding-2`
@ `global`; voice `gemini-live-2.5-flash-native-audio` @ `us-central1` (Vertex) or `gemini-3.8-live`
(Developer API, `GEMINI_LIVE_USE_DEV_API=true`, key from Secret Manager `GOOGLE_API_KEY`); TTS preview
`gemini-2.5-flash-preview-tts`; image edit `gemini-2.5-flash-image`; default voice `Aoede`. Do not change
any of these without the founder's explicit approval.

**LiveKit Inference** (Gemini through LiveKit's gateway; may or may not be covered by LiveKit credits,
unconfirmed): on `all-features-on` (deployed from there), not on `main`. JSON, vision, chat and voice default to
Inference there; `gemini.research`/`web_search`, Maps grounding, embeddings, batch, TTS preview and image edit stay on
Vertex. The as-built map and routing table are `docs/ARCHITECTURE.md` section 0; details in
`docs/LIVEKIT_INFERENCE_MIGRATION.md`. Gateway cannot do embeddings, image models, Google Search/Maps grounding, or
voice context compression.

**Feature flags** (branch `all-features-on`, doc `docs/FEATURE_FLAGS.md` there): one Firestore doc
`config/feature_flags`, cached 60 s. Resolution: env `FLAG_<NAME>` > the doc > legacy `config/llm_routing`
and `app_config/sentry` > code default. Flag keys: `llm_route_json|vision|chat` (`inference`/`vertex`),
`voice_provider` (`inference`/`google`), `llm_percent_*`, `llm_allowlist_*`, `llm_fallback_to_google`,
`maps_grounding`, `deepdive_public_profiles`, `deepdive_blocked_regions`, `vertex_ai_search`,
`vertex_ai_search_daily_cap`, `meta_integrations` (V2, off), `sentry`, `dev_panel` (on; turn off at store release;
also switchable in-app via `POST /dev/flags` with `DEV_PANEL_PASSWORD`). `sentry`, `meta_integrations` and
`dev_panel` are mirrored to `app_config/<flag>.enabled` for the app.

```
python3 scripts/flags.py list                       # effective values + source   (branch all-features-on)
python3 scripts/flags.py set <flag>=<value> --yes   # without --yes it is a dry run
python3 scripts/flags.py rollback --yes             # restore values from before the last write
python3 scripts/flags.py history
```

Fastest rollback to Google: `set llm_route_json=vertex llm_route_vision=vertex llm_route_chat=vertex
voice_provider=google --yes` (about 60 s, no deploy). On the older `livekit-inference` branch the doc is
`config/llm_routing` (set the feature route back to `google`) and voice is the `VOICE_PROVIDER` env.
**Flipping a flag that sends real traffic to a model is a model-lock decision: founder approval first.**

**Admin dashboard** `https://<ayma-api>/admin` (header `X-Admin-Password`, secret `ADMIN_PASSWORD`).
Rule: every figure comes straight from the provider (no manual or estimated numbers).
- `GET /admin/provider-spend`: Google Cloud spend from BigQuery dataset `billing_export` in `ayma-ai`
  (service identity, lags hours) and LiveKit Analytics API (`LIVEKIT_PROJECT_ID`, last 7 days only).
- `GET /admin/vendors`: every vendor in `functions/bootstrap/vendor_catalog.json` (24 now: cloud_run,
  firestore, vertex_ai, livekit_usage, livekit_inference, revenuecat, sentry, codemagic, apple_developer,
  google_play, ...) with value, method (`api` or `muse`), fetch time, stale flag (36 h) and "how to check".
- **Muse posts figures** it reads from vendor billing pages to `POST /admin/vendor-spend` with JSON fields
  `vendor, metric, amount, currency, period, source_url, collected_by ("muse"), fetched_at, note?`
  (`metric` matches `^[a-z0-9_]{1,48}$`, `source_url` is required, stored in Firestore `vendor_spend`).
  Validation lives in `functions/bootstrap/vendor_spend.py`; read it before posting. A vendor with no value
  shows `unavailable`; never guess.

Credits: display layer over `users/{uid}.token_usage`. Open follow-ups F1/F2 in `PLAN.md` (calibrate cost vs
measured tokens; keep browse + text chat free for zero-credit users).
Plan page "Where your credits went": `GET /usage?period=since_credit|7d|30d|all` adds `period_usage` (credits only,
friendly labels from `token_ledger.FEATURE_LABELS`, the one label map; a test fails if a `FEATURE_*` has no label),
aggregated from `users/{uid}/spend_events` cost at `credits_per_usd`; header total = sum of rows. "Since last credit
update" starts at the newest of `billing.credits_updated_at` (stamped on start grant, selfie unlock, daily rollover,
plan grant/renewal, expiry) and the top-level `credits_updated_at` (free reload). Events are capped (500), so a
longer window starts at the oldest retained event instead of under-reporting.

How a purchase grants the monthly plan credits (two paths, both in `billing.py`):
- **Production: the webhook.** `POST /webhooks/revenuecat` (shared secret `REVENUECAT_WEBHOOK_SECRET`) is the
  source of truth. On `INITIAL_PURCHASE`/`RENEWAL`/`PRODUCT_CHANGE`/`UNCANCELLATION` it sets the plan's monthly
  pool (`PLAN_TIERS[plan].pool_usd`) and stamps `billing.credits_updated_at`; idempotent on `event.id`.
- **Sandbox/Test Store + resilience: `POST /billing/sync`.** A RevenueCat **Test Store** (fake/simulated)
  purchase does **not** send the server webhook, so the SDK shows Pro while the backend never credits — this was
  the founder's "purchase completes but credits don't go up" (build 2211). The app now calls `POST /billing/sync`
  (authenticated) on every successful purchase/restore and on every RevenueCat customer-info change
  (`listenForEntitlementChanges`, wired in `main.dart`). The endpoint grants/refreshes the same monthly pool,
  idempotently — keyed on plan + period end, so a re-sync in the same period is a no-op (`already_synced`) and
  never double-credits; no active entitlement = no grant (`no_active`); downgrade/expiry falls back lazily via
  `normalize`. It stamps `billing.credits_updated_at` so the Plan page's "since last credit update" resets.
  - **With `REVENUECAT_SECRET_API_KEY` set** (Secret Manager, a RevenueCat REST `sk_...` key): the server reads
    the active entitlement from RevenueCat's REST API (`GET /v1/subscribers/{uid}`) itself — authoritative, works
    for everyone including the Test Store, client body ignored.
  - **Without that key** (current state): only a **dev-view** caller (founder allowlist, `dev_view_emails`/
    `dev_view_uids`) is credited, from the app-reported entitlement in the request body — debug/test only, a
    release client is never trusted. Everyone else gets `no_active` and the webhook stays the only grant path.
- **Action for founder/Muse:** to make Test Store (and non-dev sandbox) purchases credit via the REST path, add
  Secret Manager secret **`REVENUECAT_SECRET_API_KEY`** (a RevenueCat **secret** REST key, `sk_...`, from the
  RevenueCat dashboard → API keys) and mount it on `ayma-api` — append
  `REVENUECAT_SECRET_API_KEY=REVENUECAT_SECRET_API_KEY:latest` to the `SECRETS` line in `scripts/deploy-api.sh`,
  then deploy with `--full`. Until then, the founder (dev-view) can test on the **debug** APK (the sync credits
  them from the client entitlement), or use the dev "free reload" top-up tool.

---

## 2. Founder's standing rules and working style

Style
- **BLUF.** First line is the answer/result/decision needed. Status updates at most 3 short lines. Findings at
  most 6 lines unless asked for depth. One table max, only when numbers are the point. No recaps, no
  restating the founder's words, no "next steps" they did not ask for. Concise, never shallow.
- **One question at a time**, 1-2 lines, never an essay. While background work runs, ask the next question
  from the queue (section 6).
- **No background-task status chatter.** Do not volunteer progress on running agents while discussing
  something else. Report agent results only when they are the answer or need a decision.
- They/them for any person whose pronouns are unknown.
- Dissent is welcome but brief; the founder dislikes padding and being asked what they already decided.

Autonomy
- Do not wait on the founder for setup/ops steps: delegate to Muse or agents and keep going.
- **Ask ONLY for**: (1) making a payment, (2) anything that could raise future spend (paid plan changes, new
  paid services, billing exports, subscriptions), (3) any change to the locked Gemini models.
- **Model lock**: never change a model id, flip a flag that sends real traffic to a different model, or enable
  spend without explicit approval. Report recommendations instead. Every agent must ask every time.

Repo and release rules (also in `AGENTS.md`; do not diverge)
- Prompts live in `prompts/*.md` / `persona.md` files, never inline in code. No hardcoded credentials (secrets
  come from `.env.local` locally, Secret Manager when deployed). Model names only in `config.py`.
- **Commit trailers** on every commit and PR:
  `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01Err4uKEd2mdDWz5ZdoBf2N` (other tools: use the trailers
  your harness gives you; keep the Claude-Session line if you continue that session).
- **Always `git push origin main` immediately after every commit/merge on main** (Codemagic and others read
  GitHub; main has drifted before). Worktree agent branches need no push.
- **Always deploy after merging** (founder, 2026-10-18: "never wait for me to say deploy"): backend via
  `scripts/deploy-all.sh`, then build the APK and `adb install` it. Exception: pre-approved custom-branch
  deploys, and when the founder says to hold. Agents never deploy unless told in their prompt.
- Users see credits, never dollars (dollars only in dev builds / admin).
- **The EIN never appears on the site, in chat, or in this repo.** Never write passwords, API keys, card
  numbers, or phone numbers into docs or commits.
- Versioning: bump `pubspec.yaml` build number on each shipped APK; `versionCode` must never go down.
- `AGENTS.md` "test, commit, log" per-step process applies to `PLAN.md` steps. For ad-hoc founder requests,
  follow the flow above (agent -> merge -> push -> deploy -> install).

---

## 3. Operations runbooks

All commands run from the repo root. Project `ayma-ai`, region `us-central1`.

### Deploy backend and agent (no deploy from a feature branch unless told)
```
bash scripts/deploy-all.sh            # rules+indexes, ayma-api, hosting, ayma-agent (code-only)
bash scripts/deploy-all.sh --full     # also (re)sets env vars + secret mounts on both services
bash scripts/deploy-api.sh [--full]   # ayma-api only (gcloud run deploy --source functions/bootstrap)
bash scripts/deploy-agent.sh --release  # ayma-agent only: builds image via cloudbuild.agent.yaml, then deploys
```
- Always use `--release` for the agent (alias of `--full`). min-instances is **0 by design** (since
  2026-09-19; `scripts/deploy-agent.sh` comment explains); do not "fix" it to 1. Cold start is handled by the
  wake ping; mid-call scale-down by the per-call keep-alive (needs `--timeout 3600` and `AYMA_AGENT_URL`,
  both set by `deploy-agent.sh --release`). Never use a bare `gcloud run deploy ayma-agent` copied from old docs.
- Use `--full` whenever env vars or secrets changed (a missing mounted secret fails the revision).
- Verify:
```
gcloud run services describe ayma-api --region us-central1 --project ayma-ai --format='value(status.url,status.latestReadyRevisionName)'
curl -s https://<ayma-api-url>/health
gcloud run services logs read ayma-agent --region us-central1 --project ayma-ai --limit 50 | grep -i "registered worker"
```
  Agent healthy = a `registered worker` log line after a voice call starts (it scales to zero idle). Zero such
  lines despite successful `/bootstrap` calls = voice broken.

### Rollback
```
gcloud run revisions list --service ayma-api --region us-central1 --project ayma-ai
gcloud run services update-traffic ayma-api --region us-central1 --project ayma-ai --to-revisions <GOOD_REVISION>=100
gcloud run services update-traffic ayma-agent --region us-central1 --project ayma-ai --to-revisions <GOOD_REVISION>=100
```
Flag rollback: `python3 scripts/flags.py rollback --yes` (section 1). Firestore rules: redeploy the previous
`firestore.rules` from git.

### Build and install the Android APK (phone builds)
1. Move `ayma_flutter/android/key.properties` aside (`mv ... key.properties.bak`) so the build is
   debug-signed and installs over the existing debug-signed phone app. Restore it afterwards. Never commit it
   (`*.jks`, `key.properties` are gitignored). Release/store builds use the upload keystore described in
   `docs/ANDROID_DEPLOY.md`; secrets names only: keystore passwords live outside the repo.
2. Build with the RevenueCat Test Store key (Secret Manager `REVENUECAT_TEST_KEY`, never in the repo).
   Preferred: `bash scripts/build-apk.sh --debug`, which reads the key from Secret Manager when the env var is
   unset, refuses to build unless RevenueCat accepts the exact value (build 2208 shipped the key with `https`
   glued on, so every RevenueCat call failed with "Invalid API Key" and the Plan page could not sell), and reads
   the Flutter Sentry DSN (`SENTRY_DSN_FLUTTER`) so phone builds report errors. Manual equivalent (paste the key
   exactly; nothing may follow it):
```
cd ayma_flutter
flutter build apk --debug --dart-define=REVENUECAT_TEST_KEY=<from RevenueCat dashboard> \
  [--dart-define=AYMA_API_BASE_URL=...] [--dart-define=SENTRY_DSN=...]
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```
   Test Store key must never ship in a store build. It must be a `--debug` build: the RevenueCat SDK closes the
   app ("Wrong API Key") when a Test Store key runs in a release/profile build (this broke 2205). The app now
   ignores the test key outside debug and throws at startup if it is the only key. Release builds take the
   production public SDK keys from Codemagic variables (names only): `REVENUECAT_ANDROID_KEY`,
   `REVENUECAT_IOS_KEY` (dart-defines of the same names; codemagic.yaml fails the build if unset).
3. **versionCode must never go down** (bump the `+N` in `pubspec.yaml` first). **Never uninstall** the app on
   the phone (loses its data/login); always `adb install -r`.

### adb wireless pairing (QR method; the founder wants to scan, not type codes)
Device: founder's Pixel 10 Pro Fold. If `adb devices` shows nothing:
1. Generate a QR with python `segno` (no `qrencode`): text `WIFI:T:ADB;S:<name>;P:<password>;;`
   (choose a random name/password), save PNG in the scratchpad, show it to the founder.
2. Founder: Settings > Developer options > Wireless debugging > Pair device with QR code, scan.
3. Poll `adb mdns services` until `<name> _adb-tls-pairing._tcp <ip>:<port>` appears, then
   `adb pair <ip>:<port> <password>` (retry once if it faults).
4. `adb connect <phone LAN IP 10.0.0.x>:<port shown on the Wireless debugging screen>`. The 100.x address shown
   on the phone is not reachable; use the LAN IP.

### Android call notification (Hang Up / Mute mic / Unmute Ayma)
`CallForegroundService.kt` (microphone FGS, `CallStyle`) turns a Hang Up / Mute mic / Unmute Ayma tap into a
`PendingIntent.getService` start, then calls Dart on the cached main engine over the `ayma/call_ui` MethodChannel. Dart
handles it in `CallBackgroundService`, which routes into the one `VoiceSessionController` (`stop()` / `toggleMute()` /
`unmuteAyma()`). "Unmute Ayma" only shows while Ayma is in "shut up" mode (`aymaQuiet`, ARCHITECTURE.md §1.6a). The
channel handler is process-wide, so there must be exactly one `CallBackgroundService` per voice controller.
`MainShellScreen` gets it through `CallBackgroundService.acquire` / `release` (ref-counted), never by constructing
its own: two shells can be mounted at once (a pushed `/` route from the `navigate` command, or a replacement built
before the old one is disposed). In build 2208 each shell had its own service, and the one that disposed cleared the
handler, so taps did nothing (fixed on `fix-call-notification`). To debug: `adb logcat -s CallForegroundService`
logs "no Dart handler" or "no Flutter engine" whenever a tap cannot reach Dart.

### Firestore flags, Cloud Run, billing, secrets
```
python3 scripts/flags.py list                                   # feature flags (all-features-on branch)
gcloud run revisions list --service ayma-agent --region us-central1 --project ayma-ai
bq ls --project_id ayma-ai billing_export                       # tables gcp_billing_export_*
bq query --project_id ayma-ai --use_legacy_sql=false \
 'SELECT service.description svc, ROUND(SUM(cost),2) cost FROM `ayma-ai.billing_export.gcp_billing_export_v1_*`
  WHERE usage_start_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY) GROUP BY svc ORDER BY cost DESC'
gcloud secrets list --project ayma-ai
bash scripts/apply-artifact-cleanup.sh                          # Artifact Registry cleanup policy
```
Secret Manager names (values never in repo): `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `CRON_SECRET`,
`ADMIN_PASSWORD`, `INSTAGRAM_APP_SECRET`, `GOOGLE_IMPORT_CLIENT_SECRET`, `GOOGLE_API_KEY` (agent, Developer-API
voice), `SENTRY_DSN_API`, `SENTRY_DSN_AGENT`, `SENTRY_DSN_FLUTTER` (read at APK build time),
`REVENUECAT_WEBHOOK_SECRET`, `DEV_PANEL_PASSWORD` (ayma-api), `PLAY_REVIEWER_CREDENTIALS`, and — **not yet
created** — `REVENUECAT_SECRET_API_KEY` (RevenueCat REST `sk_...`, used by `POST /billing/sync`; see the Credits
section; until it exists only dev-view/debug test purchases credit via sync). Mounting is wired in
`scripts/deploy-api.sh` / `deploy-agent.sh`; rotation procedure in `docs/deploy.md`. Local dev secrets: gitignored
`.env.local`. The founder keeps off-repo key backups in `~/.ayma-keys/` (not for agents to read or copy).
Cloud Scheduler jobs `ayma-cron-*` call `/cron/*` with `X-Cron-Secret`.

---

## 4. Agent orchestration model

The founder's main session is a **coordinator**: it dispatches, merges, deploys, and answers; it does not do
work inline. (Revoked exceptions: investigation is also delegated.)
- Implementation, investigation, tests: background agents, usually in their own git worktree
  (`isolation: worktree`), branched from `main`. Unrelated asks run in parallel; related asks touching the same
  files go to one agent in sequence.
- Mechanical execution (APK build, `adb install`, running deploy scripts, fixed command sequences):
  **haiku-class agents**. Small single-file code drafts may be drafted by Gemini/DeepSeek MCP tools (text-only,
  cannot run tests or deploy), then applied and verified by a Claude/Codex agent.
- Main thread merges worktree branches, runs/dispatches the deploy+install cycle, pushes `origin main`.
- Tools without sub-agents: do the same work but still keep replies BLUF and follow the rules in section 2.

Prompt template to give every agent:
```
Repo /home/suhailps/workspace/ayma (use a git worktree; branch from main; read AGENTS.md and docs/AGENT_HANDOFF.md first).
Goal: <one outcome>. Success: <test/observable>.
Hard rules: do NOT change any Gemini model id or config.py LOCKED block; do NOT flip any feature flag or env var that
changes model traffic; do NOT enable anything that adds spend; do NOT deploy unless this prompt says to; no secrets
in code/docs/commits; prompts in prompts/*.md; model names only in config.py; no mock DBs.
Commit with trailers: 'Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>' and
'Claude-Session: https://claude.ai/code/session_01Err4uKEd2mdDWz5ZdoBf2N'. Merge to main only if told; if on main, push origin main.
Report in under N lines, answer first.
```

---

## 5. Muse (Astro) and Hark (COO)

Both are web apps with no API; drive them with the **chrome-devtools MCP** (`mcp__chrome-devtools-mcp__*`)
in the persisted browser. Page ids change after a browser restart: call `list_pages` first.

### Muse (Astro, muse.ai) - the researcher / console operator
Used for: research, daily vendor billing collection (posts to `/admin/vendor-spend`), console setup (Play
Console, Apple, Cloudflare, ...), credit-program applications (AWS Activate etc.).

Driving it (known-good recipe; Muse's page was id **7**):
1. `select_page` (pageId 7), then `take_snapshot` **with pageId** to confirm you are in the Muse chat.
2. Element uids go stale quickly. Instead `evaluate_script` to focus the chat `TEXTAREA`
   (`document.querySelector('textarea').focus()`), then `type_text` with `submitKey: "Enter"` to send.
3. Wait (`wait_for` or re-snapshot) and read the reply from a fresh `take_snapshot`.

Rules: Muse tasks are **read-only, no payments, no plan changes** unless the founder explicitly authorised that
task; stop at any payment or plan-change screen and report. Do not paste secrets into Muse. Reviewer/test
credentials go into consoles only as the founder directs.

### Hark Pro - "the COO"
`https://app.hark.com/login`. Chat **only inside Hark's project named "Ayma"**, never other projects or general
chat. Browser-based ops (research, web consoles, even App Store / Play Console tasks).
- Drive via `new_page`/`select_page` -> `take_snapshot` -> `fill` / `click` (no API/MCP exists).
- Login recovery: Google sign-in is blocked in the automation browser. Use phone login: ask the founder for their
  number (not stored in the repo), fill "Mobile number or email address", Continue, founder reads the texted
  code, fill "Verification code", Continue. Do not accept terms or create accounts without the founder's
  approval each time.
- Rules: never paste secrets/keys/credentials into Hark chat (the founder enters console credentials in the
  session themself); Hark must never make payments; WhatsApp Web is read-only unless told otherwise.

### Queueing and relaying
Tasks are written as self-contained prompts, sent to Muse/Hark, and results are relayed to the founder only when
they are the answer or need a decision. Pending Muse work is listed in section 6.

Task prompt style that worked: state the goal in one line; list numbered concrete steps with exact URLs/menus;
say "read-only, no payments, no plan changes; stop and tell me if you hit one"; say what to return (exact
fields / a table / "post to POST /admin/vendor-spend with fields ..."); never include secrets.

---

## 6. State snapshot (2026-10-25) and open work

Branches (all local, none merged to `main` except where noted; `main` = `c1bc9d3` Play policy fixes):
| Branch | Contents |
|---|---|
| `livekit-inference` | Gemini JSON/chat/vision/voice via LiveKit Inference behind flags, provider-tagged spend. Defaults stay on Google. Do not merge before the founder has tested. |
| `maps-grounding` | Vertex `google_maps` tool in chat behind `GEMINI_MAPS_GROUNDING` (default off). |
| `deepdive-public-profiles` | Flagged public-profile photo discovery in deep dive (default off). |
| `deploy-candidate` | livekit-inference + maps-grounding + Sentry wiring merged. |
| `all-features-on` | deploy-candidate + deepdive; single `config/feature_flags` doc, all defaults ON, `llm_fallback_to_google` OFF, Vertex AI Search source, livekit-agents 1.8.9; since then biometric consent, Plan page, Developer panel, app registry, voice hot swap, voice-start fix. **Deployed from here** (waves in `docs/TODO_QUEUE.md`). |
| `fix-inference-voice-context` | all-features-on + fix pinning Google voice `tool_behavior=BLOCKING` / voice context fix. **Decision: deploy cloud + phone from this branch (not main) so the founder can retest voice.** |

Deployed: `main`-based `ayma-api` / `ayma-agent` unless the voice-context fix deploy has since run; check
`gcloud run services describe` and the latest revision's image/commit before assuming. The live
`config/feature_flags` doc did not exist yet at last check (code defaults apply).

Pending Muse tasks: put reviewer creds into Play Console App access; Apple status + Small Business Program;
Mercury card billing; Cloudflare `/s/*` routing; credits research; scheduled-tasks question.

Open decisions / blockers: LiveKit credits covering Gemini unconfirmed (ask LiveKit in writing); Highsfield credits
exhausted, blocking the approved 30 s cinematic Ayma ad (plan saved in the founder's notes: kling3_0 two acts +
Maeve VO + code-rendered end card from `ayma_flutter/tool/render_ayma_ad_test.dart`; fire only on founder's go);
referral equity program (`docs/referral-equity-program.md`; SJSU pilot, options via advisor agreements with
milestone vesting, never raw shares per referral); credits calibration F1/F2.

Founder question queue (ask ONE at a time, top first, drop when answered):
0. As soon as the voice-context fix is deployed and the APK installed, ask the founder to retest voice, then
   ask test-related questions first.
1. (closed) Prices $9.99 / $19.99 / $99.99 are agreed; do not re-ask.
2. Production reviewer account for Play review: OK to create?
3. Play declarations: confirm the app is strictly 18+ (content rating, data safety, app access).
4. Referral equity: draft ambassador agreement outline + attorney questions?
5. Which 3 vendors make 27 (catalog has 24)?
6. Move the daily Muse vendor collection to Cloud Scheduler (small paid service)?
7. AWS Activate application: review and submit?
8. Founder to-dos: assetlinks SHA-256, IP assignment to the LLC, Cloud Identity, back up
   `~/.ayma-keys/`, Play identity/phone verification. (Apple Team ID: have Muse read it from the Apple account.)

## Instagram / Facebook are V2 (founder decision)

All Instagram and Facebook integration (sign-in and photo import) is deferred to V2, so there is no Facebook App ID to-do for V1. Why: Meta's Instagram login API supports professional (business/creator) accounts only, and Facebook Login needs a Meta app plus app review. The code (`instagram.py`, `instagram_service.dart`, `instagram_screen.dart`) is intact but unreachable behind the `meta_integrations` feature flag (default OFF, see `docs/FEATURE_FLAGS.md`): the app hides the Connect Instagram row, route and the Instagram Story share option, and `/instagram/*` returns 404 "not available". V1 privacy/terms text does not mention Instagram/Facebook data collection.

## Default delegation

Delegate everything delegable: Muse for browser/console/research/billing/applications, Gemini (gemini-mcp, deepseek, codex) for code drafts and analysis, background/worktree Claude agents for app code, builds, deploys and installs. Run all work as parallel agents; the main thread never blocks. See AGENTS.md "Default delegation".
