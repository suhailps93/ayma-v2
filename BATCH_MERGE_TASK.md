# TASK — Batch-merge the fleet test/doc branches to staging (one merge, one versionCode bump)

From Astro (PM). You are Kiro (Engineer). Your MCP tests are DONE (66 tests, a3e3d4b8) — this is your follow-on. Estimate: ~60–90 min.

## Context
Eight fleet branches are pushed to ~/workspace/ayma but unmerged, so their tests/docs are not in staging: fleet/kiro-auth-tests (856b10ed), fleet/kiro-revenuecat-tests (0a2eadb6), fleet/kiro-route-test-coverage (d2ebb4e8), fleet/kiro-practice-tests (3e0782fd), fleet/kiro-mcp-tests (a3e3d4b8), fleet/opencode-api-inventory (4c60af8b), fleet/aider-range-report (09bb1d8b), fleet/aider-deploy-notes (c5ed9901). Merge them all into staging in ONE merge, with ONE versionCode bump.

## Work
1. In this clone, pull the latest staging tip first (git fetch origin staging; base on it) — do NOT touch main.
2. For each branch, verify its tests pass on its own tip first (run the branch's new tests; if a branch's tests fail, leave that branch OUT and record it as excluded-with-reason — do not fix other agents' code).
3. Merge the ready branches into staging one at a time in your clone, resolving any conflicts (they should be additive: tests + docs). Run the full backend test suite and flutter analyze + the affected Flutter tests after all merges. Everything must be green.
4. Bump versionCode exactly +1 from the staging tip at the time of merge (expect 2317 — verify the tip, do not assume).
5. Push the merged staging branch to origin (the shared repo ~/workspace/ayma — this clone's origin). Do NOT push to GitHub; the watcher deploys from the shared repo.

## Guardrails
- Tests + docs only: if any branch contains production-code changes, EXCLUDE it and record why — do not merge prod changes in this batch.
- No new features, no model/provider changes. Nothing that creates a charge.

## Report
Append to ~/workspace/ayma-inbox/kiro.md an entry headed: ## <YYYY-MM-DD HH:MM PT> — From Kiro (Engineer) — DONE (or BLOCKED) with: branches merged (with commits), branches excluded with reason, test-suite results, the new staging tip + versionCode, and confirmation the push landed in ~/workspace/ayma.
