# Agent Rules

> Copy this file in as `AGENTS.md` at the root of the new workspace. `AGENTS.md` is the tool-agnostic convention for agent instructions — Codex CLI reads it natively, and it's the file to point any other tool at (Claude Code, Gemini CLI, Cursor, etc. — see the pointer-file note at the bottom). Every rule here applies **regardless of which tool is currently driving.**

## Read this first, every session

Before writing any code: read this file, then `PLAN.md` in full, then its Progress Log to find the next unstarted step. Never resume from memory, from a chat summary, or from assumption — `PLAN.md` and this file are the source of truth for what to build and how, no matter which tool opened the session.

## The five engineering principles

1. **Think before coding.** Do not make assumptions. State assumptions explicitly before starting, and if a request is ambiguous, pause and ask rather than guess.
2. **Simplicity first.** Write the minimum code necessary. No speculative features, no over-engineering, no abstractions built for a single use.
3. **Surgical changes.** Touch only what the current step requires. Do not "improve" adjacent code, refactor things that aren't broken, or reformat anything not explicitly part of the task.
4. **Goal-driven execution.** Every step in `PLAN.md` already states its own success criterion (the "Test:" line) — treat that as the definition of done, not a suggestion.
5. **Production-ready code only.** No temporary hacks, no workaround code with a plan to "fix it properly later." No commented-out or dead code left in source files. Every async/future error path is explicitly caught and handled. A step marked `(stub)` in `PLAN.md` describes reduced *scope* (a deliberately simple first version, upgraded later), never reduced *quality* — a stub is still fully production-ready for what it does.

## Never diverge from the plan without approval

If implementation reveals that a decision in `PLAN.md` or `docs/ARCHITECTURE.md` is wrong, incomplete, or blocked: **stop and ask the user.** Do not silently implement something different, and do not silently work around it. Only after the user explicitly approves a change do you edit the relevant document to reflect it — and only then resume implementation against the updated version.

## Data & credentials

- **No mock databases, no `USE_MOCK_DB` flags, no SQLite/local-database fallbacks.** Firestore is the only data layer, in every environment — local dev included.
- **No hardcoded credentials, ever** — not API keys, not passwords, not service-account JSON, not as a "temporary" inline value, not in a comment. Locally, secrets load from a gitignored `.env.local`/`.env` via `python-dotenv`, loaded at the top of the entrypoint file, skipped when running unit tests to preserve test isolation. Deployed, they come only from Google Secret Manager, mounted into Cloud Run — never a plaintext env var in a deploy config. If a step needs a credential that doesn't exist yet, stop and ask the user for it; never invent, stub, or commit a placeholder key.
- **No prompts embedded inside code files.** Every prompt template lives as its own text/markdown file (e.g. under a `prompts/` directory or as `persona.py`/`.md` per `docs/ARCHITECTURE.md` §13.4) and is loaded dynamically — never an inline string literal in a Python or Dart file.
- **No hardcoded model names anywhere except `functions/bootstrap/config.py`.** All Gemini model strings flow from that one file. If a model name is needed and `config.py` hasn't provided it, throw — never substitute a hardcoded default.

## Process: test, commit, log — every step, no exceptions

1. Implement exactly one step from `PLAN.md`.
2. Stop. Tell the user precisely what to test and how (the step's own "Test:" line is the baseline — restate it concretely against what was actually built).
3. Wait for explicit confirmation the test passed. If it fails, fix it and ask again — never move on regardless.
4. Once confirmed: commit (one commit per passing step, message referencing the step number).
5. Append one row to `PLAN.md`'s Progress Log (date, step, commit) — never edit or delete a prior row.
6. Only then start the next step.

## Operating handbook

Read `docs/AGENT_HANDOFF.md` after this file and `PLAN.md`: architecture, the founder's working style, deploy/build/adb runbooks, agent orchestration, how to drive Muse and Hark, and the current state and question queue. Rules stay in this file; the handoff holds the details (no secrets, ever).

### Default delegation (founder standing rule, do not make the founder repeat it)

- Delegate every delegable task: **Muse** (muse.ai via chrome-devtools) for anything in a browser or vendor console, research, billing checks and applications; **Gemini** (`gemini-mcp`, also the deepseek and codex MCPs) for drafting simple code, analysis and summaries; background or worktree **Claude agents** for app code, builds, deploys and installs.
- Run all work as parallel agents so the main thread never blocks and stays free for the founder. The main thread only coordinates and talks to the founder.
- Ask the founder one short question at a time; hold agent results while a question is pending. Details and runbooks: `docs/AGENT_HANDOFF.md`; live queue: `docs/TODO_QUEUE.md`.

## Using this file from a specific tool

If the active tool expects its own filename (`CLAUDE.md`, `.cursor/rules`, `GEMINI.md`, etc.), that file should do nothing but point here: *"Read `AGENTS.md` and `PLAN.md` at the repo root before doing anything else; follow them exactly."* Keep all actual rules and plan content in `AGENTS.md`/`PLAN.md` only — a tool-specific file that duplicates rules instead of pointing to these two will drift out of sync the first time one gets edited and not the other.
