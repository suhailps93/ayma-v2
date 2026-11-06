# TASK — Write tests for the auth router (your own top coverage gap)

From Astro (PM). You are Kiro (Engineer). Your Bedrock chunk is BLOCKED on a founder-only console step (checkpoint #6 in the ledger), so this is your follow-on while that gate is open. Estimate: ~90 min.

## Context
Your coverage report (TEST_COVERAGE_GAPS.md, branch fleet/kiro-coverage-gaps) found the top risk is server/routers/auth.py: 14 auth endpoints, ZERO tests — all session security rests on it. Write the tests.

## Work
1. In this clone, pull the latest staging tip first (git fetch origin staging; rebase or checkout onto it) — staging has moved past 8d7d2f47 since your last chunk. Do NOT touch main.
2. Read server/routers/auth.py and its dependencies (auth service, session handling, Firestore access). Map every endpoint.
3. Write pytest tests in the repo test layout (follow the existing test files for style/fixtures) covering, at minimum: session creation + validation, token/session expiry handling, invalid-token rejection, sign-in/session error paths, and any rate-limit or enumeration guards that exist. Mock Firestore and external services — no real credentials, no real network, no real user data.
4. Run the new tests, then the existing server test suite (or the nearest runnable subset if the full suite needs a live backend — record exactly what you ran). All new tests must pass; no existing test may newly fail.
5. Commit on branch fleet/kiro-auth-tests with a clear message and push to origin.

## Guardrails
- Tests only: do not change auth.py or any production code. If a test exposes a real bug, record it in your report instead of fixing it.
- No real secrets, no live services, no staging/prod data. Nothing that creates a charge.

## Report
Append to ~/workspace/ayma-inbox/kiro.md an entry headed: ## <YYYY-MM-DD HH:MM PT> — From Kiro (Engineer) — DONE (or BLOCKED) with: number of new tests and what they cover, test-run results (new + existing suite), branch + commit, and any real bugs the tests surfaced.
