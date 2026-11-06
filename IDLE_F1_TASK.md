# TASK — Investigate note-114 F1: warm-call silent ends fire early (17.8-22.9s vs 30s spec)

From Astro (PM). You are Kiro (Engineer). Your admin-tests chunk is DONE — this is your follow-on. Estimate: 60-90 min.

## Context (Scout note 114, voice idle-timeout retest on build 2308)
- Legs 1/2/3/5/7 PASS. F1 (MEDIUM): on REPEAT (warm) voice calls, the silent-end fires 17.8-22.9s after the live log line, vs the 30s spec. The reset mechanism is exact twice over (a finalized input resets the timer and it fires at exactly +30.0/30.1s).
- The warm-path early-arm theory was DISPROVEN by code: the arm flag resets in start(), and there is a single arm site at live. Remaining candidates: (a) the live-log-line timestamp lags the real arm, i.e. measurement lag, or (b) the timer genuinely fires early on warm calls.
- The tour fix (2318) is unrelated — do not touch tour code.

## Work
1. In this clone, pull the latest staging tip first; base your branch on it. Do NOT touch main.
2. Find the idle-timeout implementation in the voice agent (functions/bootstrap/ — the 30s silent-end timer, its arm/reset sites, and the live log line it is measured against).
3. Instrument the warm-call initial arm: log the arm timestamp, the live-log-line timestamp, and the fire timestamp on a warm call, so the two candidates can be separated.
4. Determine the root cause with evidence: measurement lag (show the timestamp deltas) or a genuinely early fire (show the mechanism).
5. If it is a real early fire: fix it and add a regression test covering a warm call (second call in the same session) asserting the silent end lands at about 30s, not early. If it is measurement lag: file the findings with the evidence instead of changing code.
6. If you fix: commit on branch fleet/kiro-idle-f1 with a clear message and push to origin. If findings-only: no commit needed — the report is the deliverable.

## Guardrails
- No device testing — Scout owns on-device retests if a fix lands. No real secrets, no live services, no staging/prod data. Nothing that creates a charge.
- Do not change the 30s spec or any tour code.

## Report
Append to ~/workspace/ayma-inbox/kiro.md an entry headed with the timestamp and From Kiro (Engineer) — DONE (or BLOCKED) with: root cause (measurement lag vs early fire, with the evidence), fix or findings, regression test if any, branch plus commit if any, and what Scout should retest on-device if a fix lands.
