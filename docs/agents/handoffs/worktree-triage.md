# Worktree Triage — full report (from Muse)

Date: 2026-10-31. Scope: READ-ONLY — nothing deleted, merged, pruned, or fetched.

Refs at analysis time (no fetch performed, per read-only rule):
- `origin/main` = `9622966` (2026-10-30, "Merge pull request #1 from suhailps93/meta-hackathon")
- local `main` = `b6af7ce` (2026-10-28) — ancestor of `origin/main`; `origin/main` is 256 commits ahead of local `main`
- "Merged" below means HEAD is an ancestor of `origin/main` unless noted.

## Summary counts (127 registered worktrees, all covered)

| Class | Count | Meaning |
|---|---|---|
| SAFE-DELETE | 105 | Merged into `origin/main` (or patch-identical) AND clean: 104 + `connect-agent-instructions` (cherry-pick-equivalent, see note) |
| REVIEW | 7 | Clean but has unmerged commits (one-line summaries below) |
| DIRTY | 11 | Uncommitted changes (7 active/KEEP, 4 legacy need a decision) |
| PRUNE-READY | 4 | Directory gone (`/tmp/...`, `git worktree list` already flags prunable); metadata only |

Plus 2 loose dirs that are NOT worktrees (separate standalone repos, out of scope): `~/workspace/ayma-godmode`, `~/workspace/ayma-meta-hackathon-extract` (details at bottom).
No unregistered loose dirs under `.claude/worktrees` (116 dirs on disk = 116 registered). 21 worktrees are on detached HEAD.

Suggested deletion order for whoever executes: (1) `git worktree prune` for the 4 PRUNE-READY, (2) remove the 104 clean-merged + `connect-agent-instructions` worktrees (branches `deploy-candidate` etc. stay until branches are deleted separately), (3) decide the 7 REVIEW + 4 legacy-DIRTY items below. Active fleet worktrees and the main checkout are KEEP.

## REVIEW — clean, unmerged commits (7)

All except `appearance-single` are pushed to `origin` under the same branch name, so removing the worktree would not lose the branch.

1. `agent-a0381d6ff591cf768` / `per-sentence-suggestions` @ `6f989b6` (2026-10-26, 1 commit): profile banner ChromeColumn overflow fix — NOTE: same subject already in main as `e79a485` but `git cherry` = `+` (different patch); verify the fix exists in main, then likely delete.
2. `agent-a543353656f3bc559` / `fix/explore-show-everyone-no-age-gate` @ `51d2d56` (2026-10-30, 1 commit): Explore backend — show-everyone default + paginated bounded-read feed + mode=matches (`explore.py` + tests).
3. `agent-a774de70e0c2a40fa` / `deploy-candidate` @ `857e01f` (2026-10-25) **and** `agent-a827cd6e04414da7c` / `fix-inference-voice-context` @ `857e01f` — SAME HEAD, one decision covers both worktrees: pin Google voice `tool_behavior` to BLOCKING + livekit-agents 1.8.9 agent-image build reqs.
4. `agent-a873a6aa0aee521e0` / `fix/explore-filter-and-pagination-ui` @ `759b2ca` (2026-10-30, 1 commit): Explore UI — Everyone/Potential-matches mode control + infinite-scroll pagination.
5. `agent-a8bd3d43a05b0d832` / `public-repo-prep` @ `5b4fefd` (2026-10-26, 1 commit): standalone public-repo candidate under `export/ayma-practice-date` — likely superseded (Qloo submitted Oct 30; `ayma-practice-date` repo exists); verify, then delete.
6. `appearance-single` / (detached HEAD) @ `6760599` (2026-10-29, 1 commit): test-only fix — fake AymaPhoto cache manager (`flutter_test_config.dart` + `ayma_photo.dart` tweak). **ORPHAN RISK: no branch or tag contains this commit and the file is absent from `origin/main` — tag/branch it before any removal; then merge-or-drop on content.**
7. (Also unmerged but dirty — see DIRTY/KEEP: `integrate-2218`, 24 commits e2e harness; `privacy-test`, 1 commit privacy pack.)

SAFE-DELETE* note: `connect-agent-instructions` @ `97216a2` is HEAD-not-ancestor but `git cherry origin/main` = `-`: its content was cherry-picked into `origin/main` as `24e56f8` ("Integration 2218: cherry-pick connect-agent-instructions"). Content-safe to delete.

## DIRTY — uncommitted changes (11)

### KEEP — main checkout + active work (7, do not delete)

- `~/workspace/ayma` (`main`, HEAD merged, 8 dirty): `M docs/TODO_QUEUE.md`; untracked scaffolding `.claude/`, `.codex/`, `.fleet-worktrees/`, `CLAUDE_TO_MUSE_HANDOFF.md`, `ayma_flutter/android/key.properties.bak`, `ayma_flutter/tool/render_orb_lit_transparent_test.dart`, `docs/HACKATHON_PLAN.md`.
- `integrate-2218` (`test/e2e-integration-harness`, 1 dirty + 24 unmerged, pushed): `M docs/TODO_QUEUE.md`; unmerged = Oct 29–31 e2e integration harness (GATES/B sweeps, DM GIF scenario, scroll fixes, HTML report). Active test branch — KEEP.
- `.fleet-worktrees/privacy-test` (`test/privacy-extraction`, 2 untracked + 1 unmerged, pushed): `TASK.md`, `docs/agents/CONTEXT_PACK.md`; unmerged = Oct 31 privacy-extraction 25-prompt fishing pack + runner. Active fleet task — KEEP.
- `.fleet-worktrees/explore-tiles` (`fix/explore-blank-tiles`, 2 untracked, HEAD merged): `TASK.md`, `docs/agents/`. Active fleet task — KEEP.
- `.fleet-worktrees/sanitizer` (`fix/reports-key-sanitizer`, 2 untracked, HEAD merged): `TASK.md`, `docs/agents/`. Active fleet task — KEEP.
- `.fleet-worktrees/staging-config` (`feat/staging-build-config`, 7 dirty, HEAD merged): `M env.dart`, `M main_shell_screen.dart`, `M nav_bar_shell.dart`; new `staging_banner.dart`, `env_staging_test.dart`; `TASK.md`, `docs/agents/`. Active WIP — KEEP.
- `.fleet-worktrees/triage` (`chore/worktree-triage`, 2 untracked, HEAD merged): `TASK.md`, `docs/agents/`. THIS task's worktree — KEEP.

### Legacy dirty — needs a salvage-or-drop decision (4)

- `agent-ad91dbd1cfaf01368` (`fix/no-match-notif-for-dealbreakers`, 4 dirty, HEAD merged): `M docs/ARCHITECTURE.md`, `M docs/TODO_QUEUE.md`, `M functions/bootstrap/matching_cron.py`, `M functions/bootstrap/tests/test_matching_cron.py`.
- `agent-ae983fecf0be05bdc` (detached @ `3109ce0`, 18 dirty, HEAD merged): **has an unresolved merge conflict (`UU ayma_flutter/lib/routing/app_router.dart`)** plus age-gate/account-deletion WIP (new `underage_screen.dart`, `age_gate.dart`, `age_gate_test.dart`; modified preboarding/profile/sign-in/splash screens, api_client, profile_service). Needs human review.
- `datesim-continue` (detached @ `cd1927b`, 8 dirty, HEAD merged): date-sim changes (`date_sim_screen.dart`, `api_client.dart`, `date_sim.py`, `prompts/date_sim.md` + tests, `ARCHITECTURE.md`) + new `prompts/date_sim_lowcontext.md`.
- `tour-fix` (detached @ `78887ca`, 8 dirty, HEAD merged): tour/coach-mark changes (`tour_anchors.dart`, `tour_content.dart`, `coach_mark_overlay.dart` + test, `profile_tab_screen.dart`) + docs (`ARCHITECTURE.md`, `HACKATHON_STATUS.md`, `TODO_QUEUE.md`).

## PRUNE-READY — directory gone, metadata only (4)

Safe for `git worktree prune` (read-only task: not executed). Local branches survive pruning; delete separately if wanted.

- `/tmp/.../scratchpad/storyfix` (`metafix-storyedit` @ `530d92a`, 2026-10-28 "fix(story): guard edit_story_entry against whole-section overwrite") — merged into `origin/main`; local branch still exists.
- `/tmp/.../scratchpad/wt-dupprop` (`fix-dup-proposals-wt` @ `99a9f08`, 2026-10-28 "fix(profile): stop pinned re-append duplicating reworded facts") — merged; local branch still exists.
- `/tmp/.../scratchpad/wt-taste` (detached @ `60272c4`, 2026-10-28 "feat(questionnaire): ask taste early...") — contained in live branches (e.g. `demo/seed-accounts`, `fix/appearance-multi-photo-analysis`).
- `/tmp/pubprep` (detached @ `5b4fefd` = `public-repo-prep` HEAD, pushed to origin).

## Loose dirs that are NOT worktrees (2, out of scope)

- `~/workspace/ayma-wt-appearance` IS a registered worktree (`meta-hackathon-appearance`, clean, merged) → counted in SAFE-DELETE above.
- `~/workspace/ayma-godmode`: standalone repo (no remote), `master` @ `c08b8f8` (2026-09-06, "Ayma God Mode: read-only ops console"), clean. Not a worktree of this repo — no action.
- `~/workspace/ayma-meta-hackathon-extract`: standalone repo, own origin (`suhailps93/ayma-meta-hackathon`), `main` @ `c353559` (2026-10-27), clean. Not a worktree of this repo — no action.

## Full table — all 127 registered worktrees

Columns: branch (`HEAD` = detached), anc = HEAD ancestor of `origin/main`, dirty = uncommitted file count, un = commits in HEAD not in `origin/main`.

| # | path | branch | anc | dirty | un | last commit | class |
|---|---|---|---|---|---|---|---|
| 1 | `~/workspace/ayma` | main | yes | 8 | 0 | 2026-10-28 / docs(queue): record Agent Dates positioning wording conflict as founder decision (Nov 3 freeze) | DIRTY |
| 2 | `~/workspace/ayma-wt-appearance` | meta-hackathon-appearance | yes | 0 | 0 | 2026-10-28 / fix(appearance): run a fresh analysis on explicitly-selected photos, not the reused old report | SAFE-DELETE |
| 3 | `~/workspace/ayma/.claude/worktrees/accent` | accent-work | yes | 0 | 0 | 2026-10-27 / Voice: free-text ACCENT field + accent-switch messaging; fix cascade cold-start on stale seeded turn | SAFE-DELETE |
| 4 | `~/workspace/ayma/.claude/worktrees/agent-a0381d6ff591cf768` | per-sentence-suggestions | no | 0 | 1 | 2026-10-26 / fix(profile): banner uses ChromeColumn so it can't overflow | REVIEW |
| 5 | `~/workspace/ayma/.claude/worktrees/agent-a0cb457a4774118c3` | fix/agent-empty-messages-400 | yes | 0 | 0 | 2026-10-29 / fix(agent): seed a user turn on cascade proactive greeting/opener (Sentry inference 400) | SAFE-DELETE |
| 6 | `~/workspace/ayma/.claude/worktrees/agent-a14013da2f84d8498` | fix/voice-match-context-and-persona | yes | 0 | 0 | 2026-10-30 / fix(voice): real match score in agent context, fuzzy name open, demo persona | SAFE-DELETE |
| 7 | `~/workspace/ayma/.claude/worktrees/agent-a1828f5c2af71acf2` | fix/dm-coach-long-text | yes | 0 | 0 | 2026-10-30 / fix(dm coach): never leak model reasoning or raw JSON into the composer hint | SAFE-DELETE |
| 8 | `~/workspace/ayma/.claude/worktrees/agent-a222dd98cd34008e7` | web-research-facematch | yes | 0 | 0 | 2026-10-27 / Tighten web-research "Photos to confirm" face-match gate (config threshold) | SAFE-DELETE |
| 9 | `~/workspace/ayma/.claude/worktrees/agent-a2629272b9d263f01` | meta-voice-cascade | yes | 0 | 0 | 2026-10-26 / feat(hackathon): Practice Date voice Meta cascade behind LLM_PROVIDER_VOICE (Gemini Live stays default) | SAFE-DELETE |
| 10 | `~/workspace/ayma/.claude/worktrees/agent-a2d5e497278a43193` | taste-backfill-qloo | yes | 0 | 0 | 2026-10-29 / docs(taste): document the backfill path, triggers, weights + update diagram | SAFE-DELETE |
| 11 | `~/workspace/ayma/.claude/worktrees/agent-a308b2e5558ef5810` | HEAD | yes | 0 | 0 | 2026-10-26 / docs: voice practice deployed (api-00207-w74, agent-00112-wjk), APK 2214 | SAFE-DELETE |
| 12 | `~/workspace/ayma/.claude/worktrees/agent-a543353656f3bc559` | fix/explore-show-everyone-no-age-gate | no | 0 | 1 | 2026-10-30 / Explore done right: show-everyone default, paginated bounded-read feed, mode=matches | REVIEW |
| 13 | `~/workspace/ayma/.claude/worktrees/agent-a5e006c1b08e13930` | hack-work | yes | 0 | 0 | 2026-10-26 / docs: record hackathon merge+deploy; bump APK to 2213 | SAFE-DELETE |
| 14 | `~/workspace/ayma/.claude/worktrees/agent-a65ddb449fddfcdd0` | qloo-depth-engine | yes | 0 | 0 | 2026-10-29 / docs(qloo): enumerate full Qloo surface (depth writeup), diagram, follow-ups | SAFE-DELETE |
| 15 | `~/workspace/ayma/.claude/worktrees/agent-a682166abd372176f` | practice-ui-fixes | yes | 0 | 0 | 2026-10-26 / fix(hackathon): Practice Date UI — shared chat bubble, empty-state, restart, voice avatar | SAFE-DELETE |
| 16 | `~/workspace/ayma/.claude/worktrees/agent-a69bc973e662e7437` | demo/seed-accounts | yes | 0 | 0 | 2026-10-29 / Merge demo/seed-accounts: 3 complete demo accounts + scoped overrides | SAFE-DELETE |
| 17 | `~/workspace/ayma/.claude/worktrees/agent-a6aa360887b1b9843` | rebuild-2215 | yes | 0 | 0 | 2026-10-26 / rebuild-2215: fix 3 carousel widget tests, practice layout overflow, bump to +2215 | SAFE-DELETE |
| 18 | `~/workspace/ayma/.claude/worktrees/agent-a6f638ff2e67725bc` | fix/dealbreakers-show-not-hide | yes | 0 | 0 | 2026-10-29 / fix(match): SHOW dealbreaker profiles in Explore (not hide) + "Why this is 0%" report + cache input-staleness | SAFE-DELETE |
| 19 | `~/workspace/ayma/.claude/worktrees/agent-a743f62abbfa78e3a` | fix/taste-grounding | yes | 0 | 0 | 2026-10-29 / fix(taste): ground Qloo taste card in both-stated domains, not predictions (bug G) | SAFE-DELETE |
| 20 | `~/workspace/ayma/.claude/worktrees/agent-a749702286c65908f` | main-voice-meta | yes | 0 | 0 | 2026-10-26 / feat(agent): extend Meta Muse cascade to the MAIN voice behind LLM_PROVIDER_VOICE_MAIN (default gemini, OFF) | SAFE-DELETE |
| 21 | `~/workspace/ayma/.claude/worktrees/agent-a774de70e0c2a40fa` | deploy-candidate | no | 0 | 1 | 2026-10-25 / Pin Google voice tool_behavior to BLOCKING; agent image builds with livekit-agents 1.8.9 requirements | REVIEW |
| 22 | `~/workspace/ayma/.claude/worktrees/agent-a7fbf0a06056aa027` | fix/match-dealbreakers | yes | 0 | 0 | 2026-10-29 / fix(match): hard dealbreakers, practice-persona leak, cached reports (bugs B/E/F/H) | SAFE-DELETE |
| 23 | `~/workspace/ayma/.claude/worktrees/agent-a827cd6e04414da7c` | fix-inference-voice-context | no | 0 | 1 | 2026-10-25 / Pin Google voice tool_behavior to BLOCKING; agent image builds with livekit-agents 1.8.9 requirements | REVIEW |
| 24 | `~/workspace/ayma/.claude/worktrees/agent-a86245ba10b8794ec` | qloo-default-gemini | yes | 0 | 0 | 2026-10-29 / config: Qloo-phase app-wide default stack = Gemini (brain + main voice) | SAFE-DELETE |
| 25 | `~/workspace/ayma/.claude/worktrees/agent-a873a6aa0aee521e0` | fix/explore-filter-and-pagination-ui | no | 0 | 1 | 2026-10-30 / Explore UI: Everyone/Potential-matches mode control + infinite-scroll pagination | REVIEW |
| 26 | `~/workspace/ayma/.claude/worktrees/agent-a8bd3d43a05b0d832` | public-repo-prep | no | 0 | 1 | 2026-10-26 / chore(hackathon): prep standalone public repo candidate (ayma-practice-date) | REVIEW |
| 27 | `~/workspace/ayma/.claude/worktrees/agent-a92c9fb8599322d7e` | fix/match-report-ui-scroll-terminology | yes | 0 | 0 | 2026-10-30 / fix(match report): revert "Compatibility"→"Match report", fix Qloo-card scroll skip, de-cram match-request header | SAFE-DELETE |
| 28 | `~/workspace/ayma/.claude/worktrees/agent-a9535d4a96c695787` | worktree-agent-a9535d4a96c695787 | yes | 0 | 0 | 2026-10-26 / docs(hackathon): record voice cascade fix deploy (ayma-agent-00115-hkc) | SAFE-DELETE |
| 29 | `~/workspace/ayma/.claude/worktrees/agent-a99d7d5cd505d2edd` | submission-docs | yes | 0 | 0 | 2026-10-26 / docs(hackathon): submission package + judge-path hardening | SAFE-DELETE |
| 30 | `~/workspace/ayma/.claude/worktrees/agent-a9c3af4aa18eab654` | qloo-depth-card | yes | 0 | 0 | 2026-10-29 / docs(taste-card): note the card now surfaces shared_tags + demographics | SAFE-DELETE |
| 31 | `~/workspace/ayma/.claude/worktrees/agent-aa34fa8598001663c` | fix/feature-tour-root-overlay-v2 | yes | 0 | 0 | 2026-10-29 / Feature tour: device-verification fixes (back, nav-settle) | SAFE-DELETE |
| 32 | `~/workspace/ayma/.claude/worktrees/agent-aa4ea7ec9c75eeb2d` | fix/report-ux | yes | 0 | 0 | 2026-10-29 / fix(report): compatibility vs match terminology, IG-style share picker, report cache (bugs D/P/F) | SAFE-DELETE |
| 33 | `~/workspace/ayma/.claude/worktrees/agent-aa928f529553a94c1` | worktree-agent-aa928f529553a94c1 | yes | 0 | 0 | 2026-10-26 / feat(hackathon): Practice Date VOICE — simulated-match voice practice + live coach (Deliverable B) | SAFE-DELETE |
| 34 | `~/workspace/ayma/.claude/worktrees/agent-aad0275bc6cc722b3` | fix/ayma-clean-language-guardrail | yes | 0 | 0 | 2026-10-30 / Clean-language guardrail: Ayma's own output stays non-crude in every conversation | SAFE-DELETE |
| 35 | `~/workspace/ayma/.claude/worktrees/agent-aad8b7cab2db8abb1` | worktree-agent-aad8b7cab2db8abb1 | yes | 0 | 0 | 2026-10-26 / feat(profile): move profile photo controls: move delete+star to opened image | SAFE-DELETE |
| 36 | `~/workspace/ayma/.claude/worktrees/agent-ab80f4e2c55302926` | fix/web-research-icon-opens-report | yes | 0 | 0 | 2026-10-29 / fix(web-research): profile icon opens the report screen instead of auto-running the dive | SAFE-DELETE |
| 37 | `~/workspace/ayma/.claude/worktrees/agent-abe1c4871970501be` | fix/web-research-run-action | yes | 0 | 0 | 2026-10-29 / fix(web-research): relabel never-run empty-state action to "Run web search" | SAFE-DELETE |
| 38 | `~/workspace/ayma/.claude/worktrees/agent-abed0f94de4892eaa` | photo-upload-speed | yes | 0 | 0 | 2026-10-26 / perf(photo): speed up profile photo upload (client downscale + concurrent batch + deferred captioning) | SAFE-DELETE |
| 39 | `~/workspace/ayma/.claude/worktrees/agent-ac3d7ac1608718893` | fix/qloo-taste-bars | yes | 0 | 0 | 2026-10-29 / Taste match card: per-domain bars matching the Qloo judge demo | SAFE-DELETE |
| 40 | `~/workspace/ayma/.claude/worktrees/agent-ad4f7bb0d07a33b05` | practice-backend-fixes | yes | 0 | 0 | 2026-10-26 / fix(practice): correct coach target, parallelize send, add photo_url | SAFE-DELETE |
| 41 | `~/workspace/ayma/.claude/worktrees/agent-ad65cd8e2e7b10346` | feat/dm-media-gif-image | yes | 0 | 0 | 2026-10-30 / feat(dm): GIFs + images at par with WhatsApp (v1) — keyboard GIF insertion + gif type | SAFE-DELETE |
| 42 | `~/workspace/ayma/.claude/worktrees/agent-ad91dbd1cfaf01368` | fix/no-match-notif-for-dealbreakers | yes | 4 | 0 | 2026-10-29 / build: bump versionCode to 2239 (hide test fixtures from Explore + web-research icon opens report, no auto-run) | DIRTY |
| 43 | `~/workspace/ayma/.claude/worktrees/agent-ae830138335bfcdc9` | fix/appearance-prerun-test | yes | 0 | 0 | 2026-10-29 / test: update appearance_prerun_sheet_test for multi-select semantics | SAFE-DELETE |
| 44 | `~/workspace/ayma/.claude/worktrees/agent-ae978da94ddb46c4a` | fix-test-failures | yes | 0 | 0 | 2026-10-26 / fix(tests): green the suite — chat-scroll setup + backfill event-loop isolation | SAFE-DELETE |
| 45 | `~/workspace/ayma/.claude/worktrees/agent-ae983fecf0be05bdc` | HEAD | yes | 18 | 0 | 2026-10-25 / Add in-app account deletion flow and public delete-account page (Play data-deletion requirements) | DIRTY |
| 46 | `~/workspace/ayma/.claude/worktrees/agent-af6615067aee86bd5` | worktree-agent-af6615067aee86bd5 | yes | 0 | 0 | 2026-10-26 / feat(hackathon): Meta Muse Spark LLM provider behind per-surface flag (Deliverable A) | SAFE-DELETE |
| 47 | `~/workspace/ayma/.claude/worktrees/agent-af711a65ef3c10ac4` | fix/hide-test-fixtures-from-explore | yes | 0 | 0 | 2026-10-29 / fix(explore): hide seeded test fixtures from real users' Explore, keep curated demo set | SAFE-DELETE |
| 48 | `~/workspace/ayma/.claude/worktrees/agent-afd55a9f0bf6d8cda` | fix/web-research-empty-state | yes | 0 | 0 | 2026-10-29 / fix(web-research): bug C — distinguish "never run" from "load failed" | SAFE-DELETE |
| 49 | `~/workspace/ayma/.claude/worktrees/app-fixes` | HEAD | yes | 0 | 0 | 2026-10-27 / Record deployed ayma-api-00225-lzd in HACKATHON_STATUS | SAFE-DELETE |
| 50 | `~/workspace/ayma/.claude/worktrees/appearance-e2e` | HEAD | yes | 0 | 0 | 2026-10-28 / feat(questionnaire): ask taste early + surface it as a fillable completeness topic | SAFE-DELETE |
| 51 | `~/workspace/ayma/.claude/worktrees/appearance-fix` | appearance-fix-work | yes | 0 | 0 | 2026-10-28 / Appearance flow fixes: rerun keeps both axes, all-photos picker, vision routing | SAFE-DELETE |
| 52 | `~/workspace/ayma/.claude/worktrees/appearance-privacy` | appearance-privacy-work | yes | 0 | 0 | 2026-10-28 / Appearance sheet: private photo-add + run-in-place (privacy fix) | SAFE-DELETE |
| 53 | `~/workspace/ayma/.claude/worktrees/appearance-select` | appearance-select-work | yes | 0 | 0 | 2026-10-28 / fix(appearance): never auto-select multi-person or wrong-axis photos in pre-run sheet | SAFE-DELETE |
| 54 | `~/workspace/ayma/.claude/worktrees/appearance-single` | HEAD | no | 0 | 1 | 2026-10-29 / test(appearance): fake AymaPhoto cache manager in tests (fix "databaseFactory not initialized") | REVIEW |
| 55 | `~/workspace/ayma/.claude/worktrees/appearance-ux` | appearance-ux | yes | 0 | 0 | 2026-10-28 / feat(appearance): upload spinner, per-section guidance, background Run-analysis | SAFE-DELETE |
| 56 | `~/workspace/ayma/.claude/worktrees/argon` | HEAD | yes | 0 | 0 | 2026-10-28 / docs: Qloo extraction complete at /home/suhailps/qloo-extraction/ | SAFE-DELETE |
| 57 | `~/workspace/ayma/.claude/worktrees/avatar-snapshot` | avatar-snapshot | yes | 0 | 0 | 2026-10-27 / Persistent AI-avatar snapshot: standing per-user persona that sims spawn instantly | SAFE-DELETE |
| 58 | `~/workspace/ayma/.claude/worktrees/ayma-mcp` | ayma-mcp | yes | 0 | 0 | 2026-10-26 / MCP server: docs, architecture diagram, threat model | SAFE-DELETE |
| 59 | `~/workspace/ayma/.claude/worktrees/brain` | HEAD | yes | 0 | 0 | 2026-10-28 / Unified Brain selector: one per-user LLM for all text surfaces (§13.10) | SAFE-DELETE |
| 60 | `~/workspace/ayma/.claude/worktrees/build-2231` | HEAD | yes | 0 | 0 | 2026-10-28 / chore(release): bump versionCode to 1.30.0+2231 for consolidated build | SAFE-DELETE |
| 61 | `~/workspace/ayma/.claude/worktrees/build-2233` | HEAD | yes | 0 | 0 | 2026-10-28 / chore(release): bump versionCode to 1.30.0+2233 for 2233 build | SAFE-DELETE |
| 62 | `~/workspace/ayma/.claude/worktrees/build-2234` | HEAD | yes | 0 | 0 | 2026-10-28 / chore(release): bump versionCode 2233 -> 2234 for consolidated hackathon APK | SAFE-DELETE |
| 63 | `~/workspace/ayma/.claude/worktrees/coldstart2` | HEAD | yes | 0 | 0 | 2026-10-28 / Voice cascade: cold-start opener greets fresh (not reply to old msg) + tool-use hardening | SAFE-DELETE |
| 64 | `~/workspace/ayma/.claude/worktrees/connect-agent-capabilities` | connect-agent-capabilities | yes | 0 | 0 | 2026-10-27 / Connect-agent: add "What your agent can do" capabilities section | SAFE-DELETE |
| 65 | `~/workspace/ayma/.claude/worktrees/connect-agent-instructions` | connect-agent-instructions | no | 0 | 1 | 2026-10-27 / Connect an agent: in-screen setup instructions + Learn more | SAFE-DELETE* |
| 66 | `~/workspace/ayma/.claude/worktrees/datesim-continue` | HEAD | yes | 8 | 0 | 2026-10-29 / Conversations/DM: list_conversations tool, open-last/fuzzy, chip-on-success | DIRTY |
| 67 | `~/workspace/ayma/.claude/worktrees/dev-test-upgrade` | dev-test-upgrade | yes | 0 | 0 | 2026-10-27 / Add dev-only test-upgrade to grant per-plan credits without payment | SAFE-DELETE |
| 68 | `~/workspace/ayma/.claude/worktrees/devmode-flag` | devmode-flag-work | yes | 0 | 0 | 2026-10-28 / feat(devmode): compile-time flag gates dev mode; customer builds ship it off | SAFE-DELETE |
| 69 | `~/workspace/ayma/.claude/worktrees/dm-coach-backend` | dm-coach-backend | yes | 0 | 0 | 2026-10-26 / dm-coach: evolve icebreakers into thread-aware "Ayma in your DMs" assist on Muse | SAFE-DELETE |
| 70 | `~/workspace/ayma/.claude/worktrees/dm-coach-flutter` | dm-coach-flutter | yes | 0 | 0 | 2026-10-26 / DM coach: live refreshing suggestion chips + one-line tip (POST /dm/assist) | SAFE-DELETE |
| 71 | `~/workspace/ayma/.claude/worktrees/dm-coach-verify` | dm-coach-verify | yes | 0 | 0 | 2026-10-27 / Fix DM coach: exempt /dm/assist from the credit cap (§6.9) | SAFE-DELETE |
| 72 | `~/workspace/ayma/.claude/worktrees/dm-translate` | HEAD | yes | 0 | 0 | 2026-10-29 / fix(dm-translate): only offer Translate for confidently-foreign messages | SAFE-DELETE |
| 73 | `~/workspace/ayma/.claude/worktrees/feat-brain-for-all-surfaces` | feat-brain-for-all-surfaces | yes | 0 | 0 | 2026-10-27 / Route chat, matching and reports to the Meta brain | SAFE-DELETE |
| 74 | `~/workspace/ayma/.claude/worktrees/feat-credit-reset-display` | feat-credit-reset-display | yes | 0 | 0 | 2026-10-27 / Plan screen: show when free credits reset (local time + countdown) | SAFE-DELETE |
| 75 | `~/workspace/ayma/.claude/worktrees/feat-mcp-under-settings` | feat-mcp-under-settings | yes | 0 | 0 | 2026-10-27 / Move MCP "Connect an agent" entry under Ayma's settings | SAFE-DELETE |
| 76 | `~/workspace/ayma/.claude/worktrees/feature-ai-date-sim` | feature-ai-date-sim | yes | 0 | 0 | 2026-10-27 / Date sim: both-agent billing audit, cost warning with live estimate, AI Avatar opt-out | SAFE-DELETE |
| 77 | `~/workspace/ayma/.claude/worktrees/feature-cross-language` | feature-cross-language | yes | 0 | 0 | 2026-10-27 / Cross-language DM: real-time translation powered by Muse (§6.12) | SAFE-DELETE |
| 78 | `~/workspace/ayma/.claude/worktrees/feature-safety-coach` | feature-safety-coach | yes | 0 | 0 | 2026-10-27 / Safety red-flag coach: protective heads-up in DM threads (§6.9.1) | SAFE-DELETE |
| 79 | `~/workspace/ayma/.claude/worktrees/feature-tour` | feature-tour-wt | yes | 0 | 0 | 2026-10-28 / feat(tour): per-feature feature tour — auto-show post-preboarding, Settings replay, new-feature spotlights | SAFE-DELETE |
| 80 | `~/workspace/ayma/.claude/worktrees/feedback-catcher` | feedback-catcher | yes | 0 | 0 | 2026-10-26 / feat(feedback): in-app feedback catcher + unified feedback collection | SAFE-DELETE |
| 81 | `~/workspace/ayma/.claude/worktrees/fix-ai-avatar-toggle` | fix-ai-avatar-toggle | yes | 0 | 0 | 2026-10-27 / Fix AI Avatar toggle: age gate only on birthdate writes, allow accent colour, add rules tests | SAFE-DELETE |
| 82 | `~/workspace/ayma/.claude/worktrees/fix-coach-tip-keyboard` | fix-coach-tip-keyboard | yes | 0 | 0 | 2026-10-27 / Fix DM coach tip/chips clipped behind keyboard | SAFE-DELETE |
| 83 | `~/workspace/ayma/.claude/worktrees/fix-daily-free-credits` | fix-daily-free-credits | yes | 0 | 0 | 2026-10-27 / fix(billing): make free daily credit pool meaningful ($0.25→$1.00/day) | SAFE-DELETE |
| 84 | `~/workspace/ayma/.claude/worktrees/fix-date-sim-streaming` | fix-date-sim-streaming | yes | 0 | 0 | 2026-10-27 / Date sim: stream the AI-to-AI conversation live via Firestore | SAFE-DELETE |
| 85 | `~/workspace/ayma/.claude/worktrees/fix-launcher-icon` | fix-launcher-icon | yes | 0 | 0 | 2026-10-26 / fix(android-icon): make round launcher icon opaque so Android search shows no black box | SAFE-DELETE |
| 86 | `~/workspace/ayma/.claude/worktrees/fix-repeated-questions` | fix-repeated-questions | yes | 0 | 0 | 2026-10-27 / Fix completeness re-asking story-captured questions | SAFE-DELETE |
| 87 | `~/workspace/ayma/.claude/worktrees/fix-sentry-zone-startup` | fix-sentry-zone-startup | yes | 0 | 0 | 2026-10-27 / Fix release-only startup hang: guard RevenueCat init before runApp (§11.2) | SAFE-DELETE |
| 88 | `~/workspace/ayma/.claude/worktrees/fix-share-buttons` | fix-share-buttons | yes | 0 | 0 | 2026-10-27 / fix(share): Instagram link-to-clipboard + name missing app on report-card share | SAFE-DELETE |
| 89 | `~/workspace/ayma/.claude/worktrees/fix-splash-timeout` | fix-splash-timeout | yes | 0 | 0 | 2026-10-26 / Fix splash hang: startup timeouts, auto-retry/backoff, reconnect + Retry UI | SAFE-DELETE |
| 90 | `~/workspace/ayma/.claude/worktrees/fix-tour-dev-preview` | fix-tour-dev-preview | yes | 0 | 0 | 2026-10-27 / Dev-only feature-tour preview: Reset action opens /tour; relax splash gate for unlocked dev (§11.2) | SAFE-DELETE |
| 91 | `~/workspace/ayma/.claude/worktrees/fix-voice-default-and-chips` | fix-voice-default-and-chips | yes | 0 | 0 | 2026-10-27 / Fix voice-engine default to match call runtime; cap DM coach chips at 2 | SAFE-DELETE |
| 92 | `~/workspace/ayma/.claude/worktrees/harden-startup` | harden-startup | yes | 0 | 0 | 2026-10-27 / Harden startup against flaky DNS and corrupt restored auth (§11.2) | SAFE-DELETE |
| 93 | `~/workspace/ayma/.claude/worktrees/integrate-2218` | test/e2e-integration-harness | no | 1 | 24 | 2026-10-31 / test(e2e): GATES/B sweep uses the GRID's scrollable for scrollUntilVisible | DIRTY |
| 94 | `~/workspace/ayma/.claude/worktrees/integrate-2223` | integ-2223 | yes | 0 | 0 | 2026-10-27 / Bump versionCode 2223 (integrate avatar-toggle, date-sim streaming, voice default/chips) | SAFE-DELETE |
| 95 | `~/workspace/ayma/.claude/worktrees/intro-feature-tour` | intro-feature-tour | yes | 0 | 0 | 2026-10-26 / Add first-launch feature tour (intro carousel) | SAFE-DELETE |
| 96 | `~/workspace/ayma/.claude/worktrees/list-convos` | HEAD | yes | 0 | 0 | 2026-10-29 / docs(status): record conversations/DM fix (ayma-api-00245-djb, ayma-agent-00133-pmj) | SAFE-DELETE |
| 97 | `~/workspace/ayma/.claude/worktrees/lk-migrate` | lk-migrate-work | yes | 0 | 0 | 2026-10-28 / feat(voice): dual-cloud agent — Cloud Run OR LiveKit Cloud, flagged, default OFF | SAFE-DELETE |
| 98 | `~/workspace/ayma/.claude/worktrees/loading-perf` | loading-perf-wt | yes | 0 | 0 | 2026-10-28 / perf(flutter): animated-logo loader, report auto-refresh, SWR report cache, optimistic cold start (APK 2232) | SAFE-DELETE |
| 99 | `~/workspace/ayma/.claude/worktrees/notif-read` | notif-read-work | yes | 0 | 0 | 2026-10-28 / fix(notifications): mark in-app notification read + sync badge on OS notification tap | SAFE-DELETE |
| 100 | `~/workspace/ayma/.claude/worktrees/practice-voice-persona` | practice-voice-persona | yes | 0 | 0 | 2026-10-27 / Practice voice: gender-matched TTS voice, live-call persona framing, coach pronouns | SAFE-DELETE |
| 101 | `~/workspace/ayma/.claude/worktrees/qloo` | HEAD | yes | 0 | 0 | 2026-10-28 / Qloo taste match as a labeled section in the match report between two users | SAFE-DELETE |
| 102 | `~/workspace/ayma/.claude/worktrees/report-notify` | report-notify-wt | yes | 0 | 0 | 2026-10-28 / feat(reports): notify + freshness stamp when a background appearance/body report completes | SAFE-DELETE |
| 103 | `~/workspace/ayma/.claude/worktrees/rerun-fix` | HEAD | yes | 0 | 0 | 2026-10-28 / Rerun appearance report always executes, not deflect/open | SAFE-DELETE |
| 104 | `~/workspace/ayma/.claude/worktrees/self-style` | HEAD | yes | 0 | 0 | 2026-10-27 / date-sim: ground self-persona in the user's own sent DMs (texting style) | SAFE-DELETE |
| 105 | `~/workspace/ayma/.claude/worktrees/story-edit` | HEAD | yes | 0 | 0 | 2026-10-27 / Chat can now edit and soft-remove the user's own story/wiki entries | SAFE-DELETE |
| 106 | `~/workspace/ayma/.claude/worktrees/story-surgical` | story-surgical-work | yes | 0 | 0 | 2026-10-28 / fix(story): surgical single-line story edits that apply in place, no re-approval | SAFE-DELETE |
| 107 | `~/workspace/ayma/.claude/worktrees/story-tabs-restructure` | story-tabs-restructure | yes | 0 | 0 | 2026-10-27 / Story screen: drop Public view tab, move Ayma's Notes to a dev-only page | SAFE-DELETE |
| 108 | `~/workspace/ayma/.claude/worktrees/taste-q` | HEAD | yes | 0 | 0 | 2026-10-28 / feat(taste): collect music/film/food in the questionnaire to populate the public Qloo Taste page | SAFE-DELETE |
| 109 | `~/workspace/ayma/.claude/worktrees/tour-fix` | HEAD | yes | 8 | 0 | 2026-10-28 / docs(status): correct stale claim — Astro Codemagic login done, build #19 in TestFlight 1.30.0 (8) | DIRTY |
| 110 | `~/workspace/ayma/.claude/worktrees/tour-interactive` | HEAD | yes | 0 | 0 | 2026-10-28 / feat(tour): interactive coach-mark walkthrough (meta-hackathon) | SAFE-DELETE |
| 111 | `~/workspace/ayma/.claude/worktrees/ui-2226` | ui-2226-work | yes | 0 | 0 | 2026-10-28 / UI 2228: retire dev_panel flag (AI notes dev-only), date-sim avatar gate + low-context warning | SAFE-DELETE |
| 112 | `~/workspace/ayma/.claude/worktrees/voice-catalog-providers` | voice-catalog-providers | yes | 0 | 0 | 2026-10-27 / fix(voice): surface credited LiveKit providers (Fish Audio, Rime, Gradium) in the cascade dropdowns | SAFE-DELETE |
| 113 | `~/workspace/ayma/.claude/worktrees/voice-engine-switcher` | voice-engine-switcher | yes | 0 | 0 | 2026-10-26 / Voice engine switcher: per-user voice stack (mode + brain/STT/TTS + realtime), cloud-sourced catalog | SAFE-DELETE |
| 114 | `~/workspace/ayma/.claude/worktrees/voice-engine-user-settings` | voice-engine-user-settings | yes | 0 | 0 | 2026-10-27 / Move Voice Engine control into user-facing Ayma settings (§13.9) | SAFE-DELETE |
| 115 | `~/workspace/ayma/.claude/worktrees/voice-gender-fix` | voice-gender-fix | yes | 0 | 0 | 2026-10-27 / Fix Meta voice cascade gender match: default Inworld voices Ashley/Alex | SAFE-DELETE |
| 116 | `~/workspace/ayma/.claude/worktrees/voice-notif-gating` | voice-notif-gating | yes | 0 | 0 | 2026-10-26 / Voice call notification + orb glow gate on the listening state | SAFE-DELETE |
| 117 | `~/workspace/ayma/.claude/worktrees/voice-single-session` | voice-single-session | yes | 0 | 0 | 2026-10-27 / voice: enforce single active voice session (disconnect main before practice, and vice-versa) | SAFE-DELETE |
| 118 | `~/workspace/ayma/.claude/worktrees/voice-vocab` | meta-hackathon | yes | 0 | 0 | 2026-10-30 / build(play): add android-play Codemagic workflow (AAB w/ production RevenueCat key, pubspec versionCode) - Astro on founder release directive 2026-10-30 | SAFE-DELETE |
| 119 | `~/workspace/ayma/.fleet-worktrees/explore-tiles` | fix/explore-blank-tiles | yes | 2 | 0 | 2026-10-28 / docs(queue): record Agent Dates positioning wording conflict as founder decision (Nov 3 freeze) | DIRTY |
| 120 | `~/workspace/ayma/.fleet-worktrees/privacy-test` | test/privacy-extraction | no | 2 | 1 | 2026-10-31 / privacy-extraction-test: add 25-prompt fishing pack + scoring runner with mock mode | DIRTY |
| 121 | `~/workspace/ayma/.fleet-worktrees/sanitizer` | fix/reports-key-sanitizer | yes | 2 | 0 | 2026-10-28 / docs(queue): record Agent Dates positioning wording conflict as founder decision (Nov 3 freeze) | DIRTY |
| 122 | `~/workspace/ayma/.fleet-worktrees/staging-config` | feat/staging-build-config | yes | 7 | 0 | 2026-10-28 / docs(queue): record Agent Dates positioning wording conflict as founder decision (Nov 3 freeze) | DIRTY |
| 123 | `~/workspace/ayma/.fleet-worktrees/triage` | chore/worktree-triage | yes | 2 | 0 | 2026-10-28 / docs(queue): record Agent Dates positioning wording conflict as founder decision (Nov 3 freeze) | DIRTY |
| 124 | `/tmp/claude-1000/-home-suhailps-workspace-ayma/0f63c639-ef67-4eea-8457-0eacb1006fb4/scratchpad/storyfix` | MISSING | - | - |  | - | PRUNE |
| 125 | `/tmp/claude-1000/-home-suhailps-workspace-ayma/0f63c639-ef67-4eea-8457-0eacb1006fb4/scratchpad/wt-dupprop` | MISSING | - | - |  | - | PRUNE |
| 126 | `/tmp/claude-1000/-home-suhailps-workspace-ayma/0f63c639-ef67-4eea-8457-0eacb1006fb4/scratchpad/wt-taste` | MISSING | - | - |  | - | PRUNE |
| 127 | `/tmp/pubprep` | MISSING | - | - |  | - | PRUNE |
