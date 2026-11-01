# Codebase sweep, chunk 1 of 2 — backend (from Muse)

Scope: `functions/` + FastAPI service code (`functions/bootstrap/`, ~42k lines, ~100 modules, 143 test files). Report only — no application code changed. Method: vulture dead-code scan, importer tracing, route/dup analysis, marker greps, prompt/config-rule audit, `pytest --collect-only` (2354 tests, clean).

## Findings, ranked by risk × cleanup value

1. `functions/bootstrap/main.py` (6,231 lines, 145 routes, 224 defs) — monolith router every backend change touches; split by prefix group (`/story` ×13, `/cron` ×10, `/profile` ×9, `/media` ×8, `/appearance` ×7…).
2. `functions/bootstrap/face_report.py` + `body_report.py` (264 lines each, identical `_num`/`run`/`render`/`teaser` skeleton) and `skills/face_report.py` + `skills/body_report.py` (duplicated `_latest_chat_image`) — cloned engines; fixes must land twice, extract a shared base.
3. `functions/bootstrap/face_report.py:28-39`, `body_report.py:29-46` — only two app modules with prompts inline (`_SYSTEM`/`_INSTRUCTION`), violating AGENTS.md; move to `prompts/`.
4. `functions/bootstrap/requirements.txt:11` (`openai==2.46.0`) vs `requirements-agent.txt:16` (`openai>=3.19,<4`) — shared code (`inference_llm.py`, `gemini.py`) runs against two majors; reconcile the pin.
5. Duplicated micro-helpers: `_iso` ×7 (`report_hub.py:122`, `appearance.py:836`, `story.py:173`, `google_account.py:702`, `billing.py:362`, `skills/fact_source.py:70`, `biometric_consent.py:138`), `_num` ×2, `_now` ×2, plus the identical 3-line `@lru_cache _prompt()` file-loader in ~10 modules — centralize in one util module (`report_hub._iso` already drifted).
6. `functions/bootstrap/token_ledger.py` (1,166 lines) — billing module also hosts `_is_duplicate_face` (face-embedding logic) and `_contact_verified`; move domain strays out.
7. `functions/bootstrap/admin_dashboard.py` (876 lines, zero defs — one HTML string) — move markup to `templates/` next to `referral_page.html`.
8. `functions/bootstrap/skills/app_control.py` (1,155 lines, 30+ helpers) — split largest skill by action family (command queue, navigation, settings, account actions).
9. `functions/bootstrap/config.py:57,374` — dead fields `bootstrap_stub_session_mode` and `notifications_limit` (+ `NOTIFICATIONS_LIMIT` env): zero readers repo-wide; delete.
10. `functions/bootstrap/appearance.py` (1,243 lines) — engine + storage + reads + batching + corrections + legacy purge in one file; also decide a sunset date for the `_LEGACY_COLLECTIONS` read-only merge.
11. `functions/bootstrap/deep_dive.py` (1,396 lines) — four near-identical dispute paths (`dispute_fact`/`dispute_link`/`dispute_social_link`/`dispute_web_image`, lines 563-773); merge into one parameterized path.
12. `functions/bootstrap/story.py` (1,000 lines, 42 defs) and `profile_manual.py` (970 lines, 43 defs) — coherent but oversized; section banners already mark the split lines.
13. `tools/context_ab_replay.py:403-532` (reaches into `token_ledger._MODEL_PRICING` with hardcoded model keys) and `scripts/voice_pipeline_e2e.py:121` (hardcoded `gemini-2.5-flash-preview-tts`) — offline-only, but violate the no-hardcoded-models rule; route through `config.py`.
14. Stale references to `scripts/flags.py` (doesn't exist) in `dev_flags.py:5` and `admin_dashboard.py:163` — fix or drop the pointers.
15. `functions/bootstrap/main.py` uses deprecated `@app.on_event` (pytest emits DeprecationWarning) — migrate to lifespan handlers.
16. `functions/bootstrap/google_account.py` (708 lines) — OAuth + Gmail + Calendar in one module; natural three-way split, low urgency.
17. `functions/bootstrap/photo_attrs.py` (`profile/main.photo_attrs`) vs `physical_attributes.py` (`profile/main.physical_attrs`) — distinct pipeline stages, but two overlapping attribute mirrors on the same doc; document the boundary or unify the shape.

## Explicitly checked, no action needed

- Provider experiments: no stale branches — Vertex vs LiveKit Inference dual path is live and flag-routed (`llm_routing.py`, `feature_flags.py`, `VOICE_PROVIDER`); `scripts/llm_side_by_side.py` + `llm_ab_fixtures.json` and `tools/context_ab_replay.py` are labeled offline tooling.
- No duplicate routes (145 `@app.*` decorators, all unique), no orphan modules (every `.py` imported), no stale test imports, 2 conditional skips only (`test_app_registry.py:38`, `test_questionnaire_skill.py:115`).
- Prompt hygiene otherwise good: 43 files under `prompts/`, all other modules load from disk.
- `matching.py` / `match_deterministic.py` / `matching_skill.py` / `matching_cron.py` are layered (heuristic pre-filter → deterministic gates → LLM), not duplicated.

## Suggested cleanup order for chunk 2 (or a follow-up)

Delete dead flags (#9) and fix stale refs (#14) first (zero-risk); then helpers (#5), dashboard HTML (#7), offline-tool models (#13); then the face/body merge (#2) with prompt extraction (#3); monolith splits (#1, #8, #10–12, #16) last, one per commit with the layout/test gates green.
