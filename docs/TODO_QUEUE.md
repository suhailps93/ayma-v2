# Ayma work queue (kept in the repo so any agent can pick it up)

Last updated: 2026-10-25. Update this file whenever an item changes; commit and push to main.
Rules for working with the founder: see AGENTS.md "Operating handbook" and docs/AGENT_HANDOFF.md.
Ask the founder ONE short question at a time. While a question is pending, do not send agent status; hold results here.

## 0. PRIORITY (founder, 2026-10-25): app-side testing and changes come first. Backend/vendor/admin work waits behind them.

## 1. Pending founder question (one at a time, top first)
1. (closed) Stale vendor data: banner only, no push/email.
2. AI-lab startup credits (Anthropic, OpenAI...): wait for Muse report, then decide.
3. Play Console fixes still open: Data safety, content rating (set to 18+ only), Advertising ID declaration, Child safety standards, privacy policy URL, deletion URL https://justabot.info/delete-account.html (needs Firebase Hosting deploy first).
4. Founder-only items: Facebook App ID, assetlinks SHA-256 (SHARE_ASSETLINKS_SHA256), IP assignment to the LLC, Cloud Identity, back up ~/.ayma-keys/, Play identity/phone verification, Apple Team ID (have Muse read it).
5. Parked to-do (do only when told): referral equity agreement outline + attorney questions (docs/referral-equity-program.md).
Closed: prices $9.99/$19.99/$99.99 agreed; vendor count is 24; 18+ mandatory; reviewer account approved; delete test accounts done.

## 2. Completed agent results waiting to be relayed to the founder (hold while a question is pending)
- `branded-toasts`: every Material SnackBar replaced by the branded `AymaToast` (lib/widgets/ayma_toast.dart; design in docs/ARCHITECTURE.md §14.1). App-only, needs an APK build to see it.
- `fix-prefs-theme-explore` (5b078bb): partner preferences reach the Ayma prompt (voice+chat), age-range + distance controls in Edit profile and preboarding (PUT /profile/preferences, distance_pref approximates relocation_radius), accent_color tool action, Explore results returned to Ayma. Needs backend deploy; docs not yet updated for partner_age_min/max.
- `admin-stale-alert` (277dddf): stale/unavailable banner on /admin + `stale` list in /admin/vendors.
- `fix-inference-voice-context` (e1b35e4): transcript wipe bug fixed in the app (live turns kept); voice context was not missing on Inference; real gap was partner prefs (now covered by fix-prefs-theme-explore). LiveKit gateway ignores transcription language hint; barge-in can be late.
- `fix-suggested-updates`: blank "Suggested updates" screen fixed (the theme's full-width FilledButton minimum inside a Row threw "BoxConstraints forces an infinite width", so the list never painted in release). Founder's 3 proposals (family, goals, relationships) are valid and untouched. Empty state renamed "No suggestions right now"; stale/malformed proposals are cleared on list. Needs app build + backend deploy.
- Founder profile now has partner_age_min=24, partner_age_max=38 (copied from users.matching_prefs).
- `fix-match-chat-and-language` (merged into all-features-on, not deployed): (1) a finished match now drops a `[match:<id>]` score card into the Ayma chat (opens the match report); an open chat pulls it in live. (2) The 1% Suhail x Dillu score was the trust-flag penalty: the nightly lint appended every rewording of the same contradiction (9 flags on Suhail, 2 on Dillu that are about Suhail), 0.40 off a 0.41 raw score. Lint flags now mirror the latest run; the stored flags self-correct on the next nightly lint (04:17 UTC), then Recalculate. Dillu's profile is 18% complete, so 4 of 7 dimensions are omitted either way. (3) Voice language: new `prompts/voice_language.md` rule + misheard-fragment tool guard; gateway ignores transcription language and prompt (re-verified live). Needs API + agent deploy and an APK.
- `layout-robustness` (merged into all-features-on, not deployed): the Fold "BOTTOM OVERFLOWED BY 42 PIXELS" in the orb chat sheet fixed (the sheet padded the bottom inset twice and the chat's fixed chrome, pinned-context chip + composer, could exceed the sheet's height; now capped/compact); overflow guards across the app; `test/layout_matrix_test.dart` (+2 shards) holds every route and the main sheets/dialogs/toasts to zero overflows (AGENTS.md definition of done item 5). Needs an APK install to verify on the Fold.

- `fix-voice-swap-silent` (merged into all-features-on, not deployed): the build 2209 "Changed Ayma's voice ... Switching my voice, one second" then silence. (1) The LiveKit Inference gateway loses a reply requested the instant the new Live session is set up (response.created, then nothing; the turn queue stays blocked, so "Listening" forever): reproduced live (no room, gateway only) 24 of 27 immediate replies hung, 0 of 17 after a 0.5 to 2 s settle. Fix: 1 s settle before the confirmation, plus a 6 s speak-or-rebuild watchdog that restores the old voice and says so if both attempts are silent (Sentry `VoiceSwapError`). (2) "male" asks often never swapped: the model sends `request="Puck"` and the preset name was not recognised; now mapped. (3) Separate, needs a founder decision: in that call Cloud Run sent SIGTERM to the agent instance (`draining worker` 02:55:17 UTC, 36 s after it started, only 15 s into the call) and killed it 10 s later (last line 02:55:27.5), so the call would have died anyway. Scale-to-zero lets Cloud Run reap an instance mid-call because a LiveKit call is not an HTTP request. Options: min-instances 1 for ayma-agent, or a per-call keep-alive request. Needs agent deploy.

## 3. In flight (check git branches / agents)
- `share-report-card` (merged into all-features-on, not deployed): Appearance report card (design B collage) on top of the Appearance screen, one Share button (WhatsApp, Instagram Stories, Save image, More…), private "What to do next" list. PNG rendered on device, no upload, no link. Appearance removed from `POST /share` link types. Needs APK build + backend deploy; iOS Photos save untested on device.
- `plan-page-design`: unified Plan page (segmented selector Plus/Pro/Max, one detail card, sticky CTA; keep-exploring line when out of credits), Developer panel hidden behind 7 taps on the version row, gated by flag `dev_panel` (ON by default now, OFF at store release), in-app password toggle via POST /dev/flags verified server-side against Secret Manager DEV_PANEL_PASSWORD (secret exists; founder was given the password). AI debug notes also gated by dev_panel.
- `restore-color-gradient`: restore the removed colour/gradient setting under User settings and let Ayma set it by name.
- Muse (Astro) queue, read the reports when they arrive: LiveKit credits wording + Billing page; Firebase startup program; credits survey; AI-lab credits; Apple account status + Small Business Program; move all vendor billing to the Mercury card; Cloudflare routing of justabot.info/s/* and assetlinks to ayma-api; reviewer login into Play App access; Muse scheduled-tasks question; AWS account + Activate credits application (Bedrock Claude).
- LiveKit startups email sent to startups@livekit.com; no reply yet.

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

## 4. Next deploy plan (STANDING RULE: always deploy every requested change as soon as its branch is ready, in rounds; never ask the founder whether to deploy) (founder approved: deploy everywhere from the custom branch, not main)
1. Merge the finished branches into `all-features-on` (fix-prefs-theme-explore, fix-inference-voice-context, admin-stale-alert, plan-page-design, restore-color-gradient, maps-grounding/deepdive already in).
2. Deploy API and agent from that branch (`deploy-api.sh`, `deploy-agent.sh --release`), Firestore rules, Firebase Hosting (for the new public pages), mount DEV_PANEL_PASSWORD on ayma-api.
3. Build the APK (key.properties moved aside, REVENUECAT_TEST_KEY dart-define, versionCode above 2202) and `adb install -r` (QR pairing, see AGENT_HANDOFF.md). Currently installed: 2202.
4. Ask the founder to retest voice on LiveKit (voice routed for suhailps@gmail.com via config/llm_routing; all-features-on defaults to inference for everyone).
5. Then answer the founder's earlier questions one at a time.

## 5. Facts to keep straight
- Only three real accounts remain: founder (iWhWjiWhEpU7iyu9B9vy7GlT0PD2), Dillu (Apple), Play reviewer (play.reviewer@ayma-ai.web.app; credentials in Secret Manager PLAY_REVIEWER_CREDENTIALS).
- Test deploy live now: ayma-api-00194-7ft, ayma-agent-00100-gj5 from `deploy-candidate` (857e01f). Rollback revisions: ayma-api-00193-xn5, ayma-agent-00099-k79.
- Model lock: never change a Gemini model id or flip a flag that sends traffic to a new model without the founder's explicit approval.

- Deploy wave 2 (after wave 1 lands): merge restore-color-gradient (Ayma sets accent colour by voice) now; plan-page-design (+ dev_panel flag, DEV_PANEL_PASSWORD mount) as soon as it finishes. Do not wait for both.

## 6. V2 backlog (founder-declared; do NOT build for V1)
- Instagram and Facebook integrations (sign-in and photo import), hidden behind flag `meta_integrations` (off). Reasons: Meta's Instagram login API supports professional accounts only; Facebook Login needs a Meta app plus review.
- **Ayma plug-in / MCP skill ("bring your own agent")**: let every user connect their own AI agent (ChatGPT, Claude, Gemini, etc.) to Ayma. The user chats with their agent to build their story and profile details inside Ayma, and the same agent can search for matches and chat with other users' agents through Ayma. Open design points for later: auth and scopes (OAuth/MCP server), per-user consent and data-sharing controls, rate limits and cost, moderation and safety of agent-to-agent chat, 18+ and biometric-consent gates still apply, disclosure when a conversation is agent-driven.

- `ayma-default-accent`: Ayma knows the default accent is Cherry Fuchsia (#DA4B65) and resets to it by voice/text (`app_action accent_color` value `default` runs the Accent Color screen Reset to default; `get_accent_color` returns current + default). Backend constant mirrors `AymaColors.accent`; `test_default_accent_matches_flutter_theme` fails on divergence. Needs backend deploy + APK.
