# Agent Fleet Workflow — binding on every agent (Claude, Claude-Bedrock, Muse, Codex, Gemini)

Set by the founder, 2026-10-31. Astro (Muse) is the PM who coordinates the fleet; these rules are how work moves between agents without loss.

## 1. Context lives in the repo
- All shared context, rules, and skills live **in this repository, committed and pushed** — never only in one agent's session. If you learn something the fleet needs, write it into `AGENTS.md`, `PLAN.md`, or `docs/agents/` and commit it.
- Every session starts by reading, in order: `AGENTS.md` → `docs/agents/CONTEXT_PACK.md` → this file → `PLAN.md` (Progress Log for the next step).

## 2. Branch + worktree per task; cleanup on merge is the DEFAULT
- One task = one branch (off `staging` unless told otherwise) = one worktree. Never work in another agent's worktree.
- **The moment your branch is merged, delete the branch and remove your worktree.** No exceptions, no "keep it just in case" — merged work lives in the target branch; anything else belongs in a handoff note (§3). This rule exists because un-merged cleanup debt once reached 245 worktrees / 185 GB and slowed the whole machine.
- If you abandon a task unmerged: say so in your handoff note (branch name + what's in it + why). Astro triages; nobody silently accumulates worktrees.

## 3. Token limits → handoff, never purchase
- **No agent — including Astro — has authority to purchase tokens, credits, top-ups, or subscriptions.** Ever. Work runs only on capacity that already exists: plan allowances (Claude Max, ChatGPT), granted credits (AWS Activate on Bedrock, Meta Model API credit, Modal), and existing API accounts.
- When you hit a token/usage limit mid-task: STOP cleanly. Commit or stash your work, then write `docs/agents/handoffs/<task-slug>.md` with: branch, worktree, step done, step next, any uncommitted state, and gotchas. Astro re-delegates the task to an agent with capacity; the handoff note is how the next agent starts without loss.
- If everything is exhausted, the work waits for a reset — it does not get bought around.

## 4. Ownership lines
- **Claude** (claude.ai Ayma master): repo discipline, PLAN steps, deploys in flight.
- **Claude-Bedrock** (Claude Code on Bedrock): overflow + parallel engineering when Claude is limited or busy.
- **Muse** (Muse Spark): Meta-model work, second opinions, Claude-swap checks (pin muse-spark-1.3; never a `-contributor` model).
- **Codex**: independent implementation + review passes.
- **Gemini**: research-heavy and large-context passes; run via `~/.local/bin/gemini-ayma` from inside the task's worktree (not the repo root — file scanning stalls there).
- **Astro**: plans, priorities, delegation, testing (Astro owns ALL app testing), verification, and the founder line. Only Astro talks to the founder about queue/decisions.

## 5. Non-negotiables (from AGENTS.md + founder rulings)
- Production model default is **Gemini**; Meta models are default only in the meta-hackathon build (see CONTEXT_PACK.md).
- One PLAN step per commit; test → Astro verifies → commit.
- Never click a final hackathon/store submission — the founder's explicit GO is required.
- Payments/charges: never. Secrets: Secret Manager / vault only, never in code, commits, or logs.
