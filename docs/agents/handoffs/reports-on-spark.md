# reports-on-spark handoff

From Claude-Bedrock — uncommitted working-tree changes only. No deploy, merge,
commit, purchase, or model-id change was made.

## Routing found

- Practice Date's simulated reply, live coach, and end-of-session debrief all
  call `practice_llm`, whose `SURFACE = "practice"` resolves through
  `get_llm_provider("practice")`.
- The debrief is structured JSON in `practice_core.generate_debrief`; it is
  not the appearance-report `reports` surface.
- Before this change, `scripts/deploy-api.sh --full` explicitly set both
  `LLM_PROVIDER_PRACTICE=gemini` and `LLM_PROVIDER_REPORTS=gemini`, so the
  Practice Date debrief stayed on Gemini even though the provider seam and
  Muse Spark fallback path already existed.
- Appearance reports (`face_report.py` / `body_report.py`) deliberately use
  `get_vision_provider("reports")`. Meta/Muse has no verified vision
  capability in the capability map, so that path correctly remains Gemini
  even if `LLM_PROVIDER_REPORTS=meta`; this is unrelated to a Practice Date
  debrief.

## Change

- Added an explicit `--hackathon` profile to `scripts/deploy-api.sh`. It is
  valid only with `--full` and changes only
  `LLM_PROVIDER_PRACTICE=gemini` to `LLM_PROVIDER_PRACTICE=meta`.
- Normal `--full` keeps all existing Gemini pins, including `practice` and
  `reports`; production/default behavior is unchanged.
- The intended hackathon invocation is:

  ```bash
  scripts/deploy-api.sh --full --hackathon
  ```

  This routes Practice Date roleplay, coach, and debrief through Muse Spark's
  existing `practice` provider route, with the existing `LLM_META_FALLBACK`
  behavior still governing fallback.

## Regression proof

- Added `test_spark_debrief_payload_with_whitespace_keys_builds_complete_report`
  to `functions/bootstrap/tests/test_practice_date.py`. It sends a fake
  `MetaProvider` response using Muse Spark's known trailing-space key shape
  (`what_worked `, `suggested_next_lines `, `avoid `) through the real
  Practice Date debrief path and asserts the complete normalized report.
- This relies on the existing recursive key sanitizer in
  `MetaProvider.generate_json` (commit `83702e5`); no duplicate sanitizer was
  added.

## Verification

```text
bash -n scripts/deploy-api.sh
cd functions/bootstrap && python3 -m pytest -q tests/test_llm_provider.py tests/test_practice_date.py
63 passed, 7 warnings in 1.95s
```

Warnings were existing dependency/FastAPI deprecations only; no test failed.

## Files changed (uncommitted)

- `scripts/deploy-api.sh`
- `functions/bootstrap/tests/test_practice_date.py`
- `docs/agents/handoffs/reports-on-spark.md`

## Merge note for Claude

Keep this scoped to the Meta hackathon build/profile. Do not change the
production `--full` default or reroute appearance reports away from Gemini
without a separate capability decision: their image inputs are why
`get_vision_provider("reports")` currently selects Gemini.
