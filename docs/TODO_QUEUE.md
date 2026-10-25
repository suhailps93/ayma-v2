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
- `fix-prefs-theme-explore` (5b078bb): partner preferences reach the Ayma prompt (voice+chat), age-range + distance controls in Edit profile and preboarding (PUT /profile/preferences, distance_pref approximates relocation_radius), accent_color tool action, Explore results returned to Ayma. Needs backend deploy; docs not yet updated for partner_age_min/max.
- `admin-stale-alert` (277dddf): stale/unavailable banner on /admin + `stale` list in /admin/vendors.
- `fix-inference-voice-context` (e1b35e4): transcript wipe bug fixed in the app (live turns kept); voice context was not missing on Inference; real gap was partner prefs (now covered by fix-prefs-theme-explore). LiveKit gateway ignores transcription language hint; barge-in can be late.
- Founder profile now has partner_age_min=24, partner_age_max=38 (copied from users.matching_prefs).

## 3. In flight (check git branches / agents)
- `plan-page-design`: unified Plan page (segmented selector Plus/Pro/Max, one detail card, sticky CTA; keep-exploring line when out of credits), Developer panel hidden behind 7 taps on the version row, gated by flag `dev_panel` (ON by default now, OFF at store release), in-app password toggle via POST /dev/flags verified server-side against Secret Manager DEV_PANEL_PASSWORD (secret exists; founder was given the password). AI debug notes also gated by dev_panel.
- `restore-color-gradient`: restore the removed colour/gradient setting under User settings and let Ayma set it by name.
- Muse (Astro) queue, read the reports when they arrive: LiveKit credits wording + Billing page; Firebase startup program; credits survey; AI-lab credits; Apple account status + Small Business Program; move all vendor billing to the Mercury card; Cloudflare routing of justabot.info/s/* and assetlinks to ayma-api; reviewer login into Play App access; Muse scheduled-tasks question; AWS account + Activate credits application (Bedrock Claude).
- LiveKit startups email sent to startups@livekit.com; no reply yet.

## 4. Next deploy plan (founder approved: deploy everywhere from the custom branch, not main)
1. Merge the finished branches into `all-features-on` (fix-prefs-theme-explore, fix-inference-voice-context, admin-stale-alert, plan-page-design, restore-color-gradient, maps-grounding/deepdive already in).
2. Deploy API and agent from that branch (`deploy-api.sh`, `deploy-agent.sh --release`), Firestore rules, Firebase Hosting (for the new public pages), mount DEV_PANEL_PASSWORD on ayma-api.
3. Build the APK (key.properties moved aside, REVENUECAT_TEST_KEY dart-define, versionCode above 2202) and `adb install -r` (QR pairing, see AGENT_HANDOFF.md). Currently installed: 2202.
4. Ask the founder to retest voice on LiveKit (voice routed for suhailps@gmail.com via config/llm_routing; all-features-on defaults to inference for everyone).
5. Then answer the founder's earlier questions one at a time.

## 5. Facts to keep straight
- Only three real accounts remain: founder (iWhWjiWhEpU7iyu9B9vy7GlT0PD2), Dillu (Apple), Play reviewer (play.reviewer@ayma-ai.web.app; credentials in Secret Manager PLAY_REVIEWER_CREDENTIALS).
- Test deploy live now: ayma-api-00194-7ft, ayma-agent-00100-gj5 from `deploy-candidate` (857e01f). Rollback revisions: ayma-api-00193-xn5, ayma-agent-00099-k79.
- Model lock: never change a Gemini model id or flip a flag that sends traffic to a new model without the founder's explicit approval.
