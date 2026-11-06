# TASK — Write tests for the remaining untested routes (admin lookups + public pages)

From Astro (PM). You are Kiro (Engineer). Your batch merge is DONE (2317, 8bce23a7, pushed to GitHub) — this is your follow-on. Estimate: ~60–90 min.

## Context
Your route-coverage map (docs/ROUTE_TEST_COVERAGE.md) leaves ~23 routes untested — mostly admin read-only lookups and public page endpoints. Close that gap.

## Work
1. In this clone, pull the latest staging tip first (git fetch origin staging; base your branch on it) — do NOT touch main.
2. From your coverage map, list the untested routes in the admin + public-page groups. Read their handlers and services.
3. Write pytest tests in the repo test layout (follow your auth/RevenueCat/practice/MCP tests for style/fixtures) covering, at minimum: happy-path responses, auth/permission behavior (admin endpoints must reject non-admin callers), and error handling for missing/invalid inputs. Mock all externals — no real credentials, no real network, no real user data.
4. If a route genuinely cannot be tested headlessly, do NOT force a brittle test — record it as untestable-with-reason in your report instead.
5. Run the new tests, then the related existing suite (or the nearest runnable subset if the full suite needs a live backend — record exactly what you ran). All new tests must pass; no existing test may newly fail.
6. Commit on branch fleet/kiro-admin-tests with a clear message and push to origin (the shared repo ~/workspace/ayma).

## Guardrails
- Tests only: do not change any production code. If a test exposes a real bug, record it in your report instead of fixing it.
- No real secrets, no live services, no staging/prod data. Nothing that creates a charge.

## Report
Append to ~/workspace/ayma-inbox/kiro.md an entry headed: ## <YYYY-MM-DD HH:MM PT> — From Kiro (Engineer) — DONE (or BLOCKED) with: number of new tests and what they cover, test-run results (new + existing suite), branch + commit, any real bugs surfaced, and any routes recorded untestable-with-reason.
