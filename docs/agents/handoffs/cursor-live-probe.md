# Cursor live inference probe — 2026-11-02

Branch: `muse/cursor-live-probe` (off origin/staging). Report only; no app code, no env/service changes.
Follow-up to `muse/probes-sweep` @ 4727948, which left Cursor agent-quota state UNVERIFIED.

## Probe

One small live task through the cursor-agent CLI (full-path binary; TOOLS.md was not
present in this worktree, so the path below was located via the install dir):

```
time /home/suhailps/.local/bin/cursor-agent -p --trust --mode ask \
  --workspace /home/suhailps/workspace/ayma/.fleet-worktrees/cursor-live-probe \
  "List the top-level files and directories in this repo, one line each with a \
very brief description. Keep the whole answer under 15 lines." </dev/null 2>&1
```

- `-p` = non-interactive print mode; `--mode ask` = read-only Q&A (no edits possible).
- `--trust` was required: the first attempt without it exited 1 with a "Workspace Trust
  Required" prompt (trust gate, NOT a quota error). Full text of that first failure is
  in the inbox entry trail, not repeated here.

## Full output (exit 1, ~3.5s)

```
ActionRequiredError: You've hit your usage limit Get Cursor Pro for more Agent usage, unlimited Tab, and more.
Command exited with non-zero status 1
```

## Account context (read-only, no inference)

- `cursor-agent status`: logged in as suhailps@gmail.com
- `cursor-agent about`: CLI 2026.10.22-27dcf5f (up to date), Subscription Tier Free,
  Model Auto, OS linux (x64)
- `cursor-agent models`: list OK (auto, gpt-5.3-codex family, composer-2.5,
  claude-opus-5-thinking-high, …)
- No reset date shown by `status`, `about`, `models`, or the error itself.

## Verdict: STILL-LIMITED

The live task did NOT complete. The agent quota errors immediately on any inference
with `ActionRequiredError: You've hit your usage limit` + a Cursor Pro upsell, and no
stated reset date or limit details. Do NOT assign Cursor real chunks until the Free-tier
usage resets (date unknown — not surfaced by the CLI) or the account is upgraded.
