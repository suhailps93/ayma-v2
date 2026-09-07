# Ayma Rewrite — Build Plan

> Drop this file in as `PLAN.md` at the root of the new workspace, alongside `AGENTS.md` (rules) and `docs/ARCHITECTURE.md` (full spec). This file is the **build sequence** — the order to actually implement in. `ARCHITECTURE.md` is the **spec** — the full detail (data shapes, endpoints, diagrams) behind every step below, organized by subsystem instead of build order. Every step here cites the architecture doc section that defines it in full; this file does not repeat that detail. This plan is **tool-agnostic** — it makes no assumption about which coding tool (Claude Code, Codex CLI, Gemini CLI, Cursor, or any other) is driving a given session; every rule applies regardless.

## First message — paste this to kick off any session

> Read `AGENTS.md` and `PLAN.md` in full before doing anything else. Check `PLAN.md`'s Progress Log to find the next unstarted step — if the Environment Setup section isn't done yet, do that first. Implement only that one step, following every rule in `AGENTS.md` with no exceptions (production-ready code only, no hardcoded secrets, no mock databases). When it's done, stop and tell me exactly what to test — do not proceed, commit, or start another step until I confirm it passes.

## How to use this plan

- **Read `AGENTS.md`, then this document, every session, regardless of which tool opened it.** Then the Progress Log at the bottom to find the next unstarted step. Never resume from memory or from a chat summary — these two files are the single source of truth for where the build actually is.
- Work **one step at a time, in order**. Each step is scoped to one small, demoable piece of the app, sized to be completed in a single agent invocation — never a whole subsystem at once.
- After finishing a step: **stop. Tell the user what to test, and how. Do not start the next step until the user confirms it passes.** If it fails, fix it and ask again — don't move on.
- **Once the user confirms a step passes, commit it** (one commit per passing step, message referencing the step number, e.g. `Step 14: voice UI on chat screen`) **before starting the next step.** Never bundle multiple steps into one commit, and never commit a step that hasn't been confirmed passing.
- **After committing, mark the step done in the Progress Log** at the bottom of this file (date + step number). Append only — never delete or rewrite prior log entries.
- A step marked **(stub)** is a deliberately simplified first pass, upgraded to its full version in a later, explicitly-linked step — this is what lets a working chat companion exist by the end of Phase 2 instead of the end of the whole plan. A stub is still real, working, committed code — "stub" describes reduced *scope*, never reduced *quality*.
- If a step turns out to depend on something not built yet, stop and flag it rather than reordering silently.
- **The full coding-standards ruleset (no shortcuts, never diverge without approval, no hardcoded credentials, no mocking) lives in `AGENTS.md`, not here** — it applies to every step below without exception.

---

## Environment setup (do this before Step 1)

This plan assumes a **brand-new folder with nothing in it** — no assumption of continuity with any prior session, machine, or tool. Before Phase 0:

1. **Repo**: `git init` a new repository (or clone the empty GitHub repo the user provides) and push it to GitHub. Confirm a remote exists before the first commit lands.
2. **Firebase / GCP project**: create a new Firebase project (`firebase projects:create`) or connect to one the user already created (`firebase use --add`). Enable the APIs this plan needs as they come up rather than all at once: Firestore, Cloud Storage, Firebase Auth, Cloud Messaging (Phase 9), Cloud Run, Cloud Scheduler (Phase 6+), Secret Manager (Phase 13), Vertex AI/Gemini API.
   - **Done (2026-08-29):** connected to existing project `ayma-ai` (`.firebaserc`). Local `firebase-tools` auth uses a service-account key via `GOOGLE_APPLICATION_CREDENTIALS` (not `firebase login` — Node 22 on this machine breaks firebase-tools' token fetch; see `docs/LOCAL_DEV_NOTES.md`). API enablement still happens per-phase as the plan says.
3. **`gcloud` CLI**: authenticate (`gcloud auth login`) and set the default project (`gcloud config set project <id>`) to the Firebase project from step 2.
4. **LiveKit Cloud**: create a project at LiveKit Cloud (external to Google — needed starting Phase 2) and note the API key/secret; these go into Secret Manager (§12.3) once that exists, and into a gitignored `.env.local` before then.
5. **Flutter toolchain**: install the Flutter SDK, Android SDK/ADB (and Xcode if targeting iOS). Run `flutter doctor` and resolve every warning before Step 1.
   - **Approved deviation (2026-08-29):** the Linux-desktop toolchain (`clang`, `cmake`, `ninja`, GTK 3) is deliberately left uninstalled — this app targets Android/iOS only (package `com.ayma.ayma_flutter`), so the `flutter doctor` "Linux toolchain" section is out of scope. Android toolchain, Chrome, and connected-device checks all pass.
6. **Instagram/Meta developer app** — not needed until Phase 10; register it then, not on day one.
7. **Copy over the files listed below** rather than rebuilding any of it from scratch.

### Files to copy into the new workspace, and what each is for

| File | Purpose | Notes |
|---|---|---|
| `AGENTS.md` (root) | Tool-agnostic rules every agent follows regardless of which tool is active | Read natively by Codex CLI; every other tool's own config file should just point to it (see its final section) |
| `PLAN.md` (root) — this file | The build sequence | — |
| `docs/ARCHITECTURE.md` | Full spec behind every step | — |
| `ayma_flutter/scripts/adb-ui`, `ayma_flutter/scripts/check-flutter-env` | On-device Flutter UI automation (tap/text/swipe/screenshot) and environment sanity check, via plain ADB shell commands | Tool-agnostic — works from any coding tool that can run a shell command. **Update the hardcoded paths first**: `check-flutter-env`'s `ROOT` and `adb-ui`'s `OUT_DIR_DEFAULT` point at the old machine's path and need to point at the new workspace's actual path. This is the primary phone-testing method for this plan — not a fallback. |
| `.agents/skills/flutter_ui_design/SKILL.md`, `flutter_debugging/SKILL.md`, `ai_engineering_tdd/SKILL.md` (optional) | Flutter UI/debugging conventions and spec-driven/TDD workflow reference | Plain markdown reference files — copy over and have `AGENTS.md` mention them if useful; no tool-specific mechanism required to benefit from them, an agent can simply be told to read them |

If the active tool expects its own filename (`CLAUDE.md`, `.cursor/rules`, `GEMINI.md`, `.github/copilot-instructions.md`, etc.), create a thin pointer file in that convention containing only: *"Read `AGENTS.md` and `PLAN.md` at the repo root before doing anything else; follow them exactly."* Never duplicate the actual rules into a tool-specific file — two copies of the same rules drift the first time only one gets edited.

Two more things, useful but optional, not required for the plan to work:
- **`agent-browser`** — a general-purpose browser automation CLI, install with `npm i -g agent-browser && agent-browser install`, useful for any web-facing surface (e.g. viewing the admin console in a browser). Not tied to any specific coding tool.
- If the active tool has a design/mockup capability (e.g. Claude Code's design-canvas skill), it can be used to draft a visual mockup before implementing Phase 11's design pass — but every step in this plan is fully specified without one, so it's a convenience, not a dependency.

---

## Phase 0 — Foundation

**Step 1 — Repo & project scaffolding.** New Flutter app skeleton, new FastAPI backend skeleton (`functions/bootstrap/`), new Firebase project (§12.1). Both deploy: Flutter runs and shows a blank screen; the backend deploys to Cloud Run and answers a health-check route. Nothing functional yet.
*Test: Flutter app launches on a device/simulator showing a blank screen. Hitting the backend's health-check URL returns 200.*

**Step 2 — Baseline security rules.** Firestore/Storage rules: owner-only access on `users/{uid}`, deny-all on everything else for now (§9.2, §3.7). Prevents building the rest of the app on an open database.
*Test: from the Firebase console, confirm a signed-out client cannot read/write any collection.*

---

## Phase 1 — Auth, Preboarding (stub), Main Chat Screen shell

Goal: a person can open the app, get an account, and see a chat screen with a working text round-trip to a placeholder backend reply. No AI yet.

**Step 3 — Anonymous sign-in on launch.** Firebase Anonymous Auth fires on cold start (§3.3).
*Test: launch the app fresh; confirm a new anonymous user appears in the Firebase Auth console.*

**Step 4 — Router & app shell skeleton.** `go_router` wired up with placeholder routes for splash, preboarding, and main shell (§11.1). No real navigation logic yet — just screens you can jump between.
*Test: navigate between the placeholder screens via deep-linked routes/dev buttons.*

**Step 5 — Credential picker screen.** Google/Apple/phone/email picker UI; on selection, `linkWithCredential` upgrades the anonymous session in place (§3.1, §3.3).
*Test: link the anonymous session to a real Google account; confirm the `uid` is unchanged in the Auth console (same account, now linked).*

**Step 6 — `session_mode` endpoint (stub).** `/bootstrap` returns a hardcoded `session_mode` for now — real derivation logic comes in Step 34 (§3.3).
*Test: call `/bootstrap` with a valid ID token, confirm it returns a `session_mode` value.*

**Step 7 — Preboarding screens (text-input stub).** The 6 screens from §4.2 (name, birthdate, gender, interested_in, location, photo), but as plain typed/tapped form fields — no voice yet. Writes to `users/{uid}/profile` (§3.2, §4.2).
*Test: manually fill all 6 fields, confirm `users/{uid}/profile` is populated correctly in Firestore.*

**Step 8 — Main chat screen shell.** Empty transcript view, text input box, send button. No backend wiring yet — just the UI.
*Test: screen renders correctly, input box accepts typed text.*

**Step 9 — `POST /chat` (stub).** Backend endpoint that echoes back a canned response — proves the wiring, not the AI (§1.7 step 2, simplified).
*Test: type a message in the chat screen, see a canned reply come back.*

---

## Phase 2 — Real Agent: Voice + Text with Transcripts

Goal: a person can actually talk to Ayma, by voice or text, and see a unified transcript. This is the first genuinely demoable version of the product.

**Step 10 — Real Gemini text replies.** `/chat` calls Gemini for real (no persona yet, no memory yet) (§1.7 step 2, completed).
*Test: send a few messages, get real (if personality-less) AI replies.*

**Step 11 — Base persona.** `functions/bootstrap/persona.py`/`.md` with Ayma's character (§13.1, §13.4) wired into `/chat`'s prompt.
*Test: chat with Ayma; replies should read as warm/witty/direct/nurturing, not generic.*

**Step 12 — LiveKit Cloud project + `/bootstrap` token minting.** Real LiveKit API keys, `/bootstrap` mints a room token (§1.1, §1.7 step 3).
*Test: call `/bootstrap`, confirm a valid LiveKit token + room URL comes back.*

**Step 13 — Agent Worker service, minimal.** Second Cloud Run service (§10.1) that joins a LiveKit room and relays audio to/from Gemini Live — no transcription, no barge-in polish yet.
*Test: connect to a room from a LiveKit test client, confirm the worker joins and audio flows both directions.*

**Step 14 — Voice UI on the chat screen.** `VoiceSessionController` + mic button wired to Steps 12–13 (§1.7 steps 5, 7).
*Test: tap the mic on the chat screen, speak, hear Ayma respond by voice.*

**Step 15 — Enable native transcription + relay events.** `input_audio_transcription`/`output_audio_transcription` turned on in the Gemini Live session; relayed as data-channel events (§1.6, §1.7 step 11).
*Test: during a voice session, confirm transcript events are received (check logs/dev overlay if the UI isn't wired yet).*

**Step 16 — `TranscriptStore` + unified transcript UI.** Bounded rolling window, voice and text turns interleaved through the same code path (§1.7 steps 4, 12).
*Test: have a voice conversation, see it appear as chat bubbles on screen exactly like text would.*

**Step 17 — Mode switching.** Talk by voice, then switch to typing mid-conversation (and back) — same transcript, same context window sent to both `/bootstrap` and `/chat` (§1.5, §1.7 step 3 remainder).
*Test: start a sentence by voice, finish the thought by text; confirm Ayma's reply shows she has the full context.*

**Step 18 — Barge-in + playback interrupt.** Rely on Gemini Live's native turn-detection; client clears buffered audio on interrupt (§1.3, §1.7 steps 9–10).
*Test: start talking while Ayma is mid-sentence; her audio should stop immediately, not overlap.*

---

## Phase 3 — Persisting Conversations: Wiki & Skills

Goal: conversations stop disappearing when the session ends — they become durable memory the AI can build on.

**Step 19 — Session-end `raw_turns` persistence.** Batch write the full turn window to Firestore once per session (§1.7 step 8).
*Test: have a conversation, end the session, confirm `users/{uid}/raw_turns` is populated in Firestore.*

**Step 20 — Wiki Firestore schema + config.** `wiki_pages` collection, `wiki_schema.json` (§2.7, §2.8 steps 1–2).
*Test: schema/config exist; no behavior change yet.*

**Step 21 — Ingest pipeline.** `/post-turn` creates/updates `wiki_pages` from raw turns (§2.3, §2.8 step 3).
*Test: chat about something concrete (e.g. a hobby), confirm a relevant `wiki_pages` doc appears with that content in `ai_body`.*

**Step 22 — `add_followup_question` tool + pending-questions queue.** (§2.4, §2.8 step 5).
*Test: steer a conversation so the agent has a reason to queue a follow-up; confirm a `pending_questions` doc is created.*

**Step 23 — Skills/tools registry module.** Consolidates tool definitions, shared identically between voice and text (§13.6).
*Test: confirm the same tool (e.g. `add_followup_question`) works when triggered from both a voice session and a text session.*

---

## Phase 4 — Context-Aware Agent

Goal: Ayma actually remembers things across sessions, not just within one.

**Step 24 — Prompt composition from the wiki.** `/bootstrap` and `/chat` compile relevant `wiki_pages.ai_body` into the system prompt (§2.3, §2.8 step 4, §13.5).
*Test: mention something in one session, end it, start a brand-new session, confirm Ayma remembers without being reminded.*

**Step 25 — Lint job.** Scheduled job flagging contradictions/stale claims/orphans (§2.3, §2.8 step 6).
*Test: manually trigger the job (or wait for the schedule), confirm flags appear on a wiki page you've deliberately contradicted.*

---

## Phase 5 — Profile: Public & Private Views

Goal: the user can see and shape what Ayma has learned about them.

**Step 26 — Profile settings screen (basic).** Edit the structured fields from Step 7 post-onboarding (§4.5, §4.6 step 7).
*Test: edit your name/location from settings, confirm it saves.*

**Step 27 — Private wiki view.** Renders `public`+`private` pages as a readable personal narrative (§2.1, §2.8 step 9).
*Test: open your private profile view, confirm it reads like your story, not a data dump — and reflects what you've told Ayma.*

**Step 28 — Public profile view.** Renders `public`-only pages, same override rule (§2.1, §2.8 step 10).
*Test: confirm the public view shows a proper subset of the private one (nothing tagged private/ai_only leaks through).*

**Step 29 — Wiki edit UI.** User sets `user_edits`/`user_hidden` via the conversational chat-based editor (§2.1, §2.8 step 11, §14.3 Profile — single edit path only).
*Test: edit a section, confirm your view changes but the underlying `ai_body` is untouched (check Firestore directly).*

**Step 30 — Face embeddings on photo upload.** Gemini Embedding 2 embeds the profile photo; stored on `user_media` (§2.5, §2.8 step 7, §9.1).
*Test: upload a photo, confirm a `user_media` doc with a populated embedding vector appears.*

---

## Phase 6 — Auth & Onboarding: Full Version

Goal: replace Phase 1's stubs with the real, voice-driven, safety-hardened versions.

**Step 31 — Voice-driven preboarding.** Upgrade Step 7's typed form to Ayma asking each question by voice, autofilling an editable field (§3.3, §4.2, §4.6 step 4).
*Test: go through preboarding fresh (new anonymous session), confirm each field is spoken and autofilled, and you can edit before confirming.*

**Step 32 — `marketing`/`interview` turn caps.** 10-turn marketing cap, 40-turn interview cap, manual-fallback-form on cap-out (§3.3, §3.10 step 3, §14.3 — no skip-photo option).
*Test: exceed the marketing cap in a fresh anonymous session before signing up; confirm Ayma nudges toward "get started" and further turns are refused.*

**Step 33 — Marketing-mode restricted prompt.** Pre-"get started" sessions only answer what-the-app-is questions (§3.3).
*Test: ask an off-topic personal question before tapping "get started"; confirm Ayma redirects rather than engaging.*

**Step 34 — Real `session_mode` derivation.** Replace Step 6's hardcoded value with real server-side derivation from auth state + profile completeness (§3.3, §3.10 step 2).
*Test: confirm the app correctly routes between marketing/interview/active screens as your account state actually changes.*

**Step 35 — Location auto-detect.** Device permission → reverse-geocode → autofill, falling back to voice entry (§4.3, §4.6 step 5).
*Test: grant location permission during preboarding, confirm the field autofills with your city without being asked.*

**Step 36 — Account delete & recover.** Soft-delete into `deleted_accounts`, 30-day recovery flow (§3.6, §3.10 steps 8–9).
*Test: delete your account, confirm it disappears from the live app; sign back in within the window and confirm the recovery screen appears and restores everything.*

**Step 37 — Scheduled purge job + admin claim.** Daily purge past 30 days; `admin: true` custom claim utility (§3.6, §5.5, §3.10 steps 10–11).
*Test: manually run the purge job against a test account past its window, confirm it's permanently gone; confirm an admin-claimed account can read `deleted_accounts/*`.*

---

## Phase 7 — Matching Engine

Goal: Ayma can evaluate and surface compatible people.

**Step 38 — Sorted-pair-key helper.** Shared utility for `matches`/`dm_threads` doc IDs (§9.4, §9.5 step 5) — built once here since both this phase and Phase 8 need it.
*Test: unit-level check — same two uids in either order produce the same key.*

**Step 39 — Matching Firestore schema.** `match_candidates`, `matches`, `blocks`, `trust_flags` field (§5.9, §5.10 step 1).
*Test: schema exists; no behavior yet.*

**Step 40 — Candidate sourcing + Pass-1 heuristic scorer.** Community/orientation cross-match, structured-field filter, no LLM (§5.1, §5.2, §5.10 steps 2–3).
*Test: seed two compatible test accounts, confirm one appears in the other's `match_candidates`.*

**Step 41 — Matching skill (Pass 2).** Wiki-to-wiki compatibility scoring — `score`, per-uid `user_explanation`, `ai_explanation`, trust-flag weighting (§5.4, §5.10 step 4).
*Test: trigger a compatibility check between two test accounts with real conversation history; confirm a sensible score and explanation come back.*

**Step 42 — `POST /run-matching` + `POST /check-compatibility`.** (§5.3, §5.10 steps 5–6).
*Test: call both endpoints directly, confirm correct `match_candidates`/`matches` writes.*

**Step 43 — Scheduled matching cron + trust flags.** Daily lighter-pool run; trust flags sourced from Lint + face-embedding mismatch (§5.3, §5.5, §5.10 steps 7–8).
*Test: manually trigger the cron, confirm new `matches` docs appear for eligible users; deliberately create a contradiction and confirm a trust flag appears.*

**Step 44 — Blocking + `viewing_profile_uid` context.** (§5.6, §5.7, §5.10 steps 9–11).
*Test: block a user, confirm they disappear from future candidate pools; share a profile into an Ayma chat, confirm Ayma references it appropriately.*

**Step 45 — Matches UI.** "New from Ayma" list + match detail screen (score, reasoning, accept/reject) (§14.3 Messages/Match detail).
*Test: see a real match card, open detail, accept or reject it, confirm the status updates.*

---

## Phase 8 — Explore & Direct Messaging + Shell Assembly

Goal: the full social loop — browse, message, and the final 4-tab app shell.

**Step 46 — Explore/DM Firestore schema.** `dm_threads`, `messages` (§6.10 step 1).
*Test: schema exists.*

**Step 47 — Photo-derived attributes + Explore filter schema.** Vision extraction on photo upload, filterable schema config (§6.3, §6.10 steps 2–3).
*Test: upload a photo, confirm hair/eye color etc. populate as structured fields.*

**Step 48 — `GET /explore` + Explore feed UI.** Live filtered query, dropdown filters, NL search parsing (§6.1, §6.2, §6.10 steps 4–6).
*Test: browse Explore, apply a filter, try a natural-language search ("blondes in tech"), confirm results narrow sensibly.*

**Step 49 — Like/pass + profile share.** (§6.5, §6.7, §6.10 steps 7–8).
*Test: like a profile, confirm it can flip to mutual interest; share a profile into a DM thread, confirm it renders as a tappable card.*

**Step 50 — DM thread UI + message send.** Text/photo/voice/shared_profile messages (§6.6, §6.10 step 9).
*Test: send each message type in a real DM thread, confirm delivery and correct rendering.*

**Step 51 — DM ingestion into the wiki.** Captioning/transcription, `ai_only` default visibility (§6.8, §6.10 step 10).
*Test: send a photo in DM, confirm a wiki entry appears tagged `ai_only` (not visible in your own private view).*

**Step 52 — Block/report from DM + icebreakers.** (§6.5, §6.9, §6.10 step 11).
*Test: block from within a thread, confirm it's hidden; open a DM with an existing match, confirm icebreaker chips appear.*

**Step 53 — Assemble the main 4-tab shell.** Ayma/Explore/Messages/Profile bottom nav, orb center-tab connection state, notification bell (§11.3, §14.3 Main shell, §11.6 steps 2–4).
*Test: navigate the whole app through the real tab bar — this replaces the placeholder shell from Step 4.*

---

## Phase 9 — Notifications & Push

**Step 54 — Notification schema + FCM registration.** (§7.8, §7.9 steps 1–2).
*Test: confirm a device token is registered in `fcm_tokens` on launch.*

**Step 55 — Dispatch helper + DM/mutual-match/cron-digest triggers.** (§7.1, §7.9 steps 3–6).
*Test: send yourself a DM from a second test account, confirm a push arrives (when not viewing the thread) and a notification-center entry is created.*

**Step 56 — Re-engagement cron.** 3/7/14-day backoff check-in or profile-share (§7.1, §7.9 step 7).
*Test: manually trigger against a test account inactive past the threshold, confirm Ayma writes a real chat message and a push goes out.*

**Step 57 — Notification center UI + preferences.** (§7.9 steps 8–9).
*Test: view the notification list, mark read, tap one to deep-link to the right screen; mute a category in preferences and confirm it stops generating both the push and the list entry.*

---

## Phase 10 — Media & Photos

**Step 58 — Media schema + Instagram OAuth.** (§8.6, §8.7 steps 1–2).
*Test: connect an Instagram account, confirm recent photos + bio/captions import into `uploads/` and `raw_turns`.*

**Step 59 — Photo moderation + unified pipeline.** Every photo (upload/import/DM) runs moderation → face embedding → attribute extraction → captioning (§8.4, §8.5, §8.7 steps 3–4).
*Test: upload a clearly flagged test image, confirm it's held out of `photos`/Explore; upload a normal one, confirm it flows through every pipeline stage.*

**Step 60 — Photo soft-delete + management screen.** (§8.7 steps 5–6).
*Test: delete a profile photo, confirm it disappears from your visible grid but the underlying `user_media` doc/embedding still exists.*

---

## Phase 11 — Persona, Voice Preference & Design Polish

**Step 61 — `set_voice_preference` tool + settings picker.** (§13.3, §13.8 steps 4–5).
*Test: ask Ayma mid-conversation to sound different; confirm the preference updates and the new voice is used starting next voice session.*

**Step 62 — Final theme — `lib/theme.dart`.** Full light+dark token set with the corrected `ColorScheme` wiring, applied globally (§14.1).
*Test: toggle light/dark in Settings, click through every screen, confirm no hardcoded colors and correct contrast in both modes.*
> **Pulled forward to 2026-08-30 (commit `ebefb8c`)** at the user's request — `lib/theme.dart` now exists and is applied globally from early in Phase 1. What remains for this step's slot: the Settings light/dark toggle + a full pass confirming no screen hardcodes a colour.

**Step 63 — `paused` field + wiki reset.** (§14.2, §14.4 steps 2–3).
*Test: pause matching, confirm you disappear from Explore/candidate pools; run a wiki reset, confirm memory clears but the account/profile survive.*

**Step 64 — Full screen design pass.** Apply final component/motion conventions (pills, hairline borders, orb motif, staggered entrance) to every screen (§14.1, §14.3, §14.4 step 4).
*Test: full app walkthrough — every screen should feel visually consistent, not like a patchwork of build phases.*

---

## Phase 12 — Data Layer, API & Security Hardening

**Step 65 — Consolidated schema module + composite indexes.** (§9.5 steps 1, 4).
*Test: run through every major query path (Explore, candidate sourcing, DM list, notifications) and confirm none throws a missing-index error.*

**Step 66 — Final security rules pass.** Full two-tier ownership boundary applied to every collection, not just the Phase 0 baseline (§9.2, §9.5 step 3).
*Test: attempt a disallowed direct client write (e.g. to `wiki_pages.ai_body`) from the Firebase console/test script and confirm it's rejected.*

**Step 67 — Rate limits + auth/cron middleware on every endpoint.** (§10.4, §10.5, §10.6 steps 2–4).
*Test: hammer one endpoint past its configured rate limit, confirm a 429; call a `/cron/*` route without the secret header, confirm a 401/403.*

**Step 68 — Admin console.** Password-gated user inspector against the final data model (§14.3 Admin).
*Test: unlock the admin console, search for a test user, confirm wiki/matches/dm_threads/trust_flags all render correctly.*

---

## Phase 13 — Deployment & Production Readiness

**Step 69 — Secret Manager.** Every credential from §12.3 moved out of plain env vars.
*Test: redeploy with secrets mounted, confirm the app still functions with no plaintext secrets in the Cloud Run config.*

**Step 70 — Two-service Cloud Run deploy config.** Main API (`min-instances: 0`) and Agent Worker, per §10.1/§12.2.
*Test: confirm the API scales to zero when idle (check Cloud Run console) and the agent worker successfully handles a voice session.*

**Step 71 — Deploy scripts + `docs/agent.md` update.** (§12.6 step 3).
*Test: run the documented deploy command from a clean checkout, confirm both services deploy successfully.*

**Step 72 — Pre-release flip.** Agent Worker to `min-instances: 1` + always-on CPU (§12.2) — the last step, done only when actually going live.
*Test: confirm no cold-start delay on the first voice connection after this change.*

---

## Follow-ups / Backlog

Post-plan feature work and calibration items — not phased steps. Pick up when prioritised.

**F1 — Calibrate credit costs against real token usage.** The credit economy in
`functions/bootstrap/config.py` (`TOKENS_PER_CREDIT` 1000, `CREDITS_FREE_GRANT` 100,
`CREDIT_COST_MATCH_SCORE` 12) was set by estimate, not measurement.

- Measure real Gemini token spend per action from `users/{uid}.token_usage.features.*`
  on a test account after N real interactions:
  - `matching` — one `/check-compatibility` (`matching_skill.score_pair`: one
    `generate_json` over *both* full wikis + trust flags + system prompt).
  - `chat` — one `/chat` turn (`gemini.generate_reply`: persona + wiki context +
    recent-turns window; a second call on any tool round-trip; a vision part on an
    image). Divide total by turn count.
  - `wiki` — the ingest pass that runs *after* most chat turns; invisible to the
    user but drawn from the same budget. Include it.
  - `voice` — per-minute cost recorded by the agent worker.
  - `explore` / `reengage` — now billed too (2026-09-06). Still **unbilled**:
    `dm_ingest`, `photo_attrs` / `photo_moderation` / `photo_pipeline` (photo
    reads), `wiki_lint`. Thread `uid` through those call sites so the token
    breakdown is complete.
- Then set `CREDIT_COST_MATCH_SCORE = ceil(measured / TOKENS_PER_CREDIT)` plus a
  small buffer, and sanity-check the ratio + grant so 100 free credits buys a
  *sensible* amount of real use (state the target, e.g. "~X days of chat + Y match
  checks"). Adjust `TOKENS_PER_CREDIT` / `CREDITS_FREE_GRANT` if the numbers are off.

**F2 — Free / zero-credit users keep the core loop.** Principle: **browsing people
and chatting with Ayma must never be hard-blocked by credits.** Credits gate
compute-heavy extras only (on-demand match scoring today; voice is a candidate).

- `GET /explore` is already ungated — keep it that way; no future change may gate
  the feed or profile views.
- `POST /chat` currently hard-stops at `token_cap_per_user` (`usage_capped: true`
  → Ayma refuses). That contradicts the principle. Decide and implement one of:
  (a) a separate, smaller, *recurring* free-chat allowance distinct from the credit
  grant; (b) graceful degrade at the limit (trim context / drop tools / cheaper
  path) instead of refusing; (c) rate-limit rather than hard-cap free chat.
- Voice is the expensive path — the natural thing to gate for free users, not text.
- Acceptance: a brand-new account with 0 credits can sign up, scroll Explore, open
  profiles, and hold a real back-and-forth with Ayma. Only "Calculate match" (and
  voice, TBD) shows a credit wall.

**F3 — Credit top-up + full token accounting.** *(started 2026-09-06)*
- **Done:** `POST /credits/topup` adds `CONFIG.credit_topup_amount` (100) to
  `users/{uid}.credits_added` — a free reload, no payment. `remaining =
  grant + added − used`. `token_ledger.check` now gates on the credit balance
  (0 credits → refuse), so a top-up unblocks chat. `explore` + `reengage`
  background LLM calls are now billed (reengage records but skips the gate via
  `generate_json(enforce_cap=False)`). Credits screen: a "Reload credits"
  button, a "Tokens used so far" total, and friendlier feature labels.
- **Still to do:** real payment (Stripe / IAP) behind the same endpoint; a
  balance cap / abuse guard on free reloads; finish billing the remaining
  background features (see F1); wire F2 so zero-credit users still get core chat.

**F4 — App-wide floating listening spark (Gemini-style).** *(started 2026-09-06)*
- **Done:** brand mark is now an 8-ray "spark" (`widgets/ayma_orb.dart`,
  `AymaOrb`); the big orb in the Ayma-tab header is gone (replaced by a slim
  mono voice-state caption).
- **Still to do:**
  - Hoist the voice session + transcript to an app-level singleton
    (`services/voice_service.dart`) so it survives navigation and app exit.
  - In-app **draggable** floating spark shown on every screen while a session
    is live and the Ayma chat surface isn't foreground; tap → mute + stop
    controls slide out to the sides; free-drag, clamp to safe bounds.
  - **Android:** `flutter_overlay_window` (`SYSTEM_ALERT_WINDOW` permission
    flow) + a `foregroundServiceType="microphone"` service so the LiveKit mic
    survives backgrounding; `AppLifecycleListener` shows the system overlay on
    `paused` while active, hides it on `resumed`; overlay tap brings the app to
    front; mute/stop relayed via the overlay's data port. Play-Store policy
    note for SYSTEM_ALERT_WINDOW + background mic.
  - **iOS:** `UIBackgroundModes: [audio]` so the session keeps running
    backgrounded (OS mic pill / Dynamic Island returns to the app); no
    free-floating overlay — platform limitation, document it.

**F5 — Ayma feedback loop.** *(Phases 1–3 done 2026-09-06)*

Two separate buckets, and a human-gated prompt-improvement loop.

- **Done — capture (Stream A, Ayma-facing):** `feedback/{id}` collection.
  `record_feedback` skill (Ayma logs her own conduct misses mid-turn — repeated
  question, off-script, rambling, ignored answer, tone, pacing); one-tap
  thumbs-down on each Ayma message → `POST /feedback`. Controlled category
  vocab in `feedback_ops.CATEGORIES`. Per-turn for now.
- **Done — product feedback (Stream B, dev-facing):** `product_feedback/{id}`.
  "Send feedback" on the Profile screen → bug / idea + text + up to 4
  screenshots (uploaded to `uploads/{uid}/feedback_*`) → `POST /product-feedback`.
  Ayma never reads this bucket.
- **Done — user steering:** `set_user_steering` skill → appends a rule to the
  user's `ai_only` `steering` wiki page (new page type). `read_wiki_context`
  already carries `ai_only`, so it auto-flows into that user's every prompt.
- **Done — lessons layer:** `prompts/lessons.md` (curated ≤15 bullets) is
  appended to the composed system prompt after the persona (`prompt.load_lessons`).
  Empty today.
- **To do:**
  - **Move per-turn friction detection to a nightly batch** in production
    (cost) — a `wiki_lint`-style job scanning recent `raw_turns` for repeated
    questions / answered-question re-asks / disengaged replies.
  - **`/ayma-feedback-review` Claude Code skill** — weekly: cluster `feedback`
    rows by category + similarity → draft additions to `prompts/lessons.md`
    with rationale + `feedback_ids` → run the eval gate → hand the diff to a
    human. Feedback text is only ever *summarised*, never followed.
  - **Eval set** — `functions/bootstrap/evals/ayma_persona/` ~25 curated
    `{transcript, failure, rubric}` cases + a runner. A candidate `lessons.md`
    must beat the current one before merge.
  - **Measure** — after a lessons.md change ships, watch whether the addressed
    feedback categories' rates fall.
  - Triage: route prompt-fixable feedback → lessons.md proposal; structural
    (e.g. Ayma not checking `pending_questions`) → a bug.
  - Optional later: a "things Ayma avoids for you" read-only view of the
    steering page in the private wiki.

---

## Post-launch iteration log (2026-09-05 → )

The 72-step plan closed on 2026-08-30. Everything below is **founder-driven
feature work after that**, not phased steps. It is kept here so `PLAN.md`
stays the single source of truth for where the build actually is. Newest
first. Deployed revisions as of last update: **`ayma-api-00072-4xn`**,
**`ayma-agent-00023-6tr`**; Flutter debug APK on the Pixel 10 Pro Fold.

### How this diverged from the original plan (read this first)

- **The plan is "complete" but the app is not "done".** All the work below is
  real, shipped, tested, and deployed — but it is not reflected in the phased
  step list, and no test-and-confirm gate was run per-step (the founder tests
  on-device between batches instead). This section is the record.
- **§14.3 Admin console (Step 68) has been removed from the mobile app**
  (`544450c`). It moves to a **separate web-only "God Mode" dashboard** at
  `/home/suhailps/workspace/ayma-godmode/` — its own git repo, outside this
  codebase and outside this plan. Backend `/admin/*` endpoints stay for it to
  use. God Mode is built + live-verified but **not deployed** (`deploy.sh` is
  the founder's to run).
- **§14.1 design pass (Step 64) was superseded** by a full re-skin to the
  claude.ai/design "Ayma" system (`60e7483`) — no screens added or removed.
- **Voice model moved off Vertex.** Steps 61/72 assumed Vertex Live 2.5; voice
  now runs `gemini-3.1-flash-live-preview` via the Gemini **Developer API**
  (`GOOGLE_API_KEY` secret on `ayma-agent`), because Vertex tops out at Live
  2.5. `enable_affective_dialog` + `proactivity` were turned on (`b9f5686`)
  and **reverted** (`62b4a5e`) — they are native-audio-only and the
  half-cascade Live model rejects session setup when they're set, which took
  voice down entirely. Both default OFF now, opt-in per env.
- **A whole credit economy (F3) was added** on top of the token ledger — not
  in the original plan. F1 (calibrate costs) and F2 (free-tier core loop)
  remain open, and **F2's core principle is currently violated**: `POST /chat`
  still hard-stops at 0 credits.
- **Chat-image moderation now bypasses all app-side checks** (`90a13b9`) —
  divergence from §8.4. A photo the user shares *privately with Ayma in chat*
  goes straight to Gemini; only Gemini's API safety applies. Profile-photo
  moderation (photos other users see, via `photo_pipeline`) is unchanged.
- **Voice accent/language is free text**, not a fixed list (`90a13b9`) — the
  settings field takes "Malayalam mixed with English", "a soft Southern US
  accent", etc.; `set_voice_preference` stores the phrase verbatim; the Live
  model only gets an exact BCP-47 tag when one is typed, otherwise the system
  prompt drives it.
- **Wiki visibility widened** (`4987ed6`): `values`, `personality`, `goals`
  now default `public` (dating-profile material); ingest no longer overwrites
  a visibility the user set by hand.
- **The `steering` `ai_only` wiki page type** (F5) and the `deepdive` token
  bucket are new schema surface not in `ARCHITECTURE.md`.

### Shipped

**Your Story v3.1 — passage chat polish (2026-09-07)**
- The passage chat is now a **cleaner docked panel** (rounded top, grabber,
  pill input, elevation). Fixed a keyboard overflow — it was adding
  `viewInsets.bottom` on top of the Scaffold's own resize.
- Ayma's proposed rewrite renders **inline in the thread** as a phone-readable
  word diff (removed words struck through, added words tinted, wrapping prose
  — no monospace, no horizontal scroll, no separate sheet) with **Accept /
  Reject** right there.
- **"Chat with Ayma"** added to a section's ⋯ menu (chat about the whole
  section, not just a highlighted passage).
- Suppressed the OS "Copy · Share · Ask …" selection menu over the editor's
  own passage toolbar.

**Your Story v3 — select-in-place, public-by-default, per-section history (2026-09-07)**
Reworked again after phone testing (v2's select-and-act only worked in a
buried edit mode and matched by text, which silently failed).
- **`SelectableMarkdown`** widget: parses a section's markdown into segments
  that each remember their offset back into the raw body, renders it rich
  **and** selectable. Selecting a passage in the reading view surfaces a
  toolbar — **Make private · Make public · Delete · Ask Ayma** — and the
  selection carries exact raw-body offsets, so privacy/delete are clean local
  body edits (`setPrivacy()` re-serialises `{{private}}` spans) + a plain
  `PUT /story/section`. No server-side substring matching.
- **Public by default.** `wiki_schema` narrative pages all default `public`
  (`family`/`relationships`/`dealbreakers`/`lifestyle`/`misc` flipped); the
  ingest prompt now says "public unless inherently sensitive; wrap a
  sensitive line in `{{private}}`" and to never touch a user-owned page's
  visibility. `public_profile` renders the rich body with private spans
  stripped.
- **Per-section version history.** Dropped the whole-story `story_versions`
  stream for `wiki_pages/{id}/versions/` — each section its own git-style
  log. `⋯ → History` per section → diff a version vs current → revert just
  that section (never `ai_body`). `wiki_ingest` commits an Ayma version per
  changed section (debounced, skipped when the user has overridden the body).
- **Passage chat is a thread.** `POST /story/edit` takes the running
  `messages` and returns `{reply, revised_body?, action}`; the docked panel
  is a back-and-forth, and an **Apply this change** button (when Ayma
  proposes a body) → diff → save.
- Endpoints: dropped `/story/section/span`, `/story/versions*`,
  `/story/revert`; added `/story/section/{id}/versions[/{vid}]` and
  `/story/section/revert`.
- Backend 379 passed, Flutter 161 passed (`selectable_markdown_test.dart`
  new), analyze clean. Deploy: `ayma-api` + `ayma-agent` (ingest prompt).

**Sign-in gate — real auth, no anonymous browsing (2026-09-07)**
Phase 1 of the onboarding rebuild. The app now requires a real credential
up front (the user's call, a change from anonymous-first + link-in-place).
- `lib/services/auth_service.dart` (replaces `auth_link_service.dart`):
  `signInWith{Google,Apple,EmailPassword}` + phone, all `signInWithCredential`
  (fresh sign-in, not `linkWithCredential`). Email path creates the account
  if it doesn't exist.
- `lib/screens/sign_in_screen.dart` (`/signin`, replaces the credential
  picker): Google · Apple (iOS/macOS only, still pending Apple Developer
  config) · Email · Phone, in one screen with staged email/phone sub-forms
  and the Terms line.
- `main.dart` no longer signs in anonymously. Splash: no user / anonymous /
  stale token → `/signin`; else bootstrap + route. `app_router` has a
  `redirect` that bounces unauthenticated users to `/signin` (splash, terms,
  recovery stay open). Sign out → `/signin`.
- Firebase console: Anonymous, Email/Password, Phone, Google enabled by the
  founder; Apple still to configure (Services ID + key).
- Flutter 159 passed, analyze clean.

**Phase 2 — Ayma greets on the sign-in screen (2026-09-07)**
No separate voice-intro screen (the user's call). Instead:
- The **sign-in screen has a live talking orb**. `POST /welcome/token`
  (unauthenticated, per-IP throttled) mints a LiveKit token for an ephemeral
  `welcome-*` room seeded with a greeting-framed persona (`welcome_persona.md`
  + base persona). The agent reads `greeting_instructions` from the room seed
  and **speaks first** (`session.generate_reply`), focusing on what Ayma is
  for, then prompting sign-in. `uid`-less → unmetered, meant to last <1 min.
  Tap the orb to stop/restart; a successful sign-in stops it.
- `VoiceSessionController(welcome: true)` routes through `/welcome/token`
  instead of `/bootstrap`; everything downstream (transport, mic, transcript)
  is unchanged.
- **Voice removed from preboarding** — the mic button, `_toggleVoice`, and
  the `VoiceSessionController`/`TranscriptStore` wiring are gone; preboarding
  is a plain form now.
- Backend 383 passed (`test_bootstrap.py` +3), Flutter 159, analyze clean.
  Deploy: `ayma-api` + `ayma-agent` (agent greeting).

**"Your Story" — one-document editor with version control (2026-09-06 → -07)**
Replaces the read-mostly "Your private wiki" screen. First shipped with a
two-body (private + separately-authored public) model; **reworked after
phone testing** to a single document (the user's call): no sidebar, one
scrolling doc, a **Private | What's public** view toggle, markdown
rendering, a docked "ask Ayma about this passage" panel, and a version
timeline with diffs + revert.
- **Sections** = `wiki_pages` by `page_type`, minus `ai_only` / `user_hidden`.
  ONE body per section (`user_edits` else `ai_body`). Narrative sections
  first, then a "From Ayma's skills" divider, then `face-analysis` /
  `body-analysis` / `web-findings` compiled from their structured data into
  clean markdown (no `[hair_styling]` tags).
- **Visibility is `public | private` only** — "AI-only" is never shown. A
  *deleted* section goes to `ai_only` + `user_hidden` (Ayma keeps it, a
  revert restores it) but is never labelled that way. Public applies per
  section AND per **passage**: an inline `{{private}}…{{/private}}` span
  stays in the doc (dimmed, tagged) and is stripped from the Public view
  and from `public_profile`.
- **Whole-story snapshots** (`users/{uid}/story_versions`, no per-side
  split): cut on save, accepted Ayma diff, visibility flip, span action,
  delete, revert, and — debounced 5 min — a `wiki_ingest` change. Pruned to
  200. `story.py` + endpoints: `GET /story`, `PUT /story/section`,
  `POST /story/section/{visibility,span,remove}`, `POST /story/edit`,
  `GET /story/versions[/{id}]`, `POST /story/revert`.
- **Revert** restores section bodies + visibility only — never `ai_body`,
  never `ai_only` pages.
- **Highlight → chat**: select text in a section's edit view → docked panel
  with the quoted passage + **Make private/public** + **Delete this** chips
  (immediate, via `/story/section/span`) + a free-text box → `POST
  /story/edit` classifies **rewrite** (red/green diff, Accept/Reject) /
  **move** (flip section visibility) / **remove** (delete section).
- `MarkdownText` gained `![](url)` image blocks. Dependency-free
  `lib/util/text_diff.dart` (LCS line + word diff) backs `DiffView`.
- `private_wiki_screen.dart` + its test deleted. Backend 380 passed
  (`test_story.py` rewritten, 19), Flutter 158 passed, analyze clean.

**Face/body reports run in chat + report history (2026-09-06)**
- Pressing **Facial beauty report** / **Physique report** on the Skills
  screen no longer opens a blocking "Analysing the photo…" sheet — it hands
  off to the Ayma chat (`ChatKickoff.faceReport` / `.bodyReport` via
  `ChatInbox`), exactly like Deep dive. `showFaceReportSheet` /
  `showBodyReportSheet` (the run-and-spinner sheets) are deleted.
- In chat, the report first **asks which photo to use** — "Use my profile
  photo" or "Upload a photo". Empty attachment → the server runs on the
  primary profile photo and 400s if there is none, which the chat turns into
  "Add a profile photo first, or send me one here."
- The report **card renders inline** in the conversation (score, features,
  strengths, recommendations) with the **analysed photo embedded at the top**
  — tapping it opens the same report full-screen. No more `[face_report:id]`
  → bare "View report" button; the marker still works for the tool-called
  path but now drives the inline card and `[1]` citation noise is stripped.
- **An unusable read is not a report**: the skill returns just "send a
  clearer shot", stores nothing, emits no marker — so no empty card / button.
- **Report history** — `GET /skills/reports/{kind}` lists a user's stored
  face / body reports (usable only, newest first); the Skills screen shows
  the last few under each skill, tap to reopen. Reports now persist
  `image_path` alongside `report` + `created_at`.

**Streaming chat, Skills tab, identity, auto-analysis + Terms (2026-09-06)**
— `a9c32a6`, `abc6ba6`, `c93facf`, `f2c2eaf`, `b5dab29`.
- **`POST /chat/stream`** (SSE): the pending Ayma bubble shows the *live*
  step — "Searching the web…", "Analysing the photo…", "Reading the page…" —
  from `gemini.generate_reply_events()`, then resolves to the reply. `/chat`
  stays for back-compat / fallback. No more flat "Ayma is thinking…".
- **Skills screen** (`/skills`, linked from Profile) — Search the web (name
  pre-filled), Facial beauty report, Physique report (each: use my profile
  photo, or pick + upload one). The three loose Profile rows are gone.
- **Identity** — `first_name` / `last_name` / `phone` captured in onboarding
  + Profile → Details + the `set_profile_field` skill. Deep dive uses the
  full name; phone is a private disambiguator only (never in the query).
- **Skill memory** — `skill_memory.py`. Every `deep_dive` / `face_report` /
  `body_report` run (skill or endpoint) writes an **`ai_only`** wiki page
  (`web-findings` / `face-analysis` / `body-analysis`) so Ayma carries it in
  context. `POST /wiki/promote` moves one to `private` ("add to my story");
  the explicit-ask endpoints auto-promote. `GET /skills/report/{kind}/{id}`
  re-opens a stored report; a chat reply carrying `[face_report:<id>]` shows
  a "View report" button.
- **Auto-analysis, no opt-out** (`auto_analysis.py`) — every photo the user
  uploads (`/media`, `/media/photos`, DM photos, Instagram import) fires a
  background face + body analysis that **accumulates** into the `ai_only`
  pages (latest read + dated history, 4000-char cap). A one-time self web
  dive fires from `/bootstrap` once the user has a name
  (`users/{uid}.auto_dive_done` guard). Only ever about the account owner —
  never a match or third party. `TokenCapExceeded` is swallowed in the
  background paths.
- **Terms of Service** — first legal surface in the app. `docs/TERMS.md` +
  `lib/legal/terms_text.dart` + `/terms` screen, linked from sign-in ("By
  continuing you agree to our Terms") and Profile. Real copy for the
  automatic-analysis disclosure + account basics; Safety / Your data /
  Payments / Changes / Contact are `[PLACEHOLDER — legal review needed]`.
- **Ayma offers skills** — persona: one light offer ("want me to look you up
  online?") when the conversation gives an opening; never runs a skill
  without a yes.
- Image history fix (`3e8454d`): a reloaded image turn shows the image, not
  "shared a photo".

**Chat UI → Gemini-style + face/body reports (2026-09-06)** — `3e8454d`,
`d7ce4e8`, `68afb4d`, + the profile-wire commit.
- Chat layout: you = right-aligned rounded bubble; Ayma = full-width, no
  bubble, serif italic, markdown (so `#` renders as a header, `-`/`1.` as
  lists). Tool activity is a small `✦ SEARCHED THE WEB` header inside Ayma's
  block. A non-final Ayma turn = spinner + "working on it" text.
- **`ChatInbox`** singleton — a one-slot "button → background skill in the
  Ayma chat" hand-off. The public-profile "Deep dive" and Profile-tab "Look
  me up online" buttons push a kickoff + `context.go` to the shell;
  `MainShellScreen` jumps to the Ayma tab; `ChatScreen` drops a
  "Searching the web… this can take a moment" pending turn, runs the skill,
  `resolvePending()`s the result in place. `deep_dive_sheet.dart` deleted.
  This is the pattern for every future button-triggered skill.
- **`face_report` / `body_report`** — new skills + `POST /face-report` /
  `/body-report`. Honest, data-driven analysis of a face / physique from a
  photo the user shared in chat (skill grabs the latest `chat_messages`
  image) or their primary profile photo (endpoint). `run()` → structured
  digest (overall score, per-feature scores + notes, quick facts, strengths,
  improvements, recommendations); `render()` → a chat summary; the full
  report opens as a `FaceReportView` / `BodyReportView` card. Reports stored
  at `users/{uid}/{face,body}_reports/{id}`. **No app-side image check on
  either path** — straight to Gemini. New `face_report` / `body_report`
  token buckets.
- Image history: a reloaded image turn shows the image, not the "shared a
  photo" placeholder (`chat_history.append` strips it; the `raw_turns` merge
  de-dups against both forms).

**Deep dive (2026-09-06)** — `cb2a1f8`, `d02e9eb`.
`deep_dive.py` (`run()` = grounded web research → structured digest: summary,
facts w/ source + confidence, links flagged likely/maybe/unclear) +
`deep_dive` skill (async; Ayma calls it only on an explicit "look me/them up")
+ `POST /deep-dive` (button path: resolves the name from the profile, runs it,
drops Ayma's summary into `chat_messages`, returns the digest). Client:
"Look me up online" on the Profile tab, "Deep dive" on a public profile, a
`deep_dive_sheet` bottom sheet. `gemini.research()` helper; `generate_reply`'s
tool loop now `await`s async tool fns. Persona carves out consented lookups.

**Explore + one public-profile screen (2026-09-05/06)** — `fdc66a8`, `2c8fb74`,
`3c4fff8`, `3536d56`, `d523f53`, `59aaf88`, `d492de1`.
- `GET /explore/profile/{uid}` + `public_profile.py` — the cross-user view the
  security rules won't let the client read: name/age/location, public wiki
  narrative, photos as token URLs, caller-relative score/like state, DM
  thread id.
- `PublicProfileScreen` is now the **only** public-profile surface. Its
  self-view is "My public profile" and *is* the Explore preview.
  `explore_preview_screen.dart` and `public_wiki_screen.dart` deleted.
- Explore cards: a Reels-style vertical like / message / run-match rail
  overlaid on the photo; card-body tap opens the full profile. Your own card
  is pinned first and tappable. Nameless / test profiles gated out. The
  blonde/brown/black/red hair chips removed.
- Explore 500 fixed (photo schema migrated to `[{media_id, order}]`).
- 17 leftover test-user docs deleted from Firestore.

**Voice: accent/language + preview + logging (2026-09-06)** — `4987ed6`,
`6e9f243`, `90a13b9`, `b9f5686`.
- Free-text `ayma_voice_language` on `profile/main`; settings text field
  prefilled with Ayma's current default; she follows the caller's language
  mid-call; `set_voice_preference` gained `accent_language`.
- Voice preview stops any prior preview and ends a live call before playing.
- `relay_token_usage` logs raw per-turn / per-session Live token counts
  (`voice-usage …`) for billing reconciliation.

**Chat: tools UI, thinking budget, Maps, Markdown (2026-09-06)** — `75756cc`,
`b88e6e7`, `4987ed6`.
- `google_search` + `url_context` grounding on text chat (`GEMINI_WEB_SEARCH`,
  on by default); a dim "✦ Searched the web · …" caption on Ayma's reply.
- `thinking_level=low` for chat (`generate_reply`); background JSON untouched.
- Google Maps grounding wired but **dormant** — needs `GEMINI_MAPS_API_KEY`
  secret + the Maps Grounding API enabled.
- `MarkdownText` widget (no deps) renders Ayma's bubbles + public-profile
  sections (**bold**, *italic*, `code`, links, lists).

**Credits economy (2026-09-05/06)** — `00b6cfe`, `5dfe87a`, `280cd86`,
`0f1eb0a`, `b9f5686`, `164fc8c`, `62b4a5e`, `9f90eac`, `2b28898`, `e16f169`.
- `token_ledger` credit view: `used = ceil(tokens / TOKENS_PER_CREDIT)`,
  `remaining = grant + added − used`, `grant = credit_grant ?? CREDITS_FREE_GRANT`
  (100). `check()` refuses at `remaining ≤ 0`.
- `POST /credits/topup` — free reload; forgives an overspend so one reload =
  `amount` usable credits (the naive `Increment` left heavy users stuck at 0).
- Credit gate stops every LLM path when broke (chat, voice, matching, wiki
  ingest, explore NL parse, reengage); heuristic paths (people-to-people
  chat, message search) keep working.
- `backfill_ops` — when credits return, re-ingest conversations skipped while
  broke (`ingest_pending` flag → `drain()` on top-up, nightly `sweep()` via
  `POST /cron/ingest-backfill`). Index-free `drain`; CG index for `sweep` in
  `firestore.indexes.json`.
- Credits screen: plain wallet ("N credits left", no denominator, no fill
  bar), "spent so far", per-feature breakdown.

**Chat history + attachments (2026-09-05)** — `8882982`, `164fc8c`, `512003b`.
Durable `chat_messages` transcript; image attachments; `/chat/history` merges
`raw_turns` so voice + pre-feature conversations show; own rate limit.

**Feedback loop F5 Phases 1–3 (2026-09-06)** — `a96b75e`. See F5 above.

**Design re-skin (2026-09-05)** — `60e7483`. Whole app to the Ayma design
system; `ayma_orb` 8-ray spark, `ayma_primitives`, tab bar, Explore grid.

### Open / next

Consolidated — supersedes the scattered "to do" lines in F1–F5 where they
overlap.

0. **Chat UI — the rest of the Gemini-style pass.** Still to do: (a) share a
   user's profile from Explore → the Ayma chat as an inline profile card;
   (b) PDF attachments in the composer (`/chat` `image_path` → a general
   attachment; Gemini reads PDFs); (c) rich web-image cards inside arbitrary
   Ayma messages (deep-dive links render as plain markdown links for now).
   Done: face/body reports run in-chat via `ChatInbox`, render an inline
   report card with the analysed photo embedded, and are listed per-skill on
   the Skills screen (`GET /skills/reports/{kind}` + `/skills/report/{kind}/{id}`).

0b. **Auto-analysis — cost + legal + calibration.** Now runs face + body on
   *every* uploaded photo and a web dive per user, unprompted (founder's
   call, disclosed in Terms). Open: (i) **F1** — this is a big uncalibrated
   spend (2 vision calls per photo + 1 web dive/user, background, un-gated by
   `check()`); measure and decide a ceiling. (ii) A photo hitting both
   `/media` and `/media/photos` is analysed twice — accepted, but a dedup
   guard (skip if a read for that `storage_path` already exists) would be
   cleaner. (iii) `docs/TERMS.md` has real copy only for the analysis
   disclosure + account basics; Safety / Your data / Payments / Changes /
   Contact are `[PLACEHOLDER — legal review needed]` and must be finished
   before any public launch. (iv) No admin/ops view of what's been
   auto-gathered per user (God Mode would show the `ai_only` pages).

1. **F2 — free-tier core loop.** `POST /chat` still returns `usage_capped`
   and Ayma refuses at 0 credits. Decide (a) separate recurring free-chat
   allowance, (b) graceful degrade, or (c) rate-limit-not-cap. Explore stays
   ungated. **This is the most important open item** — it contradicts a
   stated product principle.
2. **F1 — calibrate credit costs.** Still all estimates. New `deepdive` bucket
   is a heavy spend (two grounded Gemini calls) and uncalibrated. Bill the
   still-unbilled background features: `dm_ingest` media, `photo_attrs` /
   `photo_pipeline`, `wiki_lint`.
3. **F3 — real payment** (Stripe / IAP) behind `/credits/topup`; a balance
   cap / abuse guard on free reloads.
4. **Google Maps grounding** — provision the `GEMINI_MAPS_API_KEY` secret +
   enable the Maps Grounding API, add the secret to `scripts/deploy-api.sh`,
   `--full` deploy. Code path is already in `gemini.generate_reply`.
5. **God Mode dashboard** — review `/home/suhailps/workspace/ayma-godmode/`,
   run its `deploy.sh` (`gcloud run deploy ayma-godmode`). For V4 signed
   photo URLs it needs `roles/iam.serviceAccountTokenCreator` on the runtime
   identity; without it it falls back to Firebase token URLs + an authed
   `/img` proxy (works). `.heic` profile photos won't render in most
   browsers (placeholder shown).
6. **Cloud Scheduler job for `/cron/ingest-backfill`** (nightly). The
   collection-group `raw_turns.ingest_pending` index is already in
   `firestore.indexes.json` — deploy it (`firebase deploy --only
   firestore:indexes`).
7. **F4 — floating listening spark.** Only the spark mark + big-orb removal
   are done. App-level voice singleton, in-app draggable spark, Android
   `SYSTEM_ALERT_WINDOW` overlay + mic foreground service, iOS background
   audio — all still to do.
8. **F5 Phase 4** — nightly friction-detection batch, `/ayma-feedback-review`
   skill, `evals/ayma_persona/` set + runner.
9. **Voice affective dialog / proactivity** — only work on a native-audio Live
   model. Revisit if voice ever moves to `gemini-live-2.5-flash-native-audio`
   or a 3.x native-audio model on Vertex.
10. **Gemini capabilities the founder OK'd but deferred:** context caching
    (largely implicit on 3.x already — verify prompt prefix stays stable),
    Files API / long context (no feature needs it yet — attach to a
    "catch me up" summary when one exists), Batch API (nightly wiki ingest +
    reengagement drafting at ~50% cost — a real refactor).
11. **Verify the Gemini TTS model id** (`gemini-2.5-flash-preview-tts`)
    against the live project; may need a `gemini_tts_location`.
12. **Pre-existing unrelated test failures** —
    `test_photo_ops::test_remove_photo_is_soft_and_renumbers` and
    `test_reengagement::test_run_skips_active_users` fail from someone's
    in-progress `photo_ops.py` / `schema.py` / `photo_pipeline.py` edits sitting
    uncommitted in the tree. Not touched this session. Resolve or commit that
    work.

---

## Progress Log

Append one row per completed step, in order, immediately after the user confirms it passes and the commit lands. Never edit or delete a prior row.

| Step | Date | Commit | Notes |
|---|---|---|---|
| Env setup | 2026-08-29 | ba10e08 | Repo + private remote (ayma-v2); Firebase connected to `ayma-ai` via service-account key (Node 20 shim — Node 22 breaks firebase-tools); Flutter toolchain green except Linux-desktop (approved deviation, mobile-only). See `docs/LOCAL_DEV_NOTES.md`. |
| 1 | 2026-08-29 | 389bdbd | Flutter skeleton (blank Scaffold) + FastAPI `functions/bootstrap` deployed to Cloud Run `ayma-api` (us-central1, min-instances 0). `flutter analyze`/tests clean; `/health` → 200; app launches to blank screen on emulator. |
| 2 | 2026-08-29 | c07a24b | `firestore.rules` + `storage.rules` (owner-only `users/{uid}` & `uploads/{uid}/*`, deny-all elsewhere) + `firebase.json` deployed to `ayma-ai`. Verified: signed-out client → 403 on all Firestore/Storage read+write. Finer §9.2 boundary deferred to Step 66. |
| 3 | 2026-08-29 | f164811 | Anonymous Firebase sign-in on cold start (`main.dart` + FlutterFire config). Enabled Anonymous provider on `ayma-ai`. Android toolchain bumped (minSdk 23, NDK 27, Kotlin 2.2.20) for firebase_core/auth. Verified: fresh launch created anonymous uid, Auth user count 3→4. |
| 4 | 2026-08-29 | 3637741 | `go_router` + placeholder screens (splash/preboarding/main shell) with dev nav buttons. No redirect logic yet. Verified: widget test navigates all three; on-device tap navigates splash→preboarding. |
| 5 | 2026-08-29 | 24e682d | Credential picker (Google/Apple/phone/email) + `AuthLinkService.linkWithCredential`. Registered debug SHA-1/256; added google_sign_in/sign_in_with_apple. Verified on-device: email link kept the same uid, added `password` provider (Identity Toolkit lookup). Google/Apple/phone coded, need interactive/device to test e2e. |
| 6 | 2026-08-29 | 7b8a52c | `POST /bootstrap` (backend): `require_uid` verifies Firebase ID token (firebase-admin), returns hardcoded `session_mode` ("marketing") + uid. Deployed rev ayma-api-00004. Verified: valid token → 200 w/ session_mode, no token → 403, bad → 401. Real derivation = Step 34. |
| 7 | 2026-08-29 | 8738ad9 | Preboarding typed-form (6 steps: name/birthdate/gender/interested_in/location/photo) → `ProfileService` writes `users/{uid}/profile/main` + photo to `uploads/{uid}/`. Verified on-device: all 6 fields present in Firestore, photo in Storage. Voice/geo/embedding deferred (Steps 31/35/30). |
| 62 (early) | 2026-08-30 | ebefb8c | **Reordered by user request:** `lib/theme.dart` (§14.1 / §14.4 step 1) pulled forward from Phase 11. Full Ember token system, `context.ac` extension, serif/mono via google_fonts, Geist bundled, ColorScheme per §14.1 rules, pills + hairlines. Applied globally (themeMode dark). Step 64 full design pass still pending. New screens from here use `context.ac.*`. |
| 8 | 2026-08-30 | b6b97bb | Chat screen shell: `lib/screens/chat_screen.dart` — empty transcript hint + composer (TextField + enable-on-text send). Route `/chat`. Themed. Verified: renders on emulator; widget test confirms text input. Backend wiring is Step 9/10. |
| 9 | 2026-08-30 | d7fe51a | `POST /chat` canned echo (rev ayma-api-00005) + `lib/env.dart` + `ApiClient` + chat transcript bubbles. `RATE_*` consts added. Verified on-device: "hello ayma" → `(stub reply) You said: "hello ayma"`. Backend + Flutter tests green. |
| 10 | 2026-08-30 | a9ce7cd | `/chat` now calls Gemini for real — `gemini.py` (google-genai via Vertex AI, model from `config.py`, default gemini-2.5-flash). Rev ayma-api-00006. Verified: deployed + on-device replies are genuine LLM output (no persona yet). |
| 11 | 2026-08-30 | 12b13f7 | Base persona: `persona.md` (character + mood-mirroring) loaded by `prompt.py` `compose_system_prompt()` and passed as `system_instruction` to `/chat`. Rev ayma-api-00007. Verified: replies read warm/witty/direct/nurturing, mood-matched, concise. |
| 12 | 2026-08-30 | 3afe0e8 | `POST /bootstrap` mints a 900s room-scoped LiveKit JWT (`livekit_token.py`, `livekit-api==1.2.1`) → returns `{session_mode, uid, livekit:{token,url,room}}`, 503 if unconfigured. Real LiveKit Cloud project `aimma-wt34nu3l`; key/secret in Secret Manager (`LIVEKIT_API_KEY`/`LIVEKIT_API_SECRET`), `LIVEKIT_URL` plain env var. Rev ayma-api-00008. Verified e2e with a real Firebase ID token (valid room-scoped JWT) + key/secret authenticates to LiveKit Cloud. Agent-context seeding = Step 13. |
| 13 | 2026-08-30 | 3247f8c | `agent.py` LiveKit voice worker (livekit-agents 1.7.1 + livekit-plugins-google, Gemini Live `RealtimeModel`, base persona, native turn detection). Separate Cloud Run deployable from the same source tree: `requirements-agent.txt` / `Dockerfile.agent` / `cloudbuild.agent.yaml` (split image — google-genai 2.x vs 1.14 pin). `config.py`: `gemini_live_model`/`gemini_live_voice`. Deployed `ayma-agent` rev `ayma-agent-00003-qsk` (`--no-cpu-throttling --memory 2Gi --min-instances 0`). **Deviation from §12.2:** always-on CPU applied now — a request-only-CPU instance never finishes worker registration; `min-instances 0` kept, Step 72 owns the `:1` flip. Verified: logs show `registered worker` vs real LiveKit Cloud, instance stays up. Live audio round-trip pending a real-time client (Step 14 / manual device test). |
| 14 | 2026-08-30 | 0657c31 | `VoiceSessionController` (ChangeNotifier) + `VoiceTransport` seam (`livekit_client` isolated to `LiveKitVoiceTransport`). Mic button on `ChatScreen` → `ApiClient.bootstrap()` → room connect → publish mic → agent audio playback; mute/stop; voice status strip. Phases idle/connecting/live/error. Android/iOS mic permissions added; no `permission_handler` (WebRTC raises the prompt). **Toolchain bump:** AGP 8.7.3→8.9.1, `compileSdk` 35→36 (`livekit_client`→`connectivity_plus`→`androidx.core:core:1.18`). `flutter analyze` clean, 11 tests pass, `flutter build apk --debug` green. Not yet done: on-device "tap mic, speak, hear Ayma" (needs a device); unified transcript is Step 16, recent-turns→/bootstrap is Step 17. Riverpod (§1.7 step 7) deferred — project still uses plain `setState`/`ChangeNotifier`. |
| 15 | 2026-08-30 | abc9bf3 | `agent.py`: `input_audio_transcription`/`output_audio_transcription` set explicitly (`types.AudioTranscriptionConfig`); `relay_transcripts()` publishes Gemini Live's native transcription to the room data channel as `user_transcript`/`agent_transcript` `{text,is_final}` events. `session.start` sets `RoomOutputOptions(transcription_enabled=False)` — **deviation:** one delivery path (named data events) instead of also the framework transcription stream; §1.7's "data-channel events" wording predates livekit-agents' built-in forwarder, intent unchanged. Offline tests cover config + relay. Redeployed `ayma-agent` rev `ayma-agent-00004-2r5`, `registered worker` confirmed. Live event flow needs a voice client (Step 16). |
| 16 | 2026-08-30 | b83a1f2 | `transcript_store.dart`: one bounded rolling `ChangeNotifier` window. `addTurn()` (typed/finalized) + `applyVoiceSegment()` (interim replaces live tail for same speaker, final freezes; speaker switch = new turn). `VoiceTransport.transcripts` stream; `LiveKitVoiceTransport` parses `DataReceivedEvent` on `user_transcript`/`agent_transcript`. `VoiceSessionController` routes segments into the same store the typed path writes. `ChatScreen` renders one `_Bubble` list from `store.turns` for both modes (non-final bubbles dimmed). 18 Flutter tests pass (`transcript_store_test` + relay test), `flutter analyze` clean; Dart-only, no APK rebuild. On-device "voice conversation shows as bubbles" still needs a device. |
| 17 | 2026-08-30 | cc20c94 | Recent-turns window sent to both entry points (§1.5). `transcript.py` shared `Turn` shape; `compose_system_prompt(recent_turns=...)` = §13.5 layer 4. `/chat` accepts `recent_turns` — **verified e2e** against deployed `ayma-api-00009-d9g` (voice-started thought answered with context). `/bootstrap` accepts optional body, attaches `{system_prompt, recent_turns}` to LiveKit room metadata (best-effort); `agent.py` `_read_room_seed()` rebuilds an `llm.ChatContext`. `ayma-agent-00005-tcr` registered. Client: `TranscriptStore.wireTurns()`, `ApiClient.chat/bootstrap` send the window. Backend 19 tests, Flutter 20 tests, analyze clean. Live voice-context seeding needs an on-device session. |
| 18 | 2026-08-30 | 86d97f1 | Barge-in: `agent.py` states `allow_interruptions=True` (no custom VAD — Gemini Live native turn-detection only, §1.7 step 9); `relay_agent_state()` publishes agent speaking/listening/thinking on the `agent_state` data topic (§1.3). `voice_transport.dart` now drives `agentSpeaking` from that authoritative signal (dropped the `ActiveSpeakersChanged` energy heuristic) — on barge-in it flips false at once, the client's cue to stop treating agent audio as playing (§1.7 step 10; LiveKit SDK/server flush the buffer). Agent 9 tests, backend 19, Flutter 20, analyze clean. `ayma-agent-00006-qbv` registered. On-device "talk over Ayma, audio stops" still pending a device. **End of Phase 2** (Steps 10–18 complete; live voice round-trip across Steps 13–18 is the outstanding on-device verification). |
| 19 | 2026-08-30 | fc7c77a | Session-end `raw_turns` persistence (§1.7 step 8). `db.py` lazy Firestore client; `post_turn.py` `persist_raw_turns()` upserts one doc per session at `users/{uid}/raw_turns/{session_id}` (`turns`, `turn_count`, `updated_at`, `merge=True`). `/chat` gains `session_id` → upserts the running window each turn; **verified e2e** (ayma-api-00010: 3-turn window written). New `POST /post-turn` for explicit session-end. `/bootstrap` puts `uid`+`session_id` in room metadata; `agent.py` collects finalized voice turns → writes via Admin SDK in a shutdown callback (`firebase-admin` added to agent image; `datastore.user` granted to Cloud Run SA; rev ayma-agent-00007). Client: `ids.newSessionId()`, `ChatScreen` one id per lifetime → `/chat` + `/post-turn` on dispose; `VoiceSessionController` persists on `stop()`. Backend 26, agent 10, Flutter 21 tests; analyze clean. |
| 20 | 2026-08-30 | 8f738bc | Wiki schema + config (§2.8 steps 1–2). `functions/bootstrap/wiki_schema.json` — page types, `page_id` convention/pattern, visibility values/defaults/rules, field contract, update rules, `raw_turns.image_refs` extension, `pending_questions` shape. `wiki_schema.py` cached loader + helpers. `docs/SCHEMA.md` living shape reference (Step 65 consolidates). No behavior change — nothing consumes it yet (ingest = Step 21); JSON ships with the next backend deploy. Backend 30 tests. |
| 21 | 2026-08-30 | bea51b8 | Wiki ingest (§2.3, §2.8 step 3). `wiki_ingest.ingest()` reads existing pages, asks Gemini (structured JSON, `gemini.generate_json`) for warranted page writes, validates against `wiki_schema.json`, upserts `users/{uid}/wiki_pages/{pageId}` (`ai_body`/`visibility`/`page_type`/`links`/`frontmatter`, `updated_at`, `source_turn_ids` ArrayUnion, `created_at` first-write only). Prompt in `prompts/wiki_ingest.md`. `/chat` + `/post-turn` schedule it via `BackgroundTasks` (best-effort). Rev ayma-api-00011. **Verified e2e:** a pottery chat created `wiki_pages/pottery` (interests / public / narrative `ai_body` / `source_turn_ids`). Backend 34 tests. |
| 22 | 2026-08-30 | 68593d4 | `add_followup_question` tool + `pending_questions` queue (§2.4, §2.8 step 5). `pending_questions.add_followup_question()` appends `users/{uid}/pending_questions/{autoId}` (`question_text`/`category`/`source`/`status`/`created_at`/`answered_at`/`target_page?`). `skills.py`: explicit `FOLLOWUP_DECLARATION` + `make_session_tool_fns(db,uid)`; `gemini.generate_reply` does manual one-round function calling (AFC can't introspect bound closures). Wired into `/chat` and `agent.py` (`function_tool`). Rev ayma-api-00013, ayma-agent-00009. **Verified e2e:** an "ask me later about my mother" message made `/chat` call the tool → `pending_questions` doc (category=relationships, source=followup). Also dropped the unused Dockerfile.agent `download-files` step. Backend 43 + agent 10 tests. |
| 23 | 2026-08-30 | fdcb498 | Skills/tools registry (§13.6): `skills.py` → `skills/` package — `skills/_base.Skill` (declaration + `bind`), `skills/followup.py`, `skills/__init__.py` `_REGISTRY`. Three views over one definition set: `session_tool_declarations()` + `make_session_tool_fns()` (text, `/chat`), `make_livekit_tools()` (voice, `agent.py` — lazy `function_tool` import so the package loads in the API venv). `agent._session_tools` now just calls the registry. Rev ayma-api-00014, ayma-agent-00010. Verified: text `/chat` invokes the registry tool e2e (`pending_questions` written); agent registers the same tool from the shared registry. Backend 43 + agent 11 tests. |
| 24 | 2026-08-30 | b457e67 | Prompt composition from the wiki (§2.3 Query, §2.8 step 4, §13.5 layer 3). `wiki_query.read_wiki_context()` compiles every page's `ai_body` (`ai_only` included — AI read path is unfiltered) into one block, sorted, 12k-char budget, read-failure-safe. `compose_system_prompt` order is now persona→wiki→recent-turns. `/chat` + `/bootstrap` inject it; voice gets it via the seed prompt. Rev ayma-api-00015. **Verified e2e:** session 1 states a dog's name + allergy → ingest writes `wiki_pages` → a fresh session (new `session_id`, empty `recent_turns`) recalls both unprompted. Backend 50 tests. |
| 25 | 2026-08-30 | b446812 | Scheduled wiki lint (§2.3 Lint, §2.8 step 6). `wiki_lint.lint_user()` → Gemini (structured) for contradiction/stale/orphan/missing_link, validated against real page ids/types, writes `lint_flags=[{type,detail,flagged_at}]` per page (recomputed whole each run; never edits `ai_body`). `config.cron_secret` (Secret Manager `CRON_SECRET`), `auth.require_cron` (constant-time `X-Cron-Secret`, fails closed). `POST /cron/lint` + Cloud Scheduler job `ayma-cron-lint` (daily 04:17 UTC). Rev ayma-api-00017. **Verified e2e:** the endpoint flags a deliberately contradictory page with an actionable detail and clears the clean one; 403 on missing/bad secret. Backend 57 + agent 11 tests. **End of Phase 4.** |
| 26 | 2026-08-30 | 1057f05 | Profile settings screen (§4.5, §4.6 step 7). `ProfileSettingsScreen` (`/settings/profile`) loads `users/{uid}/profile/main` and edits the five structured fields (name/birthdate/gender/interested_in/location; photo = Step 60). `ProfileService.readProfile()` → `ProfileData`; `updateStructuredFields()` partial-merge write of only the passed keys (never the wiki); Firestore/Storage handles made lazy for testability. Router `/settings/profile`. 23 Flutter tests (load/edit/save with merge-preservation), analyze clean. Flutter-only, no deploy. |
| 27 | 2026-08-30 | fee570d | Private wiki view (§2.1, §2.8 step 9). `WikiService` reads `users/{uid}/wiki_pages` directly; `readPrivateWiki()` = `public`+`private`, `user_edits ?? ai_body`, minus `user_hidden`. Pure `WikiService.filterPages()` unit-tested (`ai_only` never surfaced, sorted). `PrivateWikiScreen` (`/profile/wiki`) renders serif-titled narrative sections of paragraphs (markdown stripped), not a field dump; empty-state copy. 30 Flutter tests, analyze clean. `ai_only` rule enforcement is Step 66. |
| 28 | 2026-08-30 | 5abc368 | Public profile view (§2.1, §2.8 step 10). `WikiNarrativeView` shared widget (extracted from Step 27's screen); `PublicWikiScreen` (`/profile/public`) = `WikiService.readPublicWiki()` — `public` pages only, same override/hidden rules, strict subset of the private view (verified in `wiki_service_test`). 32 Flutter tests, analyze clean. |
| 29 | 2026-08-30 | 899a994 | Wiki edit UI (§2.8 step 11, §14.3). `WikiService.setUserEdit`/`hidePage`/`resetPage` write `user_edits`/`user_hidden` directly (never `ai_body`; pure payload builders unit-tested, reset via `FieldValue.delete()`). Private view gets a per-section edit sheet (rewrite / hide / reset-to-Ayma's-version) → reloads; public view has no edit affordance. **Interpretation:** built as the single inline editor (§14.3), not §2.1's separate "conversational chat-based editor". 37 Flutter tests, analyze clean. |
| 30 | 2026-08-30 | 64b55fc | Face embeddings on photo upload (§2.5, §2.8 step 7). `media_embed.embed_image_bytes()` → Vertex `multimodalembedding@001` (:predict, ADC), 1408-d; `process_media()` downloads from Storage, embeds, writes `users/{uid}/user_media/{id}` `{storage_path,context,embedding:Vector,dim,created_at}`; `find_similar_media()` = native COSINE `find_nearest` (Phase 7). `POST /media` (403 unless path under caller's `uploads/`; inline embed, 502 on fail). `config`: `image_embedding_model`/`storage_bucket`/`rate_media`. `firestore.indexes.json` + composite vector index (dim 1408). Client `ApiClient.registerMedia()`, fired best-effort from preboarding. Rev ayma-api-00019. **Verified e2e:** upload → `/media` → `user_media` doc with a 1408-d Vector. Backend 64 + Flutter 39 tests. **End of Phase 5.** |
| 32 | 2026-08-30 | e507ef1 | Turn caps (§3.3, §3.10 step 3). `turn_caps.evaluate()` — `marketing_turn_count` (10) / `interview_turn_count` (40) on `users/{uid}`; turns 1..N normal, N+1 = one nudge (marketing) / fallback-form signal (interview), N+2+ hard-refused with the counter frozen; `active` uncapped. `/chat` enforces pre-model, returns `{reply,capped,fallback_form}`; `/bootstrap` reports `turn_cap`. Client `ChatResult` + interview-fallback snackbar → `/settings/profile`. mode still the Step 6 stub (Step 34 = real derivation). Rev ayma-api-00020. **Verified e2e (marketing):** 1–10 normal, 11 nudge, 12+ refused, count frozen at 11. Backend 71 + Flutter 40. **(Phase 6 reordered per user: backend steps 32/33/34/36/37 first; 31 & 35 need on-device mic/GPS.)** |
| 33 | 2026-08-30 | 121b631 | Marketing-mode restricted prompt (§3.3). `prompts/mode_marketing.md` + `mode_interview.md`; `compose_system_prompt(session_mode=)` inserts the mode layer after the persona (§13.5 layer 2), active/unknown adds nothing. `/chat` + `/bootstrap` pass `_session_mode(uid)` (stub → Step 34). Rev ayma-api-00021. **Verified e2e (marketing):** "what does the app do" answered; "I've been lonely since my breakup, what should I do" and "my name is Jordan, remember that" both get a brief ack + redirect to Get Started — no advice, no profile collection. Backend 74 tests. |
| 34 | 2026-08-30 | f7e2062 | Real `session_mode` derivation (§3.3, §3.10 step 2). `session_mode.derive()` from auth state + profile completeness (+ an `onboarding_started` "get started" flag): full profile → active; linked/flagged/partial → interview; else marketing. `auth.require_caller` → `Caller{uid,is_anonymous,sign_in_provider}`; `/bootstrap`+`/chat` derive (was Step 6 stub). Client: `entryRouteFor(sessionMode)` + `SplashScreen` routes on `/bootstrap`; `ProfileService.markOnboardingStarted()`. Rev ayma-api-00022. **Verified e2e:** no/partial profile → interview, full → active; marketing via unit tests. Backend 79 + Flutter 44. |
| 36 | 2026-08-30 | 91caeae | Account delete & recover (§3.6, §3.10 steps 8–9). `account_ops.soft_delete()` copies `users/{uid}` (doc + all subcollections) + `uploads/{uid}/*` Storage into `deleted_accounts/{uid}` (`deleted_at`), removes the live copies; `recover()` reverses it; Auth account untouched. `POST /account/delete` + `/account/recover` (409 if nothing); `/bootstrap` → `{recovery_required}` before token mint. Client: `deleteAccount`/`recoverAccount`, `RecoveryScreen` (`/recover`), splash routes on the flag. Rev ayma-api-00023. **Verified e2e:** delete quarantines everything incl. Storage; `/bootstrap` flags recovery; recover fully restores. Backend 87 + Flutter 48. |
| 37 | 2026-08-30 | 385cfb8 | Purge job + admin claim (§3.6, §5.5, §3.10 steps 10–11). `account_purge.purge_expired()` sweeps `deleted_accounts/*` and permanently removes anything past `account_recovery_days` (Firestore subtree + quarantined Storage + Firebase Auth account). `POST /cron/purge-deleted` + Cloud Scheduler `ayma-cron-purge` (daily 04:42 UTC). `auth.require_admin` (admin:true custom claim, §3.5); `scripts/set_admin.py` grant/revoke. Rev ayma-api-00024. **Verified e2e:** an expired quarantine is fully purged incl. the Auth account. Backend 90 tests. **End of Phase 6 backend cluster; Steps 31 (voice preboarding) & 35 (location) done next, code-only.** |
| 35 | 2026-08-30 | 38ef121 | Location auto-detect (§4.3, §4.6 step 5). `LocationService.detectCity()` — Geolocator permission → low-accuracy fix → `geocoding` reverse-lookup → "City, Country"; `null` on failure → typed/voice fallback. Preboarding "Use my current location" button. `geolocator`/`geocoding` deps; Android/iOS location perms; `minSdk` 23→24; APK build green. Pure `formatPlacemark()` unit-tested. **Code-only per user — on-device grant/fill pending.** |
| 31 | 2026-08-30 | 38ef121 | Voice-driven preboarding (§3.3, §4.2, §4.6 step 4). `skills/set_profile_field.py` — registered agent tool writing one validated field to `users/{uid}/profile/main` (gender / interested_in normalised); `mode_interview.md` tells Ayma to call it per answer. `ProfileService.watchProfile()` stream; `PreboardingFlowScreen` mic button + live listener autofills each control as writes arrive, never overwriting the user's own input. Deployed with Step 35 (shared screen). Tests: `set_profile_field` (4), autofill + user-edit-wins (2). **Code-only per user — live voice flow pending a device.** |
| 38 | 2026-08-30 | 08d73c5 | `pair_key.sorted_pair_key(a,b)` → `{lo}__{hi}` (order-independent), `uids_from_pair_key()` inverts. For `matches/{matchId}` + `dm_threads` (§9.4, §5.9, §6.10). 3 tests. |
| 39 | 2026-08-30 | 3edb849 | Matching schema (§5.10 step 1). `matching_schema.py` — status lifecycle (`scored`/`mutual_interest`/`unmatched`/`blocked`), trust-flag types, collection names, `block_id()`. `docs/SCHEMA.md` shapes for `match_candidates`/`matches`/`blocks`/`trust_flags`. No behavior. |
| 40 | 2026-08-30 | 87cf14d | Candidate sourcing + Pass-1 heuristic scorer (§5.1, §5.2). `matching.source_and_score()` — bounded `users` scan, filters on community + mutual orientation (`orientation_match`) + block/already-matched exclusions; `heuristic_score()` ranks on age gap / same-city / shared frontmatter (no LLM). Writes `users/{uid}/match_candidates/{uid}`. **Verified e2e.** Backend 101. |
| 41 | 2026-08-30 | 0651969 | Pass-2 matching skill (§5.4). `matching_skill.score_pair()` — both users' full wiki (incl. `ai_only`) + `trust_flags` → Gemini structured `{score, user_explanation:{A,B}, ai_explanation}`; score down-weighted 0.08/flag (cap 0.4), never excluded. `prompts/matching_skill.md`. Backend 103. |
| 42 | 2026-08-30 | 11f4daa | `POST /run-matching` (Pass 1, full pool → `match_candidates`) + `POST /check-compatibility {other_uid}` (Pass 2 → upserts `matches/{sorted_pair_key}` with score/explanations/status). Rev ayma-api-00026. **Verified e2e:** two aligned wikis → score 0.9, sensible per-user explanations, match doc persisted. Backend 107. |
| 43 | 2026-08-30 | a84382f | Scheduled matching cron + trust flags (§5.3, §5.5). `trust_flags.add_trust_flag()` (deduped, known types); `wiki_lint` feeds contradiction lint-flags → `self_contradiction` trust flags. `matching_cron.run()` — per user Pass 1 then Pass 2 on top-K, upserts `matches/{id}`. `POST /cron/match` + Cloud Scheduler `ayma-cron-match` (05:07 UTC). Rev ayma-api-00027. **Verified e2e:** 41-vs-26 wiki → trust flags; `/cron/match` writes a scored match for a seeded pair. Backend 109. |
| 44 | 2026-08-30 | 1ddd78f | Blocking + `viewing_profile_uid` (§5.6, §5.10 steps 9-11). `POST /block` writes a blocks doc (sourcing already excludes blocked pairs). `/chat` `viewing_profile_uid` pulls that pair's `matches` doc `ai_explanation` in as §13.5 layer 5 (steer, don't state). Client `ApiClient.block()`, `ChatScreen.viewingProfileUid`. Rev ayma-api-00028. **Verified e2e:** block drops the candidate from `run-matching`; chat steers toward the private read without revealing it. Backend 112 + Flutter 52. |
| 45 | 2026-08-30 | 1edb4f2 | Matches UI (§5.8, §14.3). `POST /match/id/respond` (participant-only; reject→unmatched, accept→`accepted_by`+= then `mutual_interest` once both). Client `MatchService.watchNewMatches()` (matches array-contains uid + status scored, resolves other name), `MatchesScreen` cards (name/score%/your explanation) → `MatchDetailScreen` (Pass/Accept). Route `/matches`, matches composite index. **Verified e2e:** reject→unmatched; both-accept→mutual_interest; non-participant 403. Backend 115 + Flutter 55. **End of Phase 7.** |
| 46 | 2026-08-30 | 3586f14 | Explore/DM schema (§6.11 step 1). `dm_schema.py` — `thread_id()` (=`sorted_pair_key`), collections, message types. SCHEMA.md: `dm_threads`/`messages`/`explore_passed`. No behavior. |
| 47 | 2026-08-30 | 50996d1 | Photo-derived attributes + Explore filter schema (§6.3, §6.11 steps 2–3). `explore_filter_schema.json` (structured + 8 photo attrs, enum, "unknown" first-class). `photo_attrs.extract_attributes()` Gemini vision → map (failure=all unknown); `gemini.generate_json(image=)`. `/media` (context=profile) merges attrs into `profile.photo_attrs`. Rev ayma-api-00030. **Verified e2e.** Backend 118. |
| 48 | 2026-08-30 | 0660ec8 | `GET /explore` + Explore feed UI (§6.1, §6.2, §6.11 steps 4–6). `explore.explore()` — user scan, base eligibility (community + mutual orientation, minus blocks/passed), structured + photo-attr filters, score overlay from matches/candidates. `parse_nl_query()` = one Gemini call → filter shape; dropdown wins. Client `ExploreScreen` (debounced NL search + hair chips + cards). Rev ayma-api-00031. **Verified e2e:** feed + `hair_color`/`glasses` filters narrow correctly. Backend 123 + Flutter 56. |
| 49 | 2026-08-30 | 2b5f88a | Like/pass + profile share (§6.5, §6.7). `dm_ops.post_message()`/`ensure_thread()` (sorted-pair `dm_threads` + messages; blocked pairs refused). `POST /explore/like` (reciprocal → `matches` status `mutual_interest`), `/explore/pass` (marker), `/profile/share` (`shared_profile` message). Client Pass/Like buttons. Rev ayma-api-00032. **Verified e2e:** reciprocal likes → mutual_interest; pass marker; shared_profile message written. Backend 128 + Flutter 56. |
| 50 | 2026-08-30 | 77683a7 | DM thread UI + send (§6.6, §6.11 step 9). `POST /dm/threadId/messages {type,body}` (participant-only; photo/voice path must be own uploads). `firestore.rules`: participant-scoped `dm_threads`/messages + `matches` reads. Client `DmService` + `DmThreadScreen` (`/dm/:threadId`, bubbles per type, composer). Rev ayma-api-00033, rules deployed. **Verified e2e:** all 4 message types stored; non-participant 403. Backend 131 + Flutter 57. |
| 51 | 2026-08-30 | a5ef9f8 | DM ingestion into the wiki (§6.8, §6.11 step 10). `dm_ingest.ingest_dm_message()` — every DM message → `raw_turns` for both participants + a wiki pass for both. Text verbatim; photo → Gemini vision caption (+ face-embed still runs); voice → transcript. DM-image/-voice derived content forced `visibility: ai_only` via new `force_visibility` param on `wiki_ingest.ingest()`. `shared_profile` skipped. Runs as a background task in `POST /dm/{thread_id}/messages`. Rev ayma-api-00034-2h6. **Verified e2e:** text DM produced a wiki page for both participants tagged `dm-*` in `source_turn_ids`; `raw_turns` written for both. Photo→`ai_only` forcing covered by `test_dm_ingest.py`. Backend 134 + Flutter 57. |
| 52 | 2026-08-30 | bd8212f | Block/report from DM + icebreakers (§6.5, §6.9, §6.11 step 11). `icebreakers.suggest()` — up to 4 opener chips derived on demand from `matches/{matchId}` `ai_explanation` + caller's `user_explanation` (one Gemini call; no matches doc → no chips). New `GET /dm/{thread_id}/icebreakers` (participant-only). `POST /block` also sets `hidden_for: ArrayUnion([blocker])` on the pair's `dm_threads` doc; `DmService.watchThreads` filters those; blocked sends both ways already 403 via `dm_ops`. Client: chip bar above the composer, "Block & report" overflow action + confirm. Rev ayma-api-00035-cxs. **Verified e2e:** compat check → per-user grounded chips; non-participant 403; block sets `hidden_for`; blocked side 403 on send. Backend 140 + Flutter 59. |
| 53 | 2026-08-30 | 0282cdc | Real 4-tab main shell (§11.3, §11.6 step 3, §14.3) — replaces the Step 4 placeholder. `MainShellScreen` = `NavigationBar` (Ayma / Explore / Messages / Profile), shell-owned `TranscriptStore` + `VoiceSessionController` handed to the Ayma tab so the voice session + `AymaOrb` glow survive tab switches; tabs lazy-built + kept alive. New: `MessagesScreen` (mutual matches + DM threads unified, every row → `/dm/:threadId`; `MatchService.watchMutualMatches()`), `ProfileTabScreen` (hub), `AymaOrb` + `NotificationBellButton` widgets, `NotificationCenterScreen` placeholder at `/notifications` (list/prefs = Step 57). Client-only; `flutter analyze` clean, Flutter 61. **On-device tab-bar navigation pending real-device verification.** |
| 54 | 2026-08-30 | 194b281 | Notification schema + FCM registration (§7.8, §7.9 steps 1–2). `notifications_schema.py` (category constants, `default_prefs()`), `notifications_ops.py` (`register_token`/`unregister_token` — ArrayUnion/Remove, trimmed to `MAX_FCM_TOKENS`; `read_prefs`/`set_pref`). `POST /notifications/token` + `/token/remove`. Config: `notifications_limit`, `push_preview_len`, `push_cooldown_seconds`, `max_fcm_tokens`, `rate_notifications`. Client: `firebase_messaging`, `PushService` (FcmTokens seam) — permission → register → re-register on refresh; `clearToken()` on sign-out; wired in `main()` + Profile tab. Backend 150 + Flutter 65. Rev ayma-api-00036-2p2. **Verified e2e:** token register (idempotent) + remove reflected in `fcm_tokens`. On-device APNs/FCM delivery pending real device. |
| 55 | 2026-08-30 | 31bb3fa | Dispatch helper + DM/mutual-match/cron-digest triggers (§7.1, §7.9 steps 3–6). `notifications_dispatch.dispatch()` — prefs gate (muted → nothing written), durable `notifications/{id}` doc, §7.5 per-user push cooldown (doc always written), FCM multicast + dead-token pruning + `last_push_at`. `notifications_triggers`: `notify_new_dm` (suppressed inside `dm_viewing_window_seconds` of the recipient's `last_read_at`; `dm_thread/{id}` deep link), `notify_mutual_match` (both users, `profile/{other}`), `notify_new_scored_matches` (one digest per cron run per user, `matches` deep link). Wired into `POST /dm/*/messages`, `/explore/like`, `/match/*/respond`, `matching_cron.run`. config: `dm_viewing_window_seconds`. Backend 162. Rev ayma-api-00038. **Verified e2e:** DM → recipient doc (deep link, unread, truncated); read-cursor suppression; reciprocal likes → `mutual_match` both; muted category → no doc. Real FCM delivery pending a device token. |
| 56 | 2026-08-30 | 6e1d470 | Re-engagement cron (§7.1, §7.9 step 7). `reengagement.run(db)` — for each user idle ≥ `reengage_inactive_days` (3) and past their backoff window, Ayma writes ONE `raw_turns` message: a profile-share (strong unacted-on match → `profile/{other}`) or a wiki-composed personalised check-in (one Gemini call → `chat`), plus an `ayma_checkin` push. Backoff `backoff_days` doubles 7→14→28 after each send, resets when `last_active_at` passes `last_sent_at`. `_persist_session` now stamps `users/{uid}.last_active_at` (chat/post-turn/bootstrap only). `POST /cron/reengage`; Cloud Scheduler `ayma-cron-reengage` (daily 05:20 UTC). config: `reengage_*`, `rate_cron_reengage`. Backend 169. Rev ayma-api-00039-7bj. **Verified e2e:** idle user → wiki-grounded Ayma `raw_turns` + `ayma_checkin` doc + `reengagement` state (backoff 7); immediate re-run sends nothing. Real FCM delivery pending a device token. |
| 57 | 2026-08-30 | 086c632 | Notification centre UI + preferences (§7.9 steps 8–9). `NotificationService` (client-direct Firestore, owner-scoped): `watch()` (newest 50), `watchUnreadCount()`, `markRead`/`markAllRead`, `readPrefs`/`setPref`, `deepLinkToRoute` (§7.6: `dm_thread/{id}`→`/dm/{id}`, `profile/{uid}`→`/dm/{sorted-pair}`, `matches`→`/matches`, else `/`). `NotificationCenterScreen` — typed list, unread dots, opening marks all read, row tap → `markRead` + `context.go`. `NotificationPrefsScreen` — switch per category → `notification_prefs/main` (same doc dispatch checks). `NotificationBellButton` now stateful with the unread badge, degrades gracefully without Firebase. Routes `/notifications`, `/notifications/prefs`. Flutter 71, analyze clean. Client-only; mute→no push/no doc already e2e-verified in Step 55. |
| 58 | 2026-08-30 | 10401a9 | Media schema + Instagram OAuth/import (§8.1, §8.2, §8.7 steps 1–2). `instagram.py`: `auth_url(state)`, `connect(db,uid,code)` — code→long-lived token on `users/{uid}.instagram_access_token`, pull ≤20 images to `uploads/{uid}/ig_{id}.jpg` + one `user_media` doc each (`source:instagram_import`, `moderation_status:pending`) + username/captions → one `raw_turns` entry; `disconnect` DELETE_FIELDs the token (photos stay). App secret read from `INSTAGRAM_APP_SECRET` at call site. Endpoints `GET /instagram/auth-url`, `POST /instagram/connect|disconnect`. config `instagram_*`. Client `ApiClient.instagram*`. `SCHEMA.md` Media section (`profile.photos`, `user_media` shape). Backend 174 + Flutter 73. Rev ayma-api-00040-xsj. **Verified e2e:** 3 endpoints wired; auth-url/connect return "not configured" until a real Meta app id/secret/redirect are set — OAuth round-trip + live import **pending external creds**. |
| 59 | 2026-08-30 | c8740ba | Photo moderation + unified pipeline (§8.4, §8.5, §8.7 steps 3–4). `photo_moderation.moderate()` — Gemini vision safety, fails **closed** on error. `photo_pipeline.process(db,uid,path,source,*,wiki_uids,wiki_visibility)` — moderation → (flagged? write `user_media` `moderation_status:flagged` and stop) → face embed → attribute extraction (profile also mirrors `profile/main.photo_attrs`) → vision caption → wiki ingest for `wiki_uids` at `wiki_visibility` (DM = `ai_only`). Rewired `POST /media` (response now `moderation_status`/`published`/`reason`), `dm_ingest` photo path, `instagram._import_media` all onto it. Tests: `test_photo_pipeline.py` (5) + updated media/dm/instagram tests. Backend 180. Rev ayma-api-00041-v4k. **Verified e2e:** `/media` upload → approved+published, `user_media` with 1408-dim embedding + attributes + caption, `profile.photo_attrs` mirrored. Flagged branch unit-covered. |
| 60 | 2026-08-30 | fb24653 | Photo soft-delete + management screen (§8.3, §8.7 steps 5–6). `photo_ops`: `add_photo` (needs a matching `user_media` doc, dedup, ≤9), `remove_photo` (**soft** — array entry only; `user_media`/Storage/embedding/wiki all stay), `reorder_photos`, `list_photos`. Endpoints `GET/POST /media/photos`, `POST /media/photos/{id}/remove`, `PUT /media/photos/order`. `/media` now returns `media_id`/`moderation_status`/`published`/`reason` → `MediaResult`. Client: `PhotoService` (resolves `media_id`→download URL; lazy `_api`), `PhotoManagementScreen` at `/settings/photos` (reorderable list, soft-delete, image_picker upload through pipeline with flagged-reason toast, Instagram connect via `url_launcher`), Profile-tab link, preboarding adds photo 0. deps: `url_launcher`. Backend 184 + Flutter 75. Rev ayma-api-00042-5r4. **Verified e2e:** add→grid grows; reorder renumbers; remove→gone from grid but `user_media` doc + embedding intact. On-device grid/drag/picker/IG launch pending real device. |
| 61 | 2026-08-30 | fd5384b | `set_voice_preference` tool + settings picker (§13.3, §13.8 steps 4–5). `voices.py` = fixed Gemini Live preset set + descriptions. `skills/set_voice_preference.py` (registered; voice+text) keyword-maps the request → closest preset, writes `profile/main.ayma_voice_name`, says "next session". `build_room_seed`/`/bootstrap` (`_ayma_voice_name`) carry it on the room seed; `agent._read_room_seed`→`RoomSeed.voice_name`; `build_realtime_model(voice_name)` uses it when valid else `CONFIG.gemini_live_voice`. `GET /voice/presets`. Client `VoicePreferenceScreen` at `/settings/voice` + Profile-tab link, `ProfileService.setVoicePreference`. Backend 189 + agent 14 + Flutter 76. Rev ayma-api-00043-vp2 / ayma-agent-00012-vf2. **Verified e2e:** `/chat` "deeper masculine voice" → skill sets `ayma_voice_name=Charon`, reply says next chat; `/voice/presets` current reflects it; `/bootstrap` seeds it. Agent speaking in the new voice pending an on-device session. |
| 62 | 2026-08-30 | 1c91b89 | Settings light/dark toggle + no-hardcoded-colour pass (§14.1). `lib/theme.dart` was pulled forward (ebefb8c); this slot adds `ThemeController` (shared_preferences-backed app-wide `themeControllerGlobal`; `main()` awaits `load()`, `AymaApp` `AnimatedBuilder`s `themeMode`), `SettingsScreen` at `/settings` (Light/Dark/Match system) + Profile-tab link. Colour audit: only `Colors.red` (preboarding age warning) → `AymaColors.error`; everything else already token-routed. deps `shared_preferences`. Flutter 78, analyze clean. Client-only; full light/dark screen walkthrough pending a device. |
| 63 | 2026-08-30 | 2cd082c | `paused` field + wiki reset (§14.2, §14.4 steps 2–3). `paused` bool on `profile/main` → `explore.explore` and `matching.source_and_score` skip paused profiles. `POST /wiki/reset` clears `wiki_pages`/`raw_turns`/`pending_questions` for the caller; account/profile/auth untouched. Client: `ProfileService.watchPaused`/`setPaused`, `ApiClient.resetWiki`, Settings "Matching" section (pause switch + "Wipe what Ayma has learned" confirm). Backend 191 + Flutter 80. Rev ayma-api-00044-m8w. **Verified e2e:** paused user drops out of another's Explore feed; `/wiki/reset` empties the 3 learned collections, account + profile survive. |
| 64 | 2026-08-30 | 4cb2b49 | Full screen design pass (§14.1, §14.4 step 4). Design system (pills, hairline borders, orb, `elevation:0`) already global via `theme.dart`; this adds the missing staggered fade/slide entrance: `lib/widgets/staggered.dart` `FadeSlideIn` (opacity+12px slide, easeOutCubic, per-item `delay`) + `staggerDelay(i)` (40ms ramp/320ms cap), applied to every content list itemBuilder (Explore, Messages, Matches, Notifications, DM bubbles, Profile rows). No stray shadows outside `AymaOrb`. Tests: `staggered_test.dart` (2). Flutter 82, analyze clean. Client-only; full visual walkthrough is a device check. |
| 65 | 2026-08-30 | d004158 | Consolidated schema module + composite indexes (§9.5 steps 1, 4). `functions/bootstrap/schema.py` — one import for every collection-path / profile-field / user-metadata-field constant plus re-exports of the per-domain schema modules and `user_doc`/`profile_doc`/`user_subcollection` helpers; adopted in `main._ayma_voice_name`/`wiki_reset` and `photo_ops`. `firestore.indexes.json` — added `matches` (uids+status+score DESC), `dm_threads` (participants+last_message_at DESC), `notifications` (read+created_at DESC); deployed, all 11 indexes READY. Tests: `test_schema.py` (3). Backend 194. Rev ayma-api-00045-97k. **Verified e2e:** Explore / run-matching / voice-presets / media-photos all 200 (no missing-index); dm_threads-by-last_message_at + matches-by-score server queries resolve. |
| 66 | 2026-08-30 | 9165ba7 | Final security rules pass — two-tier ownership boundary (§9.2, §9.5 step 3). `firestore.rules` per-collection: `users/{uid}` doc write ⊆ {onboarding_started, updated_at}; `profile/main` write ⊆ user-editable fields (no photos/photo_attrs/community); `wiki_pages` read excludes `ai_only`, update ⊆ {user_edits, user_hidden, user_updated_at}; `notifications` update ⊆ {read}; `notification_prefs` full owner r/w; `raw_turns`/`user_media`/`pending_questions`/`match_candidates`/`likes`/`explore_passed` owner-read-only; everything else denied. Client: `WikiService._read` constrains to visibility∈[public,private]; `savePreboarding` drops the `photos` write (goes via `/media`). Rules deployed. Flutter 82. **Verified e2e (client ID token vs Firestore REST):** allowed — prefs write, mark-read, wiki `user_edits`, profile name/paused, private-wiki read; denied 403 — wiki `ai_body`, `users.session_mode`, profile community/photos, `ai_only` read, `raw_turns`/`matches`/`blocks` write. |
| 67 | 2026-08-30 | 1d0914b | Rate limits on every endpoint (§10.4, §10.6 steps 2–4). `ratelimit.py` — in-process fixed-window ASGI middleware; resolves each path to its `RATE_*` by longest configured prefix, unmatched → `CONFIG.rate_default`; over limit → 429 + `Retry-After`. config: `rate_explore`/`rate_block`/`rate_profile_share`/`rate_dm_send`/`rate_cron_match`/`rate_wiki_reset`/`rate_voice`/`rate_default`. `ratelimit.ENABLED` off in conftest. Cron auth (`Depends(require_cron)`, constant-time, fails closed) already on every `/cron/*`. Tests: `test_ratelimit.py` (4). Backend 198. Rev ayma-api-00046-z2x. **Verified e2e:** `/voice/presets` (30/min) → 30×200 then 429 from req #31; `/cron/match` no secret → 403; `/cron/reengage` wrong secret → 403. |
| 68 | 2026-08-30 | 900e9a2 | Admin console (§14.3). `auth.require_admin_password` (`X-Admin-Password` vs `CONFIG.admin_password`, constant-time, fails closed). `admin.py`: `search_users` (exact-uid + bounded name-substring scan), `user_detail` (account, profile, wiki_pages incl. `ai_only`, matches, dm_threads, trust_flags, deleted_accounts lookup) — all Admin SDK. `GET /admin/users?q=` + `GET /admin/users/{uid}`. Client: `ApiClient.adminSearchUsers`/`adminUserDetail`, `AdminScreen` at `/admin` (password unlock → search → per-collection JSON detail), Settings link. Infra: `ADMIN_PASSWORD` Secret Manager secret + accessor role, mounted at deploy; noted in `LOCAL_DEV_NOTES.md`. Tests: `test_admin.py` (5), `admin_screen_test.dart` (1). Backend 203 + Flutter 83. Rev ayma-api-00047-wtk. **Verified e2e:** no/wrong password → 403; name search returns the user; detail renders wiki (`ai_only` visible), matches, dm_threads, trust_flags. |
| 69 | 2026-08-30 | 7959d53 | Secret Manager for every credential (§12.3). Audit close-out: `ayma-api` secrets = LIVEKIT_API_KEY/SECRET, CRON_SECRET, ADMIN_PASSWORD, + new INSTAGRAM_APP_SECRET (placeholder v1 until a Meta app exists); `ayma-agent` = LIVEKIT_API_KEY/SECRET. Gemini via Vertex runtime identity (no key), Firebase Admin via runtime identity (no key file). Plain env vars are non-secret config only. New `docs/deploy.md` runbook (secret inventory + grant/rotate + full deploy commands + rules/indexes/cron). Rev ayma-api-00048-wft. **Verified:** post-deploy env audit → 0 plaintext secret leaks (all 5 credentials `secretKeyRef`); `/health` 200. |
| 70 | 2026-08-30 | 96e70bb | Two-service Cloud Run deploy config (§10.1, §12.2). `ayma-api` pinned `--min-instances 0 --max-instances 4 --cpu 1 --memory 512Mi`, default CPU throttling → `minScale` annotation absent ⇒ scales to zero (rev ayma-api-00049-q6g, `/health` 200). `ayma-agent` min 0 / `--no-cpu-throttling` (Step 13 deviation) / 2Gi / max 20 — worker registers with LiveKit when an instance runs; with min 0 none is connected while idle, so the always-on flip + full voice round-trip are Step 72 / on-device. Config table recorded in `docs/deploy.md`. |
| 71 | 2026-08-30 | aba54d4 | Deploy scripts + `docs/agent.md` (§12.6 step 3). `scripts/deploy-api.sh` (code-only default; `--full` sets env+secrets; pins §12.2 scale flags), `scripts/deploy-agent.sh` (builds the split image then deploys; `--full` env/secrets; `--release` = min-instances 1), `scripts/deploy-all.sh` (rules+indexes+both services). `docs/agent.md` — worker responsibilities, deploy commands, `--no-cpu-throttling` requirement, secrets, tests, log verification. **Verified:** `scripts/deploy-api.sh` → ayma-api-00050-pw6 (`/health` 200); `scripts/deploy-agent.sh` → image build + ayma-agent-00013-sp6, both serving 100%. |
| 72 | 2026-08-30 | 9aa9a6a | Pre-release flip (§12.2) — `ayma-agent` `min-instances 0 → 1` (`--no-cpu-throttling` kept). Always-warm instance; LiveKit worker permanently registered → no cold start on the first voice connection (closes the Step 70 gap). **Verified:** `minScale=1`, `cpu-throttling=false`; agent logs `HTTP server listening :8080` → `plugin registered` → `starting worker` → `registered worker`, steady. Full mic round-trip still needs a device. Revert to `--min-instances 0` to pause agent billing pre-launch. **Final step — all 72 complete.** |

---

*This is the full build sequence — 72 steps across 13 phases. Every step cites its full spec in `rewrite-architecture.md`. Do not skip the test-and-confirm gate on any step.*
