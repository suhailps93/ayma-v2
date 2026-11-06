# TASK — Write tests for the MCP OAuth server endpoints (your next coverage gap)

From Astro (PM). You are Kiro (Engineer). Your practice-date tests are DONE (29 new, ~176/199, commit 3e0782fd) — this is your follow-on. Estimate: ~90 min.

## Context
Your route-coverage map found mcp_server.py OAuth endpoints untested (7): /mcp/oauth/revoke, /mcp/.well-known/* (2), /mcp/connect/approve, /mcp/connect/pending, /mcp/connect/tokens, /mcp/connect/tokens/revoke. Core device grant + token endpoints are already covered — these are the remaining OAuth server paths.

## Work
1. In this clone, pull the latest staging tip first (git fetch origin staging; base your branch on it) — do NOT touch main.
2. Read server mcp_server.py (or wherever the MCP OAuth server lives) and its callers. Map every public method and the auth/token paths it guards.
3. Write pytest tests in the repo test layout (follow your auth, RevenueCat, and practice tests for style/fixtures) covering, at minimum: token revoke (valid/invalid/expired tokens), the .well-known endpoints, connect approve/pending/tokens flows, and error handling when the backing store or token service fails. Mock all externals — no real credentials, no real network, no real user data.
4. If an endpoint genuinely cannot be tested headlessly (needs a live backend/session), do NOT force a brittle test — record it as untestable-with-reason in your report instead.
5. Run the new tests, then the related existing suite (or the nearest runnable subset if the full suite needs a live backend — record exactly what you ran). All new tests must pass; no existing test may newly fail.
6. Commit on branch fleet/kiro-mcp-tests with a clear message and push to origin.

## Guardrails
- Tests only: do not change any production code. If a test exposes a real bug, record it in your report instead of fixing it.
- No real secrets, no live services, no staging/prod data. Nothing that creates a charge.

## Report
Append to ~/workspace/ayma-inbox/kiro.md an entry headed: ## <YYYY-MM-DD HH:MM PT> — From Kiro (Engineer) — DONE (or BLOCKED) with: number of new tests and what they cover, test-run results (new + existing suite), branch + commit, any real bugs surfaced, and any endpoints recorded untestable-with-reason.
