# Ayma work queue (kept in the repo so any agent can pick it up)

Last updated: 2026-10-26. Update this file whenever an item changes; commit and push to main.
Rules for working with the founder: see AGENTS.md "Operating handbook" and docs/AGENT_HANDOFF.md.
Ask the founder ONE short question at a time. While a question is pending, do not send agent status; hold results here.

## Integration 2216 (meta-hackathon, 2026-10-26) — live queue (single source of truth)

**DONE tonight (merged into `meta-hackathon`, built APK 2216, NOT deployed, NOT pushed):**
- DM coach — `dm-coach-backend` + `dm-coach-flutter`: "Ayma in your DMs" assist on Muse (`POST /dm/assist`, chips + coaching tip); replaces the old `GET /dm/{thread}/icebreakers`.
- Intro feature tour — `intro-feature-tour`: first-launch `/tour`.
- Feedback catcher — `feedback-catcher`: in-chat `submit_feedback` card → `POST /feedback/submit`; dev-gated `GET/POST /admin/feedback` + `/admin/feedback/media`; unified `feedback` collection; Settings form repointed; retires `POST /product-feedback`.
- Ayma MCP — `ayma-mcp`: `/mcp` bring-your-own-agent behind `mcp_server` flag **default OFF (kept off)**; OAuth device grant + opaque Firestore-validated tokens, no new secret.
- Fail-visible "Show AI notes" toggle fix: the dev_panel toggle now surfaces a clear error and keeps the switch on the true state when the `/dev/flags` write doesn't take (was a silent false-success).
- Version bump `1.30.0+2216`; dependency pin `sse-starlette==3.0.3` (so `mcp==2.3.0` coexists with `fastapi==0.115.6`). Tests green (flutter 1072 incl. layout matrix; backend 2433, bar the known `test_vendor_spend` date-flake).

## UI batch 2228 (meta-hackathon, 2026-10-28) — DONE
- **Retired the `dev_panel` flag end-to-end.** Per founder decision, dev-facing AI annotations (fact tag / confidence) now render ONLY inside the password-gated, dev-only **Ayma's notes** screen (`story_ai_notes`), never in the normal UI for anyone. Removed the "Show AI notes" toggle, the `DevPanelFlag` client plumbing + `app_config/dev_panel` listener, `POST`/`GET /dev/flags`, the server flag definition/seed/mirror, and the now-dead tests. The Developer-panel unlock (`POST /dev/verify`, `DEV_PANEL_PASSWORD`) is unchanged.
- **Inline "Turn on AI Avatar" button** (`dateSimEnableAvatarButton`) on the date-sim setup screen: when the user's own avatar is off, a one-tap button calls `setAiAvatar(true)` in-place (no trip to Settings); the profile stream clears the gate on success, write errors shown inline.
- **Low-context warning** (`dateSimLowContextWarning`) before a sim, from `GET /date-sim/estimate?other_uid=`'s `readiness` block; uses the server `message` when present. Informs, does not block.
- Version `1.30.0+2228`. Tests: flutter 1135 (incl. layout matrix) green; backend green bar the known `test_vendor_spend` date-flake.

## Notification read-sync on tap (meta-hackathon, 2026-10-28) — DONE [[todo-notif-read-sync-on-tap]]
- Founder bug: tapping an OS notification (Android or iOS) opened the app to the item but left the in-app notification + bell badge ("1") unread. Now the tap marks the matching in-app notification read and resyncs the bell / OS app-icon badge, platform-agnostic, for both cold-start (`getInitialMessage`) and warm (`onMessageOpenedApp`) paths.
- Push payloads carry the centre doc id as `notif_id` (`notifications_dispatch`); client `NotificationService.markReadForTap` marks that exact doc (legacy `deep_link`-only pushes fall back to the most-recent matching unread, no over-clear); DMs (no centre doc) clear nothing in the bell. OS app-icon badge synced over a new `ayma/badge` channel (`AppBadge`): iOS `applicationIconBadgeNumber`; Android launcher dot follows active notifications.
- **No APK / no versionCode bump** (stays 2229; consolidation build/deploy follows). Tests: `push_service_test.dart` +2, new `notification_tap_read_test.dart` +5, backend `test_notifications_dispatch.py` updated — Flutter + layout matrix green, backend notification suites green. Docs: ARCHITECTURE §7.6, HACKATHON_STATUS. Deploy (later): ayma-api so pushes carry `notif_id`; client ships in next APK.

## Integration 2217 (meta-hackathon, 2026-10-26) — final pass

**DONE (merged into `meta-hackathon` on top of 2216, built APK 2217, NOT deployed, NOT pushed):**
- `voice-notif-gating` — voice-call notification + central orb glow now gate on `VoiceSessionController.isListening` (phase==live); the mic foreground service / call notification is delayed until Ayma is actually listening (not at connecting/waking).
- `fix-launcher-icon` — opaque full-bleed pink round launcher icon PNGs (fixes the black box in Android search); `tool/build_icon_variants.py` updated.
- `voice-engine-switcher` — Dev Brain/STT/TTS + Cascade/Realtime per-user voice picker sourced from the LiveKit Inference catalog (`GET /voice/engines` + `POST /voice/preference`, `voice_catalog.py`); agent reads the per-user pref at the next call; OpenAI Realtime exposed only behind `VOICE_OPENAI_REALTIME` + a mounted `OPENAI_API_KEY`. Merged with the main-voice Meta cascade: default stays Meta cascade when `LLM_PROVIDER_VOICE_MAIN=meta` and Gemini Live otherwise; per-user pref overrides per user only.
- `fix-splash-timeout` — startup token/bootstrap deadlines + auto-retry with backoff + branded Retry UI; `connectivity_plus` promoted to a direct dependency; splash never signs out a signed-in user on a network blip.
- Version bump `1.30.0+2217`.

**Deploy coupling for 2217:** deploy backend (ayma-api + ayma-agent) and install the 2217 APK together — the app uses new endpoints. Both services change: ayma-api gains `/voice/engines` + `/voice/preference` (needs the full image rebuild already carrying mcp/sse-starlette); ayma-agent needs the voice-engine-switcher `agent.py`/`voice_catalog.py`/`requirements-agent.txt` (`livekit-plugins-openai`). `ayma-api` is temporarily `min-instances=1` for testing; revert to `0` when idle, but set `1` again before the **Nov 4** demo.

## Qloo Agentic Hackathon (meta-hackathon, 2026-10-27) — deadline Fri Oct 30, 8:45 PM PT

- Taste match powered by Qloo built (`docs/QLOO_TASTE.md`): `POST /taste/pair`, public judge page `GET /taste/demo`, Flutter "Taste match" card on the Date Sim result.
- Qloo is LIVE on ayma-api (`ayma-api-00221-wjd`, 2026-10-27): `QLOO_API_KEY` mounted, `/taste/demo/pair` serves `source: "qloo"`.
- Astro: extract the public Qloo demo repo (files listed in `docs/QLOO_TASTE.md`), add licence, submit on Devpost with the `/taste/demo` URL.

**DONE (meta-hackathon, 2026-10-28) — Qloo taste as a labeled section in the match report [[todo-qloo-taste-in-match-report]]:** founder decision ("have the taste definitely as a section in the match score between two users in the report"). The existing taste engine now surfaces inside the match-compatibility report, reusing the same `/taste/pair` logic (no duplicated Qloo calls). Backend: `taste_match.report_section(db, viewer_uid, other_uid)` (non-raising) is embedded by `GET /match/{match_id}` under a `taste` key — full payload with `status: "ok"`, a `{"status":"no_taste","message":…}` empty-state marker, or `null` on failure (report never errors). Flutter: shared card moved `features/date_sim/taste_*.dart` → `lib/widgets/`, reused by both the date-sim result and the match report; `MatchReport.taste` + `match_report_screen.dart` renders the **"Taste match · powered by Qloo"** section (`overflow_guards`, layout matrix green). PUBLIC profile data only, both people — no private/cross-user private reads. Tests: backend `test_taste_match.py` 16 green, Flutter `taste_match_report_section_test.dart` 5 green. CODE+TESTS+PUSH only (no APK/deploy/versionCode bump — final integration does that).
- **DONE (meta-hackathon, 2026-10-28) — collect taste in the questionnaire [[todo-onboarding-taste-questions]]:** founder ("this should be part of our questionnaire"). Three `page_type: "taste"` nodes are now in the question tree (`question_tree.json` v3, branch `all`: `taste_music` core, `taste_film` / `taste_food` deep), asked by Ayma in the normal flow. On any taste answer `skills/questionnaire.py::_sync_taste_page` composes the user's PUBLIC `wiki_pages/taste` page in the `Music: … / Film: … / Food: …` shape `parse_taste` reads (written straight to `ai_body`, public by design like the seeded profiles). So a pair who both answered get a real taste score instead of the `no_taste` empty state — previously only the 4 seeded demo profiles + anyone who hand-added a Taste page had taste data. No Flutter change (complete-profile screen is server-driven); backend-only deploy. Tests: `test_taste_match.py` end-to-end (two fresh users → real pairing), `test_questionnaire_skill.py` (compose + parse, visibility preserved). Docs: ARCHITECTURE §19 + diagram, QLOO_TASTE.md § "Where the Taste page comes from".

**IN PROGRESS / FLAGGED (meta-hackathon, 2026-10-28) — move the voice agent to LiveKit Cloud [[todo-v2-move-agent-to-livekit-cloud]]:** `ayma-agent` can now run on **Cloud Run (default)** OR **LiveKit Cloud Agents**, chosen per user by the `voice_agent_cloud` preference (`cloudrun` default | `livekit`), default OFF so production voice is unchanged. `/bootstrap` reads the pref and routes the room by **explicit agent dispatch** to `ayma-lk` when `livekit` (`RoomConfiguration`/`RoomAgentDispatch`); the Cloud Run worker keeps **automatic** dispatch and declines `livekit`-flagged rooms via a `request_fnc` guard (fail-open) so the two never contend. Same `agent.py`, switched by `AGENT_RUNTIME`; the LiveKit worker loads Firestore from a least-privilege SA key (`LK_AGENT_FIRESTORE_SA` in Secret Manager — a durable credential; SA `lk-agent-firestore@ayma-ai`, role `datastore.user`). Dev toggle: Developer screen → "Voice agent cloud" (`GET/POST /voice/agent-cloud`). **LiveKit Cloud deploy SUCCEEDED** 2026-10-28: agent `CA_bJMNunTLpVqk` (region us-east, project `aimma-wt34nu3l`), worker **registered as `ayma-lk`**, status Running. Artifacts: `Dockerfile.livekit`, `livekit.toml`, `scripts/deploy-agent-livekit.sh`. Runbook + flip-the-default plan: `docs/LIVEKIT_AGENT_MIGRATION.md`. Backend-only deploy (ayma-api for the endpoint/dispatch; Cloud Run ayma-agent redeploy for the guard before anyone opts in). No APK/versionCode change (dev toggle ships in appearance-fix APK 2230). Tests: `test_voice_agent_cloud.py` (flag resolution, endpoint, explicit-dispatch routing), bootstrap/parity green, layout matrix green.

**DONE (meta-hackathon, 2026-10-28) — story edit direct, no passage popup [[todo-story-edit-direct-no-popup]]:** `edit_story_entry` / `remove_story_entry` (`skills/story_manage.py`) are now wired into the VOICE tool set too (`make_livekit_tools`), not just text, so Ayma can change/soft-remove a section of the user's own story on a call. A "change / fix / reword / remove / delete … my story" intent routes to the direct tool *before* `open_screen` can navigate (new `story_edit_actions` in `app_registry.json` + `find_story_edit_action`), so she edits in place instead of navigating into the Story editor's "Ask Ayma" passage popup (founder bug: "it shouldn't open that pop-up, it should just update it directly"). Persona + `prompts/voice_tool_use.md` + `open_screen` description strengthened. Own-story-only (bound on `(db, uid)`). Backend + agent change; needs ayma-api + ayma-agent deploy together, no APK change.

## 0. PRIORITY (founder, 2026-10-25): app-side testing and changes come first. Backend/vendor/admin work waits behind them.

## 1. Pending founder question (one at a time, top first)
1. AI-lab startup credits (Anthropic, OpenAI...): wait for Muse report, then decide.
2. Play Console fixes still open: Data safety, content rating (set to 18+ only), Advertising ID declaration, Child safety standards, privacy policy URL, deletion URL https://justabot.info/delete-account.html.
3. Founder-only items: assetlinks SHA-256 (SHARE_ASSETLINKS_SHA256), IP assignment to the LLC, Cloud Identity, back up ~/.ayma-keys/, Play identity/phone verification, Apple Team ID (have Muse read it).
4. Parked to-do (do only when told): referral equity agreement outline + attorney questions (docs/referral-equity-program.md).
Closed: prices $9.99/$19.99/$99.99 agreed; vendor count is 24; 18+ mandatory; reviewer account approved; delete test accounts done; stale vendor data is banner only.

## 2. Deploy state (latest known, 2026-10-26)
- **Live (wave 9, built from `all-features-on` @ efff004, merged to main):** ayma-api-00205-swq (prev 00204-xtb), ayma-agent-00110-q2h (prev 00109-v6r), Hosting redeployed (get.html smart link + public pages), Firestore rules/indexes unchanged (no deploy). Included: muted orb, match/plan no-hallucination, share smartlink + logo, chat-expand v2, test-purchase credits (/billing/sync; REVENUECAT_SECRET_API_KEY not set, endpoint degrades by design), report-card photo remove/swap, push notifications, rename Settings, inline photo carousel, dev-panel password gate, per-sentence suggestions + review notification, Connecting vs Listening voice state, photo eligibility grouping. Tests: backend 2522 passed, 2 known order-dependent test_backfill_ops failures; flutter analyze clean; only known chat_scroll_to_bottom failure; layout matrix green. /health 200; wrong-password POST /dev/flags 403; reviewer /bootstrap 200 with livekit; agent Ready, keepalive on 8080, worker registered; all env vars and secrets kept (incl. DEV_PANEL_PASSWORD, SENTRY_DSN). APK debug versionCode 2212 installed with `adb install -r` (replaced 2211); no Wrong API Key, fatal exception or layout error; process alive.
- Rollback wave 9: `gcloud run services update-traffic ayma-api --region us-central1 --project ayma-ai --to-revisions ayma-api-00204-xtb=100`; `gcloud run services update-traffic ayma-agent --region us-central1 --project ayma-ai --to-revisions ayma-agent-00109-v6r=100`.
- **Live (wave 6, built from `all-features-on` @ 9cd5853, not main):** ayma-api-00202-br5 (prev 00201-9qm), ayma-agent-00107-ls5 (prev 00106-2qj), Hosting redeployed, Firestore rules unchanged. Includes share-report-card, branded toasts, chat expand transition, call-notification fix, plan-upgrade fix, default accent, suggested-updates fix, credits period filter, web-research de-dupe + link validation, no duplicate recs in report, deep-dive logging, fix-match-chat-and-language. NOT included: layout-robustness (a9037ee0538e701a1) had not merged within the 25-minute wait. Tests: backend 2212 passed; flutter analyze clean; only known chat_scroll_to_bottom failure. /health 200; wrong-password POST /dev/flags 403; reviewer /bootstrap 200 with livekit; all API env vars and secrets kept.
- APK wave 6: debug versionCode 2209 installed with `adb install -r` (replaced 2208); no RevenueCat error or fatal exception in logcat, process alive.
- Rollback wave 6 (backend and APK together): `gcloud run services update-traffic ayma-api --region us-central1 --project ayma-ai --to-revisions ayma-api-00201-9qm=100`; `gcloud run services update-traffic ayma-agent --region us-central1 --project ayma-ai --to-revisions ayma-agent-00106-2qj=100`; reinstall the 2208 APK built from all-features-on @ 5d7984b (a build with a lower versionCode needs `adb install -r -d`).
- **Previous (wave 5, built from `all-features-on` @ 5d7984b = 8c595ed plus the 2208 version bump, not main):** ayma-api-00201-9qm (prev 00200-r8j), ayma-agent-00106-2qj (prev 00105-2dp), Hosting redeployed. Firestore rules unchanged (no deploy). Includes screen-context + ui_action, review-fixes (c93d68e), hygiene pass, voice-start and shutdown fixes. Tests: backend 2164 passed; flutter analyze clean; only known chat_scroll_to_bottom failure. /health 200; wrong-password POST /dev/flags 403. Reviewer (consent not bumped): /bootstrap 200 with livekit, /chat/history 200.
- **Not yet deployed:** layout-robustness (when it merges to `all-features-on`).
- APK: debug versionCode 2208 installed on the phone with `adb install -r` (replaced 2205; no 'Wrong API Key', no crash). Built with the RevenueCat test key reused from the previous debug build (no Secret Manager entry exists for it).
- Reviewer consent is seeded at 2026-10-25.2 (functions/bootstrap/scripts/seed_biometric_consent.py). Founder and Dillu are not seeded: they re-accept in the app. The review-fixes legal text change did NOT bump the consent version (a bump forces everyone to re-consent); decide with the attorney review whether it should.
- Rollback (backend and APK together; app-control registry paths): `gcloud run services update-traffic ayma-api --region us-central1 --project ayma-ai --to-revisions ayma-api-00200-r8j=100`; ayma-agent: `--to-revisions ayma-agent-00105-2dp=100`; reinstall the previous APK build (versionCode 2207 was never installed; 2205 is the last wave-3 build, rebuild it from all-features-on @ 684470b if needed).

## 3. Open items (from the MR/hygiene review, 2026-10-25)
- Attorney review of the Privacy Policy and Terms is still needed, including the new LiveKit Inference (AI gateway: text, images/photos, audio, with Google Gemini as underlying model provider) disclosure and a LiveKit data-processing agreement.
- `deepdive_blocked_regions` now matches cities/states/countries/codes from functions/bootstrap/region_data.json (Illinois, Texas, Washington, EU 27). Keep that mapping maintained; an empty or unrecognised location is allowed (consent required) and logged. Defaults unchanged (`illinois,texas,eu`).
- Biometric consent: the endpoint gate cache is 30 s; every face job and web-photo match re-reads the user doc (`has_consent_fresh`).
- /dev/flags: lockouts are per account (5) and per client address (10, hashed) for 15 minutes plus a global ceiling of 200 misses per window.
- Known test noise: Flutter `chat_scroll_to_bottom` "message arrives mid-drag" fails; two `test_backfill_ops` tests are order-dependent (pass alone).
- Muse (Astro) queue, read the reports when they arrive: LiveKit credits wording + Billing page; Firebase startup program; credits survey; AI-lab credits; Apple account status + Small Business Program; move all vendor billing to the Mercury card; Cloudflare routing of justabot.info/s/* and assetlinks to ayma-api; reviewer login into Play App access; Muse scheduled-tasks question; AWS account + Activate credits application (Bedrock Claude). LiveKit startups email sent to startups@livekit.com; no reply yet.
- After the next deploy, ask the founder to retest voice on LiveKit (all-features-on defaults to inference for everyone).
- Feedback catcher (branch `feedback-catcher`, merged into `meta-hackathon`): in-chat `submit_feedback` tool → editable confirmation card (nothing filed until Send) → `POST /feedback/submit` → unified `feedback` collection (`source: chat_card`). The Settings "Send feedback" form now routes to the SAME endpoint (`source: settings_form`); the old `/product-feedback` endpoint/collection write path is removed. Triage in-app at Developer → Feedback (`GET /admin/feedback`, dev-allowlist gated). Screenshots stored as access-controlled `uploads/{uid}/` paths, signed only in the admin view. No new feature flag. Needs on-device verification of the chat card + admin view; pre-existing `test_vendor_spend` staleness failure is unrelated.
- **MCP server (branch `ayma-mcp`, merged into `meta-hackathon` 2026-10-26, NOT deployed):** bring-your-own-agent interface at `/mcp` (OAuth 2.1 device grant + MCP streamable-HTTP tools for profile/matches/DMs/persona), behind the `mcp_server` feature flag **default OFF (keep off)**. Zero Ayma LLM spend by design. Flutter "Connect an agent" approval screen added (Profile → Ayma’s settings). Spec + threat model: `docs/MCP_SERVER.md`. Needs **no new secret** (opaque Firestore-validated tokens). Backend MCP tests + layout matrix green. To enable later: `scripts/flags.py set mcp_server=true --yes`.

## 3b. WAVE 1 DEPLOYED (2026-10-25, from `all-features-on` @ 5019528, not main)
- Merged: fix-prefs-theme-explore, fix-inference-voice-context, admin-stale-alert, restore-color-gradient (conflicts in app_command_service/app_control resolved to the restore-color-gradient accent tool; fix-prefs duplicate tests updated). Not included: plan-page-design.
- Live: ayma-api-00195-985 (prev 00194-7ft), ayma-agent-00101-6qf (prev 00100-gj5), Hosting (delete-account, child-safety, privacy), Firestore rules (already identical, no change). /health 200, justabot.info/delete-account.html 200. No flags/models/config/llm_routing touched.
- APK debug versionCode 2203 installed on the phone with `adb install -r`.
- Rollback: `gcloud run services update-traffic ayma-api --region us-central1 --project ayma-ai --to-revisions ayma-api-00194-7ft=100`; same for ayma-agent with ayma-agent-00100-gj5.
- Still to do: plan-page-design merge + wave 2 deploy.

## 3c. WAVE 2 DEPLOYED (2026-10-25, from `all-features-on` @ 4f37920, not main)
- Merged plan-page-design (unified Plan page, hidden Developer panel behind flag dev_panel, POST /dev/flags). Conflicts in scripts/flags.py + seed resolved keeping meta_integrations and dev_panel mirrors. biometric-consent NOT merged. Tests: backend 1964 passed; flutter analyze clean; only known chat_scroll_to_bottom failure.
- Live: ayma-api-00197-g4m (DEV_PANEL_PASSWORD mounted, accessor granted to the compute SA; prev 00195-985), ayma-agent-00102-vbs (prev 00101-6qf), Hosting. Firestore rules unchanged (no deploy). /health 200, POST /dev/flags wrong password 403.
- APK debug versionCode 2204 installed on the phone (`adb install -r`). Branch tip now 1ac0f9d (adds the version bump plus others' any-accent-colour and llm_routing commits, not yet deployed).
- Rollback: `gcloud run services update-traffic ayma-api --region us-central1 --project ayma-ai --to-revisions ayma-api-00195-985=100`; ayma-agent: `--to-revisions ayma-agent-00101-6qf=100`.

## 3d. WAVE 3 DEPLOYED (2026-10-25, from `all-features-on` @ 684470b, not main)
- Merged on the branch: biometric-consent (mandatory face-matching consent gate), any-colour accent, routing-coverage (all LLM call sites via llm_routing), voice-hot-swap (8fe400d). Fix in this wave: agent image pin `openai>=3.19,<4` (old `openai==2.46.0` conflicted with livekit-agents 1.8.9 and failed the image build).
- Live: ayma-api-00198-7rq (prev 00197-g4m, DEV_PANEL_PASSWORD still mounted), ayma-agent-00103-xqb (prev 00102-vbs), Hosting. Firestore rules unchanged. Tests: backend 2001 passed; flutter analyze clean; only known chat_scroll_to_bottom failure.
- Play reviewer consent seeded (scripts/seed_biometric_consent.py, region US) before the API deploy: reviewer /bootstrap 200. Throwaway non-consented user got 403 biometric_consent_required (user deleted). Founder and Dillu NOT seeded: they see the in-app consent screen.
- /health 200; POST /dev/flags wrong password 403. APK debug versionCode 2205 installed (`adb install -r`).
- Rollback: `gcloud run services update-traffic ayma-api --region us-central1 --project ayma-ai --to-revisions ayma-api-00197-g4m=100`; ayma-agent: `--to-revisions ayma-agent-00102-vbs=100`.

## 3e. WAVE 4 DEPLOYED (2026-10-25, from `all-features-on` @ ac7b7d4, not main)
- Included: app-control registry (backend + APK together), legal-bold-clauses (consent/terms version 2026-10-25.2), voice-start new-room + crash-report fix, RevenueCat debug-build fix, agent shutdown/memory-flush fix, test fix (`openai>=3.19,<4` asserted for the worker images; versionCode 2207).
- Live: ayma-api-00200-r8j (prev 00198-7rq), ayma-agent-00105-2dp (prev 00103-xqb), Hosting. Firestore rules unchanged. Reviewer consent re-seeded at 2026-10-25.2 (script in functions/bootstrap/scripts) before the deploy: /bootstrap 200 with livekit. Founder and Dillu NOT seeded (they re-accept in app). /health 200; wrong-password POST /dev/flags 403. Tests: backend 2038 passed; flutter analyze clean; only known chat_scroll_to_bottom failure.
- APK debug versionCode 2207 built via scripts/build-apk.sh --debug; install PENDING (phone unreachable, "No route to host"; founder re-enables wireless debugging, then `adb connect 10.0.0.203:<port>` and `adb install -r`).
- Rollback: `gcloud run services update-traffic ayma-api --region us-central1 --project ayma-ai --to-revisions ayma-api-00198-7rq=100`; ayma-agent: `--to-revisions ayma-agent-00103-xqb=100`. Backend and APK must be rolled back together (registry paths).

## 3f. credits-period-filter (merged to `all-features-on`, NOT deployed)
- Plan page credit history: period chips (Since last credit update default, 7d, 30d, All time), server aggregation via `GET /usage?period=`, friendly feature labels from one server map. Fixes the "685 spent" vs ~19,000 cr rows mismatch (header was the pool-balance `credits.used`, rows were lifetime tokens/1000; both now come from the same per-period cost aggregate). Needs backend deploy plus APK together.

## 3g. WAVE 7 (2026-10-25, from `all-features-on` @ b477366)
- No backend/API/hosting/rules changes detected (diff check: functions, scripts, public, firestore.rules, firebase.json all unchanged). Backend deploy skipped.
- Flutter layout-robustness fixes + overflow guards deployed via APK only: no backend changes, no deploy needed, only app-side.
- APK debug versionCode 2209 built via scripts/build-apk.sh --debug and installed via adb (Wi-Fi to 10.0.0.203:36693). Logcat check: no RevenueCat errors, no '!!!!!!!! AYMA LAYOUT ERROR' lines, process ready.
- Tests: flutter analyze clean; flutter test passed (background task exit 0); only known pre-existing chat_scroll_to_bottom failure.
- Installed successfully. Ready for manual test on Fold (layout overflows, draft features).

## 3h. WAVE 8 DEPLOYED (2026-10-25, from `all-features-on` @ f8deba7 (includes agent keep-alive abbbb4d), not main)
- Included: fix-research-stuck (deep_dive_runs), muted-state-ux, layout-robustness, fix-send-message-flow (one-yes DM send), fix-voice-swap-silent (swap watchdog), credits-period-filter, version bump 2210. Nothing missing.
- Live: ayma-api-00204-xtb (prev 00202-br5; env vars and secrets unchanged, DEV_PANEL_PASSWORD and SENTRY_DSN kept), ayma-agent-00109-v6r (prev 00107-ls5; keepalive server on 8080, health on 8081, startup probe passed, --timeout 3600), Hosting. Firestore rules unchanged (deep_dive_runs is backend-only, default deny). /health 200, wrong-password POST /dev/flags 403, reviewer /bootstrap 200 with livekit. Tests: backend 2431 passed (2 known order-dependent test_backfill_ops pass alone); flutter analyze clean; only known chat_scroll_to_bottom failure.
- APK debug versionCode 2211 installed (`adb install -r`, prev 2209); logcat clean (no RevenueCat error, fatal exception or layout error), process alive.
- Rollback (backend and APK together): `gcloud run services update-traffic ayma-api --region us-central1 --project ayma-ai --to-revisions ayma-api-00202-br5=100`; ayma-agent: `--to-revisions ayma-agent-00107-ls5=100`; APK: build 34c1267 (`scripts/build-apk.sh --debug`) and `adb install -r -d`.

## 4. Next deploy plan (STANDING RULE: always deploy every requested change as soon as its branch is ready, in rounds; never ask the founder whether to deploy) (founder approved: deploy everywhere from the custom branch, not main)
1. Merge the finished branches into `all-features-on` (fix-prefs-theme-explore, fix-inference-voice-context, admin-stale-alert, plan-page-design, restore-color-gradient, maps-grounding/deepdive already in).
2. Deploy API and agent from that branch (`deploy-api.sh`, `deploy-agent.sh --release`), Firestore rules, Firebase Hosting (for the new public pages), mount DEV_PANEL_PASSWORD on ayma-api.
3. Build the APK (key.properties moved aside, REVENUECAT_TEST_KEY dart-define, versionCode above 2202) and `adb install -r` (QR pairing, see AGENT_HANDOFF.md). Currently installed: 2202.
4. Ask the founder to retest voice on LiveKit (voice routed for suhailps@gmail.com via config/llm_routing; all-features-on defaults to inference for everyone).
5. Then answer the founder's earlier questions one at a time.

## 5. Facts to keep straight
- Only three real accounts remain: founder (iWhWjiWhEpU7iyu9B9vy7GlT0PD2), Dillu (Apple), Play reviewer (play.reviewer@ayma-ai.web.app; credentials in Secret Manager PLAY_REVIEWER_CREDENTIALS).
- Test deploy live now: ayma-api-00200-r8j, ayma-agent-00105-2dp from wave 4. Rollback revisions: ayma-api-00198-7rq, ayma-agent-00103-xqb.
- Model lock: never change a Gemini model id or flip a flag that sends traffic to a new model without the founder's explicit approval.
- Deploy wave 7 (after wave 6 lands): layout-robustness + overflow guards, APK-only, no backend changes.

## 6. V2 backlog (founder-declared; do NOT build for V1)
- Instagram and Facebook integrations (sign-in and photo import), hidden behind flag `meta_integrations` (off). Reasons: Meta's Instagram login API supports professional accounts only; Facebook Login needs a Meta app plus review.
- **Ayma plug-in / MCP skill ("bring your own agent")**: let every user connect their own AI agent (ChatGPT, Claude, Gemini, etc.) to Ayma. The user chats with their agent to build their story and profile details inside Ayma, and the same agent can search for matches and chat with other users' agents through Ayma. Open design points for later: auth and scopes (OAuth/MCP server), per-user consent and data-sharing controls, rate limits and cost, moderation and safety of agent-to-agent chat, 18+ and biometric-consent gates still apply, disclosure when a conversation is agent-driven.

## Tested by Suhail on 2026-10-26 (build 2211) — CLOSED, do not re-offer
- Voice call stays alive through the call and back-to-back calls (keepalive). PASS.
- Call notification Hang Up and Mute (mic). PASS.
- Send a message in one confirmation + opens the DM chat. PASS.
- Plan page combined + credits period filter (see purchase note below).

## Found during testing 2026-10-26 (fixes in flight on all-features-on)
- Muted orb: must NOT unmute on tap; keep orb colour, show muted badge only (agent re-running). RETEST.
- Ayma hallucinated 'great match on paper' with zero data — grounding fix in progress.
- Test/fake purchase does not add credits (no webhook on Test Store) — /billing/sync fix in progress; may need REVENUECAT_SECRET_API_KEY.

## Pre-launch founder-only items (from Muse, 2026-10-26) — ask one at a time, testing stays top priority
- Enter one-time passwords in the Muse app secure card: Apple ID, Mercury, AWS Builder ID (founder@justabot.info), Codemagic/GitHub. (Muse never stores passwords; AWS/Apple windows die ~1h waiting.)
- Keep phone charged (password cards + 2FA land there).
- Play Console (founder only): upload ID for identity verification (BLOCKS review + phone verification); answer content-rating Qs (a) precise location shared with other users? (c) block users/UGC? [(b) purchases = Yes]; add store listing assets (developer icon, header image, promo text).
- Play account is Personal, not Justabot LLC org; "change to organization" greyed out — decide whether to pursue org account.
- Production gate: closed test, 12+ testers, 14 days (currently 0 testers).
- Decision: send the LiveKit startups email draft (credits appear to be working — may be moot)?
- Decision: have Muse check whether the 1-yr-free Scale (startup program) should cover the $112.84 Scale subscription charge.
- Good/closed: IP assignment + Operating Agreement signed (Oct 20). LiveKit credits ARE absorbing Gemini (Inference/Realtime lines $0.00).

## POSITIONING WORDING — FOUNDER DECISION NEEDED (added 2026-10-27; must be resolved before the Nov 3 submission freeze)
- Conflict: the committed docs carry two opposing lines about Agent Dates:
  - (a) Founder framing (demo script / write-up): the sim decides who's worth showing up for — "your digital self dates first; you meet when it matters."
  - (b) Guardrail Astro added without founder sign-off (`docs/POSITIONING.md`): "sims inform, never decide" + privacy phrasing "built from what its person shares."
- Founder picks which governs. Do NOT resolve this without him and do NOT edit the positioning docs until he does.
- Once decided: align `docs/DEMO_VIDEO_SCRIPT.md`, `docs/SUBMISSION_WRITEUP.md`, `docs/SUBMISSION_ONE_PAGER.md` and `docs/POSITIONING.md` to the chosen wording everywhere.
- Ownership (per the founder): technical questions for the founder are raised by Claude (via this queue / HACKATHON_STATUS); Astro handles PM-side items.

## Persistent AI-avatar snapshot follow-ups (2026-10-27, branch `avatar-snapshot`)
The standing snapshot (`users/{uid}/persona/avatar`, `persona_snapshot.py`) is built and wired for AI↔AI date sims. Remaining:
- **Human↔AI voice reads the snapshot.** The voice/agent path (`agent.py`/`voices.py`/`voice_catalog.py`) was intentionally NOT touched (another agent owns the stack-aware voice vocabulary). Wire the voice persona to spawn from `get_persona_snapshot` (the distilled `brief` + grounding) so human↔AI uses the same standing avatar. Includes surfacing `readiness`/`low_context` at any human↔AI conversation-entry preflight (today only the date-sim `GET /date-sim/estimate?other_uid=` carries it).
- **Accent in the snapshot.** The schema reserves voice/gender; spoken **accent** is not yet stored on the snapshot. UPDATE 2026-10-27 (branch `accent-work`): the accent field now EXISTS — `ayma_voice_accent` free text on `profile/main`, set from the "Ayma's models" Accent box or `set_voice_preference`, used by accent-capable voice providers at session boot (`voice_catalog.provider_supports_accent`). The snapshot can now read `ayma_voice_accent` and persist it; honour it only for accent-capable providers (same capability check).
- **Flutter: low-context warning UI.** DONE (APK 2228): the date-sim setup screen fetches `readiness` from `GET /date-sim/estimate?other_uid=` and shows a warning (`dateSimLowContextWarning`) when `low_context` is true, using the server `message` when present. Informs, does not block.
- **True conversation-volume count.** `conversation_volume` currently uses the already-gathered capped style-exemplar count (cheap, zero extra reads) as a proxy; it under-counts very chatty users (short-only, deduped, capped at 40). If needed, swap to a true uncapped own-message count across `dm_threads`.
- **Deletion coverage audit (pre-existing).** `date_sims` and `practice_sessions` subcollections are not in `schema.ACCOUNT_SUBCOLLECTIONS` (persona IS, added here). Consider adding them so account deletion wipes them too.

## Appearance report flow fixes (2026-10-28, branch `meta-hackathon`)
Shipped (see HACKATHON_STATUS dated line): rerun no longer wipes the untouched
axis so the report card survives a one-axis rerun; the pre-run sheet surfaces
ALL grid photos auto-sorted into Face/Body with tap-to-deselect (never
navigates) and Add photo on both groups; My-public-profile "Edit manually" is a
pencil icon; voice-engine dropdowns hide unavailable providers; face/body
report image calls route through `get_vision_provider` (vision-less reports
surface → Gemini). Follow-up:
- **Unified-brain capability map. [[todo-unified-brain-selector]] DONE
  (2026-10-28, branch `meta-hackathon`).** `llm_provider.supports_vision` +
  `get_vision_provider` (the first slice: vision → Gemini) is now folded into a
  full per-brain capability map (`llm_provider.BRAIN_CAPABILITIES`: Gemini =
  all; Meta/Muse = text/json/tools, no vision/web) with `supports_vision`
  derived from it. A single per-user **Brain** (`ayma_brain_model`, `gemini` |
  `meta`) drives every text surface (chat, matching, DM coach, translate) via
  `get_user_brain_provider(uid, surface, needs=…)` — the user's brain when it
  has the needed capability, else Gemini (web/vision always Gemini). UI: Brain
  section atop "Ayma's models"; API `GET`/`POST /brain/preference`; default
  `AYMA_BRAIN_DEFAULT=meta`. See ARCHITECTURE §13.10 + the HACKATHON_STATUS line.

## Argon emulator-testing harness (2026-10-28, branch `meta-hackathon`)
Dev tool at `tools/argon_testing/` (Gemini Computer-Use → ADB → GIF/MD report).
Built and verified up to the model boundary; see HACKATHON_STATUS dated line +
`tools/argon_testing/README.md`. Follow-ups:
- **Blocked on a working credential.** `GEMINI_ARGON_API_KEY` (project
  `ayma-ai`) currently holds an `AQ.` API-key-format value whose bound service
  account is deleted/disabled → 401 `ACCOUNT_STATE_INVALID`. To run Computer
  Use live, add a Gemini Developer API key with an active service account and
  Computer-Use preview access to that secret (no code change needed). Then run
  one scenario end-to-end and commit the sample `.md` + `.gif` (`git add -f`).
- **Seed the test-account password.** `login` needs `AYMA_TEST_ALEX_PASSWORD`
  in Secret Manager (project `ayma-ai`); not present yet, so `login` prompts
  interactively. Add the seeded `test.alex@ayma-ai.web.app` password there to
  run it unattended.
- **More device configs.** Boot Fold / small-screen AVDs (or `adb connect` a
  remote device) and run each scenario per serial to build a cross-form-factor
  report set.
