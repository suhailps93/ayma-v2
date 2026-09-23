"""Gemini Batch API: two-phase submit/poll for purely-background, bulk cron
work where nobody is actively waiting on the result (§ cost review 2026-09).

Batch is 50% cheaper than a synchronous ``generate_content`` call, but the
trade is asynchrony: Google's own target is "usually much faster, but the
target turnaround is 24 hours, not a guarantee" (see
https://ai.google.dev/gemini-api/docs/batch-api and
https://cloud.google.com/vertex-ai/generative-ai/docs/model-reference/batch-prediction-api).
That is a bad trade for anything a user is actively waiting on — a deep-dive
search, a photo upload, a "regenerate my report" button — those stay on
``gemini.py``'s synchronous path. It is free money for a scheduled sweep
nobody is blocked on: submit today, apply whatever comes back whenever it
lands (this run, the next run, or the one after that).

This module only knows how to submit a batch of independent
``generate_json``-shaped requests (text in, one JSON object out per request)
to GCS and read a submitted job's results back once it is done. It has no
opinion on *when* Batch is the right call for a given cron sweep — that
judgment call belongs to each caller (see ``wiki_lint.py`` for the pattern:
poll a pending job once per cron tick; finalize it if done; submit a new one
if there's nothing pending).

On Vertex AI (this app's only configured backend — see ``config.py``'s
``use_vertex``), a batch job's *source* must be a GCS/BigQuery URI, not the
inline list of requests the Gemini Developer API batch endpoint accepts —
and Vertex gives back no per-line id to correlate a result with the request
that produced it. ``fetch_json_batch_results`` rebuilds the mapping purely
by line order, and refuses (raises) rather than guess if the result count
doesn't match what was submitted — a caller must never risk writing one
user's lint flags, attributes, etc. onto a different user.
"""

from __future__ import annotations

import json
import logging
import time
import uuid
from dataclasses import dataclass

from google.genai import types

import gemini
from config import CONFIG

logger = logging.getLogger("ayma.gemini_batch")

_INPUT_PREFIX = "gemini_batches"

_DONE_STATES = {
    types.JobState.JOB_STATE_SUCCEEDED,
    types.JobState.JOB_STATE_FAILED,
    types.JobState.JOB_STATE_CANCELLED,
    types.JobState.JOB_STATE_EXPIRED,
    types.JobState.JOB_STATE_PARTIALLY_SUCCEEDED,
}


def _bucket():
    from firebase_admin import storage

    return storage.bucket(CONFIG.storage_bucket)


def _schema_dict(response_schema: dict) -> dict:
    """The wire-format (uppercase-enum) schema Vertex's batch REST endpoint
    expects, built via the public ``types.Schema`` model so this doesn't have
    to reimplement the JSON-Schema -> proto-Schema mapping by hand."""
    return types.Schema.model_validate(response_schema).model_dump(
        mode="json", by_alias=True, exclude_none=True
    )


def _request_line(
    text: str,
    system_prompt: str,
    response_schema: dict,
    *,
    temperature: float,
    max_output_tokens: int,
) -> dict:
    request: dict = {
        "contents": [{"role": "user", "parts": [{"text": text}]}],
        "generationConfig": {
            "temperature": temperature,
            "maxOutputTokens": max_output_tokens,
            "responseMimeType": "application/json",
            "responseSchema": _schema_dict(response_schema),
        },
    }
    if system_prompt:
        request["systemInstruction"] = {"parts": [{"text": system_prompt}]}
    return {"request": request}


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
    """Submit one Gemini Batch job with one ``generate_json``-shaped request
    per entry in ``items`` (text only, no images — every current caller's
    content is plain text; a vision batch would need ``fileData`` GCS refs
    per line instead, not implemented since nothing needs it yet).

    Synchronous (Firestore/GCS/genai calls are all sync in this SDK) — call
    it via ``asyncio.to_thread`` from an async caller, same convention as the
    rest of this codebase's Firestore access.

    Callers must keep their own ordered list of what each line *is* (e.g. a
    parallel ``uids`` list) — Vertex's batch API has no per-line id, so
    ``fetch_json_batch_results`` can only hand results back in submission
    order.
    """
    if not items:
        raise ValueError("submit_json_batch: items is empty")
    lines = [
        json.dumps(
            _request_line(
                text, system_prompt, response_schema,
                temperature=temperature, max_output_tokens=max_output_tokens,
            )
        )
        for text in items
    ]
    stamp = time.strftime("%Y%m%d-%H%M%S")
    input_path = (
        f"{_INPUT_PREFIX}/{job_tag}/{stamp}-{uuid.uuid4().hex[:8]}/input.jsonl"
    )
    _bucket().blob(input_path).upload_from_string(
        "\n".join(lines), content_type="application/jsonl"
    )
    gcs_uri = f"gs://{CONFIG.storage_bucket}/{input_path}"

    job = gemini._client().batches.create(model=CONFIG.gemini_model, src=gcs_uri)
    dest = (
        getattr(job.dest, "gcs_uri", None) if job.dest else None
    ) or f"{gcs_uri[:-len('.jsonl')]}/dest"
    logger.info(
        "gemini batch submitted: tag=%s job=%s items=%d dest=%s",
        job_tag, job.name, len(items), dest,
    )
    return BatchSubmission(job_name=job.name, dest_prefix=dest, count=len(items))


def poll_json_batch(job_name: str):
    """One status check — never sleeps or loops. A batch job can take
    anywhere from minutes to Google's ~24h target, so nothing here should
    hold a request thread open waiting; callers poll once per their own cron
    tick instead (see ``wiki_lint.lint_all``)."""
    return gemini._client().batches.get(name=job_name)


def is_batch_done(job) -> bool:
    return job.state in _DONE_STATES


def is_batch_succeeded(job) -> bool:
    return job.state == types.JobState.JOB_STATE_SUCCEEDED


def _parse_result_row(row: dict) -> object | None:
    """One line of batch output: ``{"response": {...}}`` on success. Mirrors
    ``gemini.generate_json``'s text -> JSON parse, but best-effort per row: a
    row Ayma can't parse comes back ``None`` so the caller can skip just that
    one item instead of failing the whole batch over one bad row."""
    try:
        resp = row.get("response") or {}
        candidates = resp.get("candidates") or []
        parts = (candidates[0].get("content") or {}).get("parts") or []
        text = "".join(p.get("text", "") for p in parts).strip()
        return json.loads(text) if text else None
    except Exception:  # noqa: BLE001 - one bad row must not break the batch
        logger.warning("gemini batch: unparseable result row: %r", row)
        return None


def fetch_json_batch_results(dest_prefix: str, *, expected_count: int) -> list[object | None]:
    """Read a finished batch job's output back into a list of parsed JSON
    values, one per submitted item, in submission order.

    Lists every blob under ``dest_prefix`` (there is normally exactly one
    output ``.jsonl`` file for the modest volumes this codebase's cron
    sweeps submit; a job large enough to shard its output across several
    files would still concatenate them in name order, which Vertex numbers
    sequentially — ``...-00000-of-00002``, ``...-00001-of-00002`` — so
    lexicographic order is submission order there too).

    Raises ``RuntimeError`` if the number of result lines doesn't match
    ``expected_count``: a caller must never guess which item a result
    belongs to, so a count mismatch aborts the whole batch rather than risk
    writing a result onto the wrong user.
    """
    prefix = dest_prefix
    if prefix.startswith("gs://"):
        parts = prefix.split("/", 3)
        prefix = parts[3] if len(parts) > 3 else ""
    blobs = sorted(_bucket().list_blobs(prefix=prefix), key=lambda b: b.name)
    out: list[object | None] = []
    for blob in blobs:
        try:
            text = blob.download_as_text()
        except Exception:  # noqa: BLE001 - a stray non-text object under the
            # prefix (a folder marker, incidental metadata) shouldn't abort
            # the whole batch; the count check below still catches real drift
            logger.warning("gemini batch: skipping unreadable blob %s", blob.name)
            continue
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                logger.warning("gemini batch: skipping non-JSON line in %s", blob.name)
                continue
            out.append(_parse_result_row(row))
    if len(out) != expected_count:
        raise RuntimeError(
            f"gemini batch result count mismatch: got {len(out)}, expected "
            f"{expected_count} (dest={dest_prefix})"
        )
    return out
