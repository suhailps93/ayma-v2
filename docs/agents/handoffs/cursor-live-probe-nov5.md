# Cursor daily CLI probe — Nov 5 (decisive method)

Date: 2026-11-05 09:13 PT (17:13 UTC)
Runner: Muse (Engineer — Deployment)
Method: decisive live ask, per 07:09 review / Nov 2 pattern

## Command

```
/home/suhailps/.local/bin/cursor-agent -p --trust --mode ask "Print the word READY and nothing else."
```

Binary resolves to `/home/suhailps/.local/share/cursor-agent/versions/2026.10.22-27dcf5f/cursor-agent`.

## Verdict: STILL-LIMITED

Live task failed on the usage limit. Exact error (exit 1):

```
ActionRequiredError: You've hit your usage limit Get Cursor Pro for more Agent usage, unlimited Tab, and more.
```

No trust or usage gate was bypassed. No upgrade, payment, or plan change made.

## Reset-date check

None of `status` / `about` / `models` shows a reset date.

- `cursor-agent status`: `✓ Logged in as suhailps@gmail.com` — no reset date.
- `cursor-agent about`: CLI Version 2026.10.22-27dcf5f (latest 2026.11.05-86047df noted, not installed), Model Auto, Subscription Tier Free, OS linux (x64), user suhailps@gmail.com — no reset date.
- `cursor-agent models`: model list only (current: auto) — no reset date.

Recorded: no reset date shown.
