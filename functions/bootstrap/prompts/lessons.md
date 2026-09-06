<!--
Behavioural corrections learned from aggregated user feedback (ARCHITECTURE.md
§15). This file is APPENDED to the composed system prompt at runtime, after the
base persona — the persona itself is never rewritten automatically.

How it changes: the weekly /ayma-feedback-review skill clusters `feedback` rows
and DRAFTS additions here with rationale + the feedback ids they address. A
human reviews/edits/rejects, and a candidate must beat the current file on the
curated eval set before it merges. Keep it to ~15 bullets max; prune stale ones.

Lines that are blank or start with "#" or "<!--" are ignored. Real corrections
are "- " bullets below.
-->
