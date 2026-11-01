# Handoff: demo-seed-verify (Meta hackathon demo data audit)

Branch: `chore/demo-seed-verify` (off `meta-hackathon` @ add55bf — no merge, no deploy).
Live systems untouched — code and fixtures only. No model/provider defaults touched.

## Bottom line

The three demo accounts (test1/test2/test3) are demo-ready at the data level
**after a fresh re-seed with this branch**, with two real seed gaps fixed here.
Offline, the seeded data runs a full Practice Date and a full AI Date
Simulation between test1↔test2 and test1↔test3 at code level (proven by a new
committed test). One live step remains: someone with ADC for `ayma-ai` must run
`seed_demo_accounts.py` (no `--reset` needed — both fixes are idempotent
upserts) and then `verify_demo_accounts.py`, and confirm the new sections 9–11.

## What I audited (all complete, no gaps)

- **Accounts**: `test1@gmail.com`/`test2@gmail.com`/`test3@gmail.com`, password
  `Test123`, uids `demo-test1/2/3` — in `personas.json`, the seed, and the
  `TEST_BYPASS_EMAILS` / `ALL_FLAGS_ON_UIDS` config defaults. Bypasses are
  scoped to exactly these accounts (existing `test_demo_account_overrides.py`).
- **Profiles**: name, birthdate (ages 29/27/30, all 18+), gender,
  `interested_in`, location (San Jose), headline, relationship intent,
  partner age range, distance pref, full `qz_*` mirrors + questionnaire answers
  (good pair identical, test3 childfree gate vs test1) — everything the
  profile/settings screens, Explore cards, and the matcher read.
- **Photos**: 3 AI photos each through the real pipeline (moderation +
  attributes + grid + primary) plus an Appearance report. Explore cards,
  profile carousel, and persona `photo_count` all resolve.
- **Story/prompts/preferences**: 9 public story pages (identity…dealbreakers)
  + 9-domain public Taste page + taste nodes + a multi-turn Ayma conversation.
  ("Prompts": the app renders no separate prompts section — story sections are
  the prompts surface, and all are filled. Preferences = partner prefs, filled.)
- **Match reports**: seed persists the FULL report doc (dimensions, structured
  score, shared/tensions/missing, gates, confidence) — the lite-doc bug is
  already fixed on this base. Good pair ≈0.99, bad pair ≈0.25 (documented live).
- **DMs**: Daniel↔Sofia (warm) and Daniel↔Priya (polite/off) via real `dm_ops`
  — correct `participants`/`sender_uid`/`type`/`body` shape, so style-exemplar
  gathering works.
- **Practice Date reads** (`build_persona_context` → prompt → session store):
  `ai_avatar_enabled=True`, public name/age/gender/location, 10 pages,
  3 photos — present for both pairs, both directions. Coach + debrief prompts
  compose. 18+ gate passes (all birthdates adult). 1000-credit top-up covers
  metered persona/coach/debrief/sim calls.
- **Date-sim reads** (`run_simulation`/`continue_simulation`): both sides'
  snapshots exist with full grounding; readiness 80+ (threshold 20), never
  low-context, so no warning and the full-depth anti-fabrication fragment.
- **Explore**: no `exclude_from_explore` flag and no `demo_practice_` prefix on
  `demo-test1/2/3`, so they stay visible (unlike the edge fixtures and the
  Maya/Leo/Aisha/Noah practice personas, which are excluded by design).

## What was missing (fixed on this branch)

1. **Seed never wrote the `users/{uid}` root doc** — REAL BUG. Explore
   candidates come from streaming the `users` collection, so after a
   `--reset` + rebuild the demo accounts were invisible in Explore until each
   account's first authed request stamped its root doc. A fresh judge login as
   test1 could have shown an empty feed. Fix: `write_profile_and_questionnaire`
   now creates the root doc (`created_at`, set-once) — idempotent.
   Caught by the new test (Explore returned zero cards before the fix).
2. **Avatar snapshots were built BEFORE the DMs** (phase 3 vs phase 5). The
   snapshot embeds the user's own sent messages as texting-style exemplars, so
   every snapshot baked in an empty sample, and the later DM sends flipped all
   three snapshots `stale=True`. Sims still ran (readiness 80, not low), but
   the user's agent couldn't mirror their texting voice. Fix: snapshots moved
   to a new phase 6, after DMs (runs under `--no-llm` too — grounding persists
   LLM-free). Cost-neutral, idempotent.
3. **Verify script had no Practice/sim coverage.** Added read-only sections:
   §9 persona context + prompt composition per pair, §10 snapshot
   (`distilled`/`stale`/readiness/exemplars) + `preflight_readiness` per pair,
   §11 story page-types + taste domains per account, plus `users-root=` in §1.
   Still fully read-only (no sessions started, nothing written).

Non-issues checked and left alone: `headline` is written but never rendered
(harmless); `seed-avatar-*` session docs have no reader (write-only warmth from
the live persona smoke test — tiny, intentional); sim `photo_url` is None from
snapshots but no sim/practice header renders photos (verified in
`date_sim_screen.dart`/`practice_screen.dart`).

## Files changed

- `scripts/seed_demo_accounts.py` — root-doc ensure; snapshot phase moved after
  DMs; docstring updated.
- `scripts/verify_demo_accounts.py` — new read-only §§9–11 + `users-root=` in §1.
- `functions/bootstrap/tests/test_demo_seed_practice.py` — NEW, 8 tests, offline:
  runs the real `personas.json` + real seed writers on FakeDb, then proves
  public profile, persona context, prompt composition, session round-trip,
  both sim sides, readiness/preflight, and Explore discovery for both pairs.

## Tests run

- New: `test_demo_seed_practice.py` — 8 passed (Explore test failed before the
  root-doc fix, passes after — the test is non-vacuous).
- Related, all green: `test_practice_date`, `test_practice_extraction`,
  `test_public_profile`, `test_demo_account_overrides` (60 passed with the new
  file), `test_date_sim`, `test_explore`, `test_explore_hides_fixtures`
  (50 passed).
- NOT run (needs live ADC + LLM, forbidden here): `seed_demo_accounts.py` and
  `verify_demo_accounts.py` against `ayma-ai`. Both compile clean.

## What remains (needs live credentials — not this agent)

1. `python3 scripts/seed_demo_accounts.py` (plain re-run; picks up root docs +
   rebuilt snapshots idempotently — `--reset` NOT required).
2. `python3 scripts/verify_demo_accounts.py` — confirm §§9–11: persona contexts
   present with 10 pages / 3 photos, snapshots `distilled=True stale=False`
   with exemplars > 0, preflights not low-context, story has all 9 page types
   + taste, taste has all 9 domains, `users-root=True` ×3.
3. If verify is green, the data level is bulletproof. Any red item → file a bug
   against this branch, do not hand-edit Firestore.

## Demo-day click-path (founder)

Log in as Daniel (test1@gmail.com / Test123):
1. **Explore** → Sofia and Priya cards show with photos, ages, scores (Sofia
   first — high match sorts top).
2. Tap **Sofia** → full profile (photos, story, taste). Side rail:
   - **Match button** → report: high score + dimension breakdown + Qloo taste
     card with shared entities (Bon Iver, Fleet Foxes, Lost in Translation…).
   - **Practice button** (`profilePracticeButton`) → simulator vs Sofia's
     persona → chat a few turns (coach nudges appear) → end → debrief
     (what worked / next lines / avoid).
   - **Spark button** (`profileDateSimButton`) → estimate (no low-context
     warning) → run 6-message sim → transcript streams in → score + summary.
3. Back out, tap **Priya** → same path, opposite story: low capped score,
   thin taste overlap, flatter sim — the good-vs-bad contrast is the demo.
4. Optional: **Messages** → pre-seeded Daniel↔Sofia and Daniel↔Priya threads
   read lived-in; **My story / Ayma's notes** shows Daniel's conversation.
