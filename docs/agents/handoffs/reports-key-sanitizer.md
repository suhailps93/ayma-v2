# reports-key-sanitizer handoff

## Status

Blocked: the requested Practice Date / Muse Spark report-generation path is not
present on this staging-aligned branch (`fix/reports-key-sanitizer` at
`b6af7ce`).

## What I checked

- Searched the FastAPI backend for `practice date`, `practice_date`, `debrief`,
  `strengths`, report parsing, and JSON-to-schema mapping.
- The branch has face/body/appearance report code, including `strengths`
  handling in `functions/bootstrap/face_report.py` and
  `functions/bootstrap/body_report.py`, but no Practice Date report or debrief
  implementation.
- No Muse Spark provider path was found in the backend. The only mention of the
  Meta hackathon implementation is in `docs/agents/CONTEXT_PACK.md`, which
  identifies a separate `meta-hackathon` branch/repository context.

## Files changed

- `docs/agents/handoffs/reports-key-sanitizer.md` (this handoff only)

## Tests

- Not run: no applicable code path exists on this branch, so no sanitizer or
  regression test was added.

## Commit and push

- Not completed: this environment cannot create the worktree Git index lock at
  `/home/suhailps/workspace/ayma/.git/worktrees/sanitizer/index.lock` because
  that path is read-only. The handoff remains uncommitted in this worktree.

## What remains

Apply the recursive parsed-JSON key normalization and trailing-whitespace-key
regression test on the branch/repository that contains the Practice Date Muse
Spark report mapper (likely the Meta hackathon codebase), then run that
report's focused backend tests.
