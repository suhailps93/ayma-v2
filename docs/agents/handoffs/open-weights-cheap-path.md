# Handoff: open-weights-cheap-path — STOPPED, provider code not on this branch

**Date:** 2026-10-31
**Branch:** `feat/open-weights-cheap-path` (= `staging` tip, commit `b6af7ce`)
**Status:** BLOCKED — did not implement. Per the task's FIRST instruction, I verified
whether the hackathon provider code exists on this branch. It does not, so I stopped
before making any code change.

## What I did

1. Read `AGENTS.md` and `docs/agents/CONTEXT_PACK.md` per fleet rules.
2. Verified the worktree/branch: `feat/open-weights-cheap-path` at `b6af7ce`,
   which is also the current tip of `origin/staging`.
3. Searched this branch for the hackathon provider code:
   - `LLM_PROVIDER` — zero hits in code (only the task scaffolding:
     `TASK.md`, `docs/agents/CONTEXT_PACK.md`).
   - Case-insensitive `muse|spark` — the only code hits are the unrelated
     vendor-spend "Muse daily routine" browser-agent strings in
     `functions/bootstrap/vendor_spend.py`, `admin_dashboard.py`,
     `tests/test_vendor_spend.py`, and `main.py`. No Muse Spark references.
   - `functions/bootstrap/llm_provider.py`, `practice_llm.py`,
     `practice_core.py` — all absent (`No such file or directory`).
4. Confirmed the code DOES exist on `origin/meta-hackathon` (read-only check,
   no checkout): `functions/bootstrap/llm_provider.py` (771 lines,
   "Higher-level LLM provider abstraction — hackathon Deliverable A" with
   `GeminiProvider` / `MetaProvider` behind per-surface `LLM_PROVIDER_*` flags),
   plus `practice_core.py`, `practice_llm.py`, and `LLM_PROVIDER` references in
   `config.py`, `agent.py`, `schema.py`, and tests.

This branch's only LLM routing is the lower-level Gemini transport switch in
`functions/bootstrap/llm_routing.py` (`vertex` vs LiveKit `inference` gateway),
which the hackathon module's own docstring calls orthogonal to the
provider-vendor choice. There is no provider abstraction here to extend, and no
`LLM_PROVIDER` default to preserve — so there was nothing minimal to build
against without porting Deliverable A itself, which is out of scope for this task.

## Files changed

- `docs/agents/handoffs/open-weights-cheap-path.md` (this file) — only change.
- No source files touched. No tests added (nothing to test against on this branch).

## Tests run and results

- No tests run — no code was changed. Verification was by repo search
  (`LLM_PROVIDER`, case-insensitive `muse|spark`) and `git grep` against
  `origin/meta-hackathon`, plus file-existence checks. All evidence points one
  way: hackathon provider code lives only on `meta-hackathon`.

## What remains (for Astro / whoever re-queues this)

- **Decision needed:** this task is targeted at the wrong branch. Options:
  1. Re-base/re-target the work onto `meta-hackathon` (where `llm_provider.py`
     lives) so the open-weights route can follow the existing
     `GeminiProvider`/`MetaProvider` abstraction; or
  2. Explicitly order a port of the provider abstraction onto staging first
     (much bigger than "keep the change minimal").
- Once on the right branch, the original spec still stands: route eligible
  non-premium calls to the Baseten OpenAI-compatible endpoint
  (`meta-models/muse-spark-open-1026`), config from `OPEN_WEIGHTS_BASE_URL` /
  `OPEN_WEIGHTS_API_KEY` only, explicit unconfigured error when unset (never
  crash, never silent fallback to a paid route), Gemini stays the default
  everywhere, plus a unit test with a mocked HTTP endpoint.
- Production-defaults guardrail held: nothing here changed any provider default.
