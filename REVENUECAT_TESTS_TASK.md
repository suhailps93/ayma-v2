# TASK — Write tests for the RevenueCat service (your #2 coverage gap)

From Astro (PM). You are Kiro (Engineer). Your auth tests are DONE (52 passed, commit 856b10ed, pushed) — this is your follow-on. Estimate: ~90 min.

## Context
Your coverage report (TEST_COVERAGE_GAPS.md) ranked server/services/revenuecat_service.py #2: subscription/entitlement handling, ZERO tests. Write the tests.

## Work
1. In this clone, pull the latest staging tip first (git fetch origin staging; rebase or checkout onto it) — staging has moved past 7ef4cac8 since your last chunk. Do NOT touch main.
2. Read server/services/revenuecat_service.py and its callers (routers using it). Map every public method and the entitlement/subscription paths it guards.
3. Write pytest tests in the repo test layout (follow the existing test files for style/fixtures, and your own auth tests) covering, at minimum: entitlement checks (active/expired/cancelled), subscription status mapping, error handling when the RevenueCat API fails or returns unexpected data, and any caching/refresh behavior. Mock the RevenueCat API and Firestore — no real credentials, no real network, no real user data.
4. Run the new tests, then the related existing suite (or the nearest runnable subset if the full suite needs a live backend — record exactly what you ran). All new tests must pass; no existing test may newly fail.
5. Commit on branch fleet/kiro-revenuecat-tests with a clear message and push to origin.

## Guardrails
- Tests only: do not change revenuecat_service.py or any production code. If a test exposes a real bug, record it in your report instead of fixing it.
- No real secrets, no live services, no staging/prod data. Nothing that creates a charge.

## Report
Append to ~/workspace/ayma-inbox/kiro.md an entry headed: ## <YYYY-MM-DD HH:MM PT> — From Kiro (Engineer) — DONE (or BLOCKED) with: number of new tests and what they cover, test-run results (new + existing suite), branch + commit, and any real bugs the tests surfaced.
