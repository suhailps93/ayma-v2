# Merge plan — tonight (2026-10-31, from Muse)

Auditor: Muse (fleet worktree `chore/merge-plan-tonight`). Method: read-only —
each branch's handoff note via `git show`, plus `git diff --stat` (and spot
diff review of the highest-risk files) against its base. Nothing merged,
nothing changed outside this worktree.

Bases: staging group → `origin/staging` @ `b6af7ce` (all four branches fork
from exactly this commit, one commit each — fast-forwardable in sequence).
Meta group → `meta-hackathon` @ `add55bf`.

## Headline

- Staging group: all four branches are mergeable tonight in the order below.
  One expected trivial conflict (`TASK.md` add/add — fleet scaffolding, drop
  it at merge time). Everything else auto-merges.
- Meta group: merge `feat/open-weights-cheap-path-meta` (clean, fast-forward).
  **`fix/reports-key-sanitizer-meta` does not exist** — on origin or locally.
  The sanitizer fix is unstarted and its hackathon gap stays open; the
  existing `fix/reports-key-sanitizer` branch is a handoff-only note on the
  wrong base explaining exactly that. Do not merge it anywhere.

## Branch audits

### 1. `test/privacy-extraction` @ `4c83af6` — target: staging

- Purpose: 25-prompt scripted fishing pack + scoring runner proving the agent
  never leaks location/phone/last-name/workplace/others' PII.
- Files touched (all additive, 444+): `test/privacy-extraction/privacy_pack.json`,
  `run_privacy_pack.py`, `detector_fixtures.json`, handoff note.
- Overlaps: none — new directory, zero shared files with any other branch.
- Test evidence (handoff): `--self-test` all OK (20 leak fixtures caught, 10
  safe quiet, 3 forbidden checks); `--mock` 25/25 pass exit 0; `--mock-mixed`
  17 pass / 8 fail exit 1 (FAIL path proven); `--forbidden` seed matching and
  `--output` JSON verified. No server needed.
- Risk: **LOW**. No production code touched. Live staging run (needs Astro's
  host + test-account token) remains but does not block the merge.

### 2. `chore/worktree-triage` @ `69c7601` — target: staging

- Purpose: read-only triage report classifying 127 worktrees (105
  safe-delete, 7 review, 11 dirty, 4 prune-ready).
- Files touched: `docs/agents/handoffs/worktree-triage.md` only (204 lines).
- Overlaps: none.
- Test evidence: n/a (docs-only, read-only analysis; no tests applicable).
- Risk: **LOW**. Note: its ref snapshot predates tonight (`origin/main`
  @ `9622966`, fleet branches mid-flight) — informational, will go stale as
  merges land. Merge for the record, don't treat counts as live.

### 3. `feat/staging-build-config` @ `648c9bf` — target: staging

- Purpose: `--dart-define=ENV=staging` switches the Flutter app to a staging
  API URL placeholder and shows a STAGING banner in the app shell.
- Files touched: `ayma_flutter/lib/env.dart` (+28/-2),
  `lib/widgets/staging_banner.dart` (new), `lib/screens/main_shell_screen.dart`,
  `lib/widgets/nav_bar_shell.dart`, `test/env_staging_test.dart` (new),
  `docs/ARCHITECTURE.md` (§12.1, +4), handoff note. (Also `TASK.md` +
  `docs/agents/CONTEXT_PACK.md` fleet scaffolding — see merge notes.)
- Overlaps: with #4 only — `TASK.md` (add/add, DIFFERENT content → will
  conflict), `docs/agents/CONTEXT_PACK.md` (add/add, byte-identical md5
  `fccb7bea…` → auto-merges), `docs/ARCHITECTURE.md` (disjoint hunks: §12.1
  here vs §11.8 there → expect clean auto-merge). No Dart file overlaps.
- Test evidence (handoff): new `env_staging_test.dart` 7/7; existing shell
  tests 15/15; `layout_matrix_test.dart` 21/21; `flutter analyze` clean.
- Auditor spot-check: `env.dart` diff reviewed — production default preserved
  (`ENV` unset → `'production'` → `prodApiBaseUrl`); the only changed line
  evaluates identically for production builds. Placeholder is non-routable
  `.invalid` as specified.
- Risk: **MED**. Touches the production `apiBaseUrl` default line and wraps
  every screen's shell — small blast radius but production-adjacent.
  Mitigated by strong test evidence + verified default. Gate below must
  include a production-build smoke check (no banner, prod URL).

### 4. `perf/phase0-telemetry` @ `9a0edce` — target: staging

- Purpose: Phase 0 perf baseline — debug-only `PerfLog` (app-start
  milestones, API timing, Firestore cache-vs-server origin). No behavior/UI/
  timeout changes by design.
- Files touched: `lib/util/perf_log.dart` + `test/perf_log_test.dart` (new),
  `lib/main.dart`, `lib/screens/splash_screen.dart`,
  `lib/services/{api_client,app_command_service,dev_panel_flag,dm_service,match_service,notification_service,profile_service}.dart`,
  `docs/ARCHITECTURE.md` (§11.8, +7), handoff note. (Also `TASK.md` +
  `docs/agents/CONTEXT_PACK.md` scaffolding — see merge notes.)
- Overlaps: with #3 only, as above. No Dart file overlaps with any branch.
- Test evidence (handoff): `flutter analyze` clean; `perf_log_test.dart`
  10/10; 4 related suites 44/44; full suite 1040 passed + 1 known
  pre-existing failure (`chat_scroll_to_bottom_test`, documented noise in
  `docs/AGENT_HANDOFF.md` §3).
- Risk: **LOW**. Everything behind `kDebugMode`; zero release-build effect.
  Many files touched but all changes are additive log lines.

### 5. `feat/open-weights-cheap-path-meta` @ `1d78add` — target: meta-hackathon

- Purpose: third `LLMProvider` value `open-weights` — cheap open-weights Muse
  Spark route over an OpenAI-compatible endpoint, per-surface flag, with
  deliberately NO paid fallback.
- Files touched (single commit on `meta-hackathon` tip → fast-forward):
  `functions/bootstrap/llm_provider.py` (+~280, incl. `OpenWeightsProvider`,
  selection + capability entries), `functions/bootstrap/config.py`
  (`open_weights_api_base_url` + docstrings), `tests/test_open_weights_provider.py`
  (new, 11 tests), `docs/META_PROVIDER.md`, handoff note.
- Overlaps: none — sole live branch on the meta line.
- Test evidence (handoff): new 11/11 (incl. no-fallback proof with Gemini
  stubbed to fail if touched); 6 related suites 94/94; full backend suite
  2829 passed / 6 skipped / 2 failed, both failures verified pre-existing on
  the clean tree via `git stash` (`test_app_registry` notification coverage,
  `test_vendor_spend` stale-list).
- Auditor spot-check: `config.py` diff reviewed — only a new field +
  docstrings; **no `LLM_PROVIDER` default touched, Gemini stays default
  everywhere** (fleet rule compliant). `llm_provider.py` removals are
  docstrings plus one selection `if`, replaced by an additive branch;
  `MetaProvider` class body untouched; unknown values still warn + Gemini.
- Risk: **MED**. It is the LLM call path on the hackathon line, but additive,
  flag-gated (unconfigured = explicit `OpenWeightsUnconfiguredError`, never
  silent paid spend), and defaults verified untouched. Live Baseten test
  (set `OPEN_WEIGHTS_BASE_URL` + key, flip one surface) remains for Astro.

### 6. `fix/reports-key-sanitizer-meta` — DOES NOT EXIST

- `git branch -a` + `git ls-remote origin`: no such ref. Nothing committed,
  nothing to merge.
- Nearest branch `fix/reports-key-sanitizer` @ `1c03c5d` (based on staging
  `b6af7ce`, NOT meta) contains only its handoff note: the agent found no
  Practice Date / Muse Spark report path on the staging base and correctly
  concluded the work belongs on the meta line. Verified: `practice_date.py`,
  `practice_llm.py`, `prompts/practice_debrief.md` exist on `meta-hackathon`
  and are absent on staging — the diagnosis was right.
- Do NOT merge `fix/reports-key-sanitizer` into staging — it would only add a
  stale blocker note (which even claims to be uncommitted). Retire the branch
  after the real fix lands.
- Risk: n/a — but the **hackathon gap (reports sanitizer, "strengths " key)
  is unstarted with submit Wed Nov 4 6:00 PM PT**. Needs a fresh branch off
  `meta-hackathon` (after #5 merges) + implement + focused backend tests.

## Merge order

### Staging group → `staging`

1. `test/privacy-extraction` — additive-only, zero overlap. Fast-forward.
2. `chore/worktree-triage` — docs-only, zero overlap. Fast-forward.
3. `feat/staging-build-config` — merges clean onto 1+2 (no shared files).
4. `perf/phase0-telemetry` — last. Expected: `CONTEXT_PACK.md` auto-merges
   (identical), `ARCHITECTURE.md` auto-merges (disjoint hunks), **`TASK.md`
   add/add conflicts — resolve by deleting it** (per-task fleet scaffolding,
   must not accumulate on staging):
   `git merge origin/perf/phase0-telemetry` → `git rm TASK.md` → commit.
   (If #3 merged first instead, the same resolution applies in reverse;
   order 3→4 is preferred because staging-config is the staging enabler and
   telemetry's suite is the broader regression net to run last.)

### Meta-hackathon group → `meta-hackathon`

1. `feat/open-weights-cheap-path-meta` — single commit on the tip:
   fast-forward, no conflicts possible. Then run its gate.
2. Sanitizer: no branch to merge — spawn the implementation task off the
   post-merge tip instead (see §6 above).

## Post-merge verification gates (run after EACH merge, on the merge result)

- After #1: `python3 test/privacy-extraction/run_privacy_pack.py --self-test`
  then `--mock` (expect all-OK / 25-25 exit 0). No server needed.
- After #2: none (docs-only). Optional: `git show --stat HEAD`.
- After #3: `cd ayma_flutter && flutter analyze` (expect clean) +
  `flutter test test/env_staging_test.dart test/main_shell_screen_test.dart test/nav_bar_shell_test.dart test/layout_matrix_test.dart`
  (expect 7+15+21 pass) + production smoke: release/debug build WITHOUT
  `ENV=staging` shows no banner and hits the prod URL.
- After #4: `cd ayma_flutter && flutter analyze` (expect clean) +
  `flutter test test/perf_log_test.dart test/splash_routing_test.dart test/app_command_service_test.dart test/dm_unread_test.dart test/notification_unread_count_test.dart`
  (expect 10+44 pass). Full `flutter test` if time allows (known noise:
  1 pre-existing `chat_scroll_to_bottom_test` failure).
- After #5: `cd functions/bootstrap && python -m pytest
  tests/test_open_weights_provider.py tests/test_llm_provider.py
  tests/test_config.py tests/test_llm_call_site_coverage.py
  tests/test_brain_preference_endpoint.py tests/test_provider_spend.py
  tests/test_practice_date.py` (expect 11+94 pass). Full suite optional
  (2 known pre-existing failures — see §5; do not chase them in this merge).

## Flags for Astro

1. Sanitizer-meta branch never materialized — biggest tonight's-plan gap;
   needs scheduling against the Nov 4 deadline.
2. `TASK.md` will conflict at step 4 — intended resolution is deletion, not a
   content merge; whoever merges must know this in advance.
3. Triage report (#2) goes stale as tonight's merges land — file it as a
   point-in-time record, not a live checklist.
4. No branch touched `LLM_PROVIDER` defaults (spot-verified on #5's
   `config.py`; #3/#4 are Flutter-only; #1/#2 add no code). Gemini default
   intact everywhere.
