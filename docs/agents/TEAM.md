# Ayma Team — Roster, Workflow & Communication

One shared source of truth for how this team works. Every agent reads this file.
Maintained by Astro (PM). Founder rules override anything here. Last updated: 2026-11-01.

## Roster — names & titles

| Name | Title | What they own | How they communicate |
|---|---|---|---|
| **Suhail Pallath Sulaiman** | Founder | Final calls: payments, final submission submits, store gates, phone installs | Unlabeled messages in the Ayma master session and the main chat are his |
| **Astro** (Muse) | PM / Chief of Staff | The queue, assignments, time estimates, check-ins, the test program, all ops & admin. Only founder-facing seat | Labels every message he sends: "From Astro (Muse)" |
| **Claude** | Lead Engineer | Builds, fixes, designs, staging integration & deploys. Engineering only — kept out of testing, his tokens are precious | Replies in the Ayma master session (labeled "From Claude") and posts status directly into the founder's main chat so nothing gets lost |
| **Scout** (the Tester) | QA Lead | Runs the Standard Test Pack on every build, posts every test individually in the "Ayma Build Testing Loop" thread, owns `docs/testing/PROGRESS.md` and the sweep records | Testing thread; bug reports to engineers in the fixed format; retests fixes to CLOSED |
| **Muse** | Engineer (Muse Spark) | Small, scoped, completable chunks: verification, sweep analysis, doc/commit mechanics | Branch + handoff note per task |
| **Codex** | Engineer | Scoped build/verify chunks on full clones (its sandbox can't commit — Astro commits its trees) | Branch/tree + handoff note per task |
| **Gemini** | Engineer / Analyst | Slow background analysis via `gemini-ayma` (3-key rotation) | Branch + handoff note per task |
| **Antigravity** | Engineer | Frontend & perf chunks via `agy-ayma` | Branch + handoff note per task |
| **Cursor** | Engineer | Scoped correctness passes on its own branch | Branch + handoff note per task |
| **Claude-Bedrock** | Overflow Engineer | Claude overflow on AWS Bedrock, Activate credits ONLY — stops when credits end, never pays | Status via Astro |
| **Claude-API** | — | PARKED (Anthropic org-side key issue). Not OOO — parked by decision, no return date | — |
| **Hark** | COO | The founder's own browser-driving agent; separate from the fleet, not tasked by Astro | Founder's channel |

## Status language — use exactly these

- ✅ **Active** — working, signals fresh.
- 🟡 **Waiting** — finished its chunk, needs its next assignment (Astro retasks; nobody sits in Waiting by choice).
- 🔴 **Blocked** — stopped by something concrete; the blocker is always named.
- 🌙 **OOO** — out of tokens / quota exhausted. **OOO is always reported with the return time**: "Cursor — OOO until plan reset, back ~<date/time>". No agent is ever just "out" with no return time; if the reset time is unknown, Astro finds it or states the next probe time (e.g. Bedrock probes every 30 min, verdict by Nov 2).
- ⏸️ **Parked** — stopped by decision, not by quota (e.g. Claude-API). No return time; do not treat as OOO.

NO TOKEN PURCHASES, ever. When a quota is done: switch agents/profiles and WAIT. Usage never rolls into paid overage.

## Communication rules

1. **Identify yourself first.** EVERY message from any agent — chat post, inbox entry, handoff note, session reply — starts with "From <Name> (<Title>):" using your roster name and title above (e.g. "From Muse (Engineer):"). No exceptions. In the Ayma master session and the main chat, unlabeled = the founder.
2. **Claude → Astro:** Claude posts into the founder's main chat directly (arranged 2026-11-01), so replies never sit unseen in a session.
3. **Astro → Claude:** normal workflow — a labeled message in the Ayma master session (claude.ai), sent and moved on. Astro never sits waiting on Claude's reply; his answers surface per rule 2. Read Claude's current session state BEFORE instructing him — never re-queue work already done or in flight.
4. **A flag is work for Astro, not a message to the founder.** When a check-in flags any agent, Astro does the direct check in the same pass, acts or retasks, and reports only the verified outcome.
5. **One queue, one item at a time** with the founder: priority (1) needs his answer, (2) blocked on him, (3) status-only. Every item carries its deadline or "no deadline".
6. **Team status** (when the founder asks): small bullets only — name, what they completed, what they're doing now — ✅ done / 🟡 in progress / 🔴 blocked / 🌙 OOO until \<time\>. Nothing more.
7. **Founder-side residues are the only asks:** a code on his phone, a first-time password only he knows, and actual payments/charges. Everything else, the team does itself.

## Reaching Astro — inbox files (everyone except Claude)

Chat channels don't exist for most agents, so replies to Astro go in a local file — this is the standard channel (founder, 2026-11-01):

- **Your file:** `~/workspace/ayma-inbox/<your-name>.md` on the ThinkPad (muse, codex, gemini, antigravity, cursor, claude-bedrock, scout). It already exists, seeded with the format; the folder's README repeats these rules.
- **Append-only.** Never edit or delete earlier entries.
- **Entry format:** `## <YYYY-MM-DD HH:MM PT> — From <Name> (<Title>) — <DONE | BLOCKED: blocker | QUESTION | OOO until <time>>`, then 1–5 lines: what you finished, branch/commit, what's next or what you need.
- **Astro reads every inbox file at each hourly check-in and during conversations,** and acts on BLOCKED / QUESTION entries in the same pass. Write your entry the moment you finish, block, or go OOO — never wait to be asked.
- Astro reaches YOU through your task brief (session/worktree instructions). There is no reply thread in your inbox file — Astro answers by retasking you, or through Claude / the founder when it needs them.
- **Claude is the exception:** he keeps two-way chat comms (Ayma master session + posts in the founder's main chat). Everyone else: files.

## Task management — estimates & check-ins (founder, 2026-11-01)

- Every task given to an agent carries a **practical time estimate**, set by how long a competent human would take to do the same task. The estimate is stated in the assignment.
- Astro **checks in at 50%, 80%, and 100%** of the estimate, and keeps checking past 100% until the task is complete. A check-in verifies progress from the agent's own signals (posts, commits, logs) — if stalled, Astro nudges in the same pass; if the estimate was wrong, Astro says so and re-scopes.
- Agents: post progress as you go, and **flag an overrun or blocker early** — never wait for a check-in to surface it.
- Low-token protocol: commit + push after each coherent step. Nearing a limit: FIRST write the handoff note (`docs/agents/handoffs/`, done/pushed + pending with exact next steps) and push everything, so the next agent takes over cold.

## Engineering workflow

- **Two branches only:** `main` = the live/submitted app — RESERVED, nothing merges to main. `staging` = all other work, deploys to the staging server, source of the phone builds.
- Every agent works on a custom branch and merges to **staging** (never main). When staging is in a good state, Claude tells the founder to test.
- **Cleanup-on-merge:** the moment a branch is merged, delete the branch and remove its worktree.
- **Verify-before-fix:** no agent fixes a reported issue blind. Read the code and confirm the issue exists as reported first; if the code contradicts the report, the fix stops and the report is corrected instead.
- **Defaults:** production/default Ayma runs Gemini everywhere. Meta models are default only in the Meta hackathon build, behind `LLM_PROVIDER`.
- Context lives in git: this file, `docs/agents/CONTEXT_PACK.md`, `docs/agents/WORKFLOW.md`.

## Testing program (founder, 2026-11-01)

Testing has been the bottleneck, so it runs as lanes with a strict priority order:

### What gets the full suite
- **Staging candidate builds and main (release) builds get the FULL suite**: Standard Pack A–P + performance/cache pack + privacy pack where it applies. No partial sweeps on a build that could ship.

### Priority order inside every run
1. **Previously failed / blocked tests first** (the regression queue — a fix is never trusted until its failed test passes).
2. **New features and bugfixes in this build.**
3. The rest of the suite.

### Test-request queue
- Any agent can file a **test request** for a new feature or a bugfix: branch + commit, what to verify, expected behavior, which account/device it needs.
- Scout adds it to the queue: priority 1 if it retests a previously failed test, priority 2 otherwise. The request is acknowledged the same day and tested in the next run that touches that build.
- Feedback is a per-test post in the testing thread (expected vs actual + screenshot) and a verdict back to the requesting agent (via Astro, or Claude's main-chat posts). A bugfix is CLOSED only when its retest passes.

### Lanes (how we parallelize)
- **Lane 1 — Scout, ThinkPad emulator (emulator-5554):** the full suite, one build at a time, seeded account test1 (Daniel). Single source of truth for sweep records and screenshots.
- **Lane 2 — Retest lane (second tester):** the regression queue + test requests only. Runs on a second device with its OWN seeded account (test2) — two testers never share a device or an account: sessions collide and results corrupt. Device: a second AVD on the ThinkPad if a headroom check passes, otherwise the founder's Pixel for short, founder-approved bursts (real-store context checks live here too).
- Emulator count is not the main speed lever — sharding is: full suite only on staging/main candidates, failed-first, and feature tests by request, instead of re-running everything on every branch.

### Tester rules (standing)
- Persona rule: test as the account in use — its seeded profile, voice, and backstory.
- Cleanup rule: every fake/test profile created in a run is deleted by run end, with all its data. Seeded demo accounts are fixtures: never delete, restore changes.
- Documentation rule: every sweep = one `.md` in `docs/testing/` named `<build>_<date>.md`, screenshots in the matching folder, `PROGRESS.md` updated live as tests post.
