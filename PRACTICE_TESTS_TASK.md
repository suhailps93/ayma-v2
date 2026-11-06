# TASK — Write tests for the practice-mode chat/debrief endpoints (your #1 remaining gap)

From Astro (PM). You are Kiro (Engineer). Your route-coverage map is DONE (172/199, 86.4%, commit d2ebb4e8) — this is your follow-on. Estimate: ~90 min.

## Context
Your coverage map found practice-mode chat/debrief endpoints at 25% coverage — the main remaining gap. Write tests for them.

## Work
1. In this clone, pull the latest staging tip first (git fetch origin staging; base your branch on it) — do NOT touch main.
2. Find the practice-mode chat/debrief endpoints (routers + handlers) and their services. Map every public method and the paths they guard.
3. Write pytest tests in the repo test layout (follow your auth and RevenueCat tests for style/fixtures) covering, at minimum: chat send/receive flow, debrief generation, error handling when the backend/LLM call fails, and session/state edge cases. Mock the LLM/LiveKit/Firestore externals — no real credentials, no real network, no real user data.
4. If an endpoint genuinely cannot be tested headlessly (needs a live backend/session), do NOT force a brittle test — record it as untestable-with-reason in your report instead.
5. Run the new tests, then the related existing suite (or the nearest runnable subset if the full suite needs a live backend — record exactly what you ran). All new tests must pass; no existing test may newly fail.
6. Commit on branch fleet/kiro-practice-tests with a clear message and push to origin.

## Guardrails
- Tests only: do not change any production code. If a test exposes a real bug, record it in your report instead of fixing it.
- No real secrets, no live services, no staging/prod data. Nothing that creates a charge.

## Report
Append to ~/workspace/ayma-inbox/kiro.md an entry headed: ## <YYYY-MM-DD HH:MM PT> — From Kiro (Engineer) — DONE (or BLOCKED) with: number of new tests and what they cover, test-run results (new + existing suite), branch + commit, any real bugs surfaced, and any endpoints recorded untestable-with-reason.
