# Ayma work queue (kept in the repo so any agent can pick it up)

Last updated: 2026-10-25. Update this file whenever an item changes; commit and push to main.
Rules for working with the founder: see AGENTS.md "Operating handbook" and docs/AGENT_HANDOFF.md.
Ask the founder ONE short question at a time. While a question is pending, do not send agent status; hold results here.

## 0. PRIORITY (founder, 2026-10-25): app-side testing and changes come first. Backend/vendor/admin work waits behind them.

## 1. Pending founder question (one at a time, top first)
1. AI-lab startup credits (Anthropic, OpenAI...): wait for Muse report, then decide.
2. Play Console fixes still open: Data safety, content rating (set to 18+ only), Advertising ID declaration, Child safety standards, privacy policy URL, deletion URL https://justabot.info/delete-account.html.
3. Founder-only items: assetlinks SHA-256 (SHARE_ASSETLINKS_SHA256), IP assignment to the LLC, Cloud Identity, back up ~/.ayma-keys/, Play identity/phone verification, Apple Team ID (have Muse read it).
4. Parked to-do (do only when told): referral equity agreement outline + attorney questions (docs/referral-equity-program.md).
Closed: prices $9.99/$19.99/$99.99 agreed; vendor count is 24; 18+ mandatory; reviewer account approved; delete test accounts done; stale vendor data is banner only.

## 2. Deploy state (latest known, 2026-10-25)
- **Live (wave 5, built from `all-features-on` @ 5d7984b = 8c595ed plus the 2208 version bump, not main):** ayma-api-00201-9qm (prev 00200-r8j), ayma-agent-00106-2qj (prev 00105-2dp), Hosting redeployed. Firestore rules unchanged (no deploy). Includes screen-context + ui_action, review-fixes (c93d68e), hygiene pass, voice-start and shutdown fixes. Tests: backend 2164 passed; flutter analyze clean; only known chat_scroll_to_bottom failure. /health 200; wrong-password POST /dev/flags 403. Reviewer (consent not bumped): /bootstrap 200 with livekit, /chat/history 200.
- **Not yet deployed:** nothing on `all-features-on`.
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

## 4. Facts to keep straight
- Only three real accounts remain: founder (iWhWjiWhEpU7iyu9B9vy7GlT0PD2), Dillu (Apple), Play reviewer (play.reviewer@ayma-ai.web.app; credentials in Secret Manager PLAY_REVIEWER_CREDENTIALS).
- Model lock: never change a Gemini model id or flip a flag that sends traffic to a new model without the founder's explicit approval.

## 5. V2 backlog (founder-declared; do NOT build for V1)
- Instagram and Facebook integrations (sign-in and photo import), hidden behind flag `meta_integrations` (off). Reasons: Meta's Instagram login API supports professional accounts only; Facebook Login needs a Meta app plus review.
- **Ayma plug-in / MCP skill ("bring your own agent")**: let every user connect their own AI agent (ChatGPT, Claude, Gemini, etc.) to Ayma. The user chats with their agent to build their story and profile details inside Ayma, and the same agent can search for matches and chat with other users' agents through Ayma. Open design points for later: auth and scopes (OAuth/MCP server), per-user consent and data-sharing controls, rate limits and cost, moderation and safety of agent-to-agent chat, 18+ and biometric-consent gates still apply, disclosure when a conversation is agent-driven.
