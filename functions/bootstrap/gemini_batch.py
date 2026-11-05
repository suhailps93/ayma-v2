"""Gemini Batch API — DISABLED (founder rule 2026-11-04 — see
``docs/DIRECT_GOOGLE_KILL_AUDIT.md`` item 7).

Submitting or polling a Vertex batch job needs the direct-Google path, which
no longer exists, and the LiveKit gateway has no batch tier
(``/batches`` 404). :func:`submit_json_batch` and :func:`poll_json_batch`
raise instead of calling Google; the only caller (``wiki_lint.lint_all``,
behind ``POST /cron/lint``) reports ``{"status": "disabled", ...}``.
Founder-decision item: restore only with a LiveKit-served equivalent or an
explicit exception.
"""

from __future__ import annotations

from dataclasses import dataclass

import llm_routing


@dataclass
class BatchSubmission:
    job_name: str
    dest_prefix: str
    count: int


def submit_json_batch(
    items: list[str],
    system_prompt: str,
    response_schema: dict,
    *,
    job_tag: str,
    temperature: float = 0.2,
    max_output_tokens: int = 4096,
) -> BatchSubmission:
    """DISABLED: submitting a Vertex batch job needs the direct-Google path,
    which no longer exists. Raises instead of calling Google."""
    raise llm_routing.DirectGoogleDisabledError(
        "batch jobs are unavailable: Vertex batch needs direct Google, "
        "which is disabled — all inference goes through LiveKit"
    )


def poll_json_batch(job_name: str):
    """DISABLED: polling a Vertex batch job needs the direct-Google path,
    which no longer exists. Raises instead of calling Google."""
    raise llm_routing.DirectGoogleDisabledError(
        "batch jobs are unavailable: Vertex batch needs direct Google, "
        "which is disabled — all inference goes through LiveKit"
    )
