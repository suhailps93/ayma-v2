# Handoff: open-weights-cheap-path

Branch: `feat/open-weights-cheap-path-meta` (pushed to origin; NOT merged).
Task: wire the open-weights low-cost backend path. Done — no token-limit stop.

## What I did

Wired a third `LLMProvider` value, `open-weights`, into the existing
`functions/bootstrap/llm_provider.py` abstraction (minimal, additive):

- `OpenWeightsProvider` — Muse Spark open weights over an OpenAI-compatible
  chat endpoint. Same call shapes as `MetaProvider` (text, event-streamed chat
  with one tool round, structured/JSON with the shared `_response_format` /
  `_coerce_json_text` / `_strip_keys` helpers), but: model id is the existing
  `config.meta_open_weights_model` (`meta-models/muse-spark-open-1026`, no new
  model string anywhere), client is built from `OPEN_WEIGHTS_BASE_URL` +
  `OPEN_WEIGHTS_API_KEY` only, no Meta-Model-API-only `reasoning_effort` knob
  is sent, and there is deliberately NO paid fallback.
- Unconfigured/misbehaving cheap path fails cleanly: missing base URL and/or
  key raises the explicit `OpenWeightsUnconfiguredError` naming the missing
  var(s); transport/bad-response errors propagate. Gemini is never consulted,
  so this path can never silently become paid spend.
- Selection: `LLM_PROVIDER_<SURFACE>=open-weights` (or global
  `LLM_PROVIDER=open-weights`) returns `OpenWeightsProvider` from
  `get_llm_provider`; unknown values still warn + return Gemini.
- Capability map: `open-weights` shares Meta's exact profile
  (text/json/tools, no vision/web), so `needs="vision"/"web"` still resolves
  to Gemini via `get_user_brain_provider`. NOT added to the user-facing
  `BRAINS` catalog or `/brain/preference` (backend flag only, per task).
- `config.py`: new `open_weights_api_base_url` (env `OPEN_WEIGHTS_BASE_URL`,
  default `""` = unconfigured); updated the `meta_open_weights_model` docstring
  (now wired) and the `llm_provider_*` docstring (third value). **No
  `LLM_PROVIDER` default touched — Gemini stays the default everywhere.**
- `docs/META_PROVIDER.md`: short "Open-weights cheap path" section; the
  "two implementations" line now says three.

Assumption (stated per AGENTS.md): the backend has no premium/non-premium
call classification (only one unrelated "premium" string in
`deep_dive_social.py`), so "eligible non-premium calls" is implemented as
"whichever surface the deployer flags `open-weights`" — the per-surface flag
IS the eligibility switch. Premium stays on `meta`/Gemini by leaving its
flag alone.

## Files changed

- `functions/bootstrap/llm_provider.py` — `PROVIDER_OPEN_WEIGHTS`,
  `OpenWeightsUnconfiguredError`, `OpenWeightsProvider`, selection +
  capability-map entries, doc updates. `MetaProvider` untouched.
- `functions/bootstrap/config.py` — `open_weights_api_base_url` field +
  `_load` entry; docstring updates only otherwise.
- `functions/bootstrap/tests/test_open_weights_provider.py` — NEW, 11 tests.
- `docs/META_PROVIDER.md` — cheap-path section.

## Tests run and results

- New: `tests/test_open_weights_provider.py` — **11 passed**. Core test mocks
  the `AsyncOpenAI` constructor, sets `OPEN_WEIGHTS_*`, and proves the call
  builds the client with `base_url=<OPEN_WEIGHTS_BASE_URL>` and sends
  `model=config.meta_open_weights_model`; plus unconfigured-key/URL errors,
  no-fallback propagation (Gemini stubbed to fail the test if touched),
  surface-flag selection, capabilities, and the empty default. No live HTTP.
- Related: `test_llm_provider.py`, `test_config.py`,
  `test_llm_call_site_coverage.py`, `test_brain_preference_endpoint.py`,
  `test_provider_spend.py`, `test_practice_date.py` — **94 passed**.
- Full backend suite (`tests/`, `test_agent.py` skips — needs agent venv):
  **2829 passed, 6 skipped, 2 failed** — both failures verified PRE-EXISTING
  on the clean tree via `git stash` (untouched by this change):
  `test_app_registry.py::test_notification_settings_cover_every_category` and
  `test_vendor_spend.py::test_stale_list_flags_stale_and_unavailable_only`.

## What remains (for Astro / next agent)

1. Set `OPEN_WEIGHTS_BASE_URL` + mount `OPEN_WEIGHTS_API_KEY` (Secret Manager,
   never plaintext) on the service, then flip one surface
   (e.g. `LLM_PROVIDER_MATCHING=open-weights`) to live-test against Baseten.
2. Optional follow-ups, deliberately out of scope: user-facing Brain catalog
   entry; `token_ledger` real-dollar pricing for the open-weights model
   (`cost_usd` is 0 today, same as Meta); a premium/non-premium classifier if
   the flag-per-surface switch proves too coarse.
3. The 2 pre-existing suite failures above belong to their owners, not this path.
