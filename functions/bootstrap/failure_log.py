"""``failure_log`` — the per-user record of what Ayma tried that failed
(founder order 2026-11-09, ~08:34 PT).

When a backend tool/skill action fails for a user — an exception, a
provider error, a permission refusal, a failed app command — one compact
record is written for THAT user: the time, what was attempted (the tool
name), and the decisive error line: the exact underlying error text,
trimmed to at most one or two lines. No stack traces (when a trace is
all we have, only its final, causal line is kept) and nothing that looks
like a credential, key, or token is ever stored.

The records exist for one reader: analysis mode (``analysis_mode.py``).
A user in that mode can ask why something failed and Ayma quotes the
recorded line exactly — one or two lines, nothing longer — instead of
the vague paraphrase she had to improvise before this existed (founder,
2026-11-09 ~08:27 PT: image generation failed and all she could say was
"a service permission issue on my end" — the real provider error line
is what analysis mode quotes now). Where nothing was recorded she says
so plainly; the mode's honesty rule forbids inventing a cause.

Storage: ``users/{uid}/failure_log`` — a per-user subcollection, the
same shape as the analysis-mode gate state (``users/{uid}/
analysis_mode/state``), so a record is structurally only ever reachable
through its owner's uid. Capped at the newest :data:`MAX_RECORDS` per
user; older records are pruned on write.

Capture points (see ``skills/__init__.py``): every bound tool callable
on both surfaces passes through one wrapper — text via
``make_session_tool_fns``, voice via ``make_livekit_tools`` — which
records raised exceptions, results in the dispatch layer's own
``error:`` form (the shape ``gemini.py`` and the voice timeout bound
already produce), and app-control results that did not navigate (the
codebase's own definition of a failed app command, ``tool_labels``).
Skills that swallow a provider exception into a soft reply string
(``generate_image`` / ``edit_photo``) call :func:`record_failure`
directly at the failure site so the RAW provider line is what lands
here, not the paraphrase.
"""

from __future__ import annotations

import logging
import re
from datetime import datetime, timezone

logger = logging.getLogger("ayma.failure_log")

MAX_RECORDS = 50

_MAX_LINES = 2
_MAX_LINE_CHARS = 300

# --- credential stripping -----------------------------------------------------
# Anything that looks like a credential, key, or token is redacted BEFORE
# a line is stored — a failure record must never become a secret store.
# Deliberately conservative patterns: provider keys, bearer/authorization
# values, ``key=value`` secret pairs, JWTs, and long opaque blobs.

_GOOGLE_KEY = re.compile(r"AIza[0-9A-Za-z\-_]{10,}")
_PROVIDER_KEY = re.compile(r"\b(?:sk|xai)-[A-Za-z0-9\-_]{8,}")
_JWT = re.compile(r"\beyJ[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+")
_BEARER = re.compile(
    r"(?i)\b(bearer|authorization)\b\s*[:=]?\s*(?:bearer\s+)?[A-Za-z0-9\-._~+/=]+"
)
_KV_SECRET = re.compile(
    r"(?i)\b(api[_-]?key|apikey|secret|access[_-]?token|auth[_-]?token|token|"
    r"password|passwd)\b\s*[:=]\s*\S+"
)
_LONG_BLOB = re.compile(r"\b[A-Za-z0-9+=_-]{40,}\b")


def sanitize(text: str) -> str:
    """Redact credential-looking values from ``text`` (labels are kept,
    values become ``[redacted]``)."""
    out = _GOOGLE_KEY.sub("[redacted]", text)
    out = _PROVIDER_KEY.sub("[redacted]", out)
    out = _JWT.sub("[redacted]", out)
    out = _BEARER.sub(lambda m: f"{m.group(1)} [redacted]", out)
    out = _KV_SECRET.sub(lambda m: f"{m.group(1)}=[redacted]", out)
    out = _LONG_BLOB.sub("[redacted]", out)
    return out


def decisive_lines(text: str) -> str:
    """The decisive one-or-two lines of an error text.

    A traceback-shaped text keeps only its final line — the exception
    itself, which is the causal line; anything else keeps its first
    :data:`_MAX_LINES` non-empty lines. Each line is length-capped so a
    provider's wall-of-text error still lands as a quotable line."""
    lines = [ln.strip() for ln in str(text or "").splitlines()]
    lines = [ln for ln in lines if ln]
    if not lines:
        return ""
    traceback_shaped = any(
        ln.startswith("Traceback") or ln.startswith('File "') for ln in lines
    )
    picked = lines[-1:] if traceback_shaped else lines[:_MAX_LINES]
    return "\n".join(ln[:_MAX_LINE_CHARS] for ln in picked)


def _error_line(error: object) -> str:
    """The stored error text for an exception or an error string."""
    if isinstance(error, BaseException):
        text = str(error) or type(error).__name__
    else:
        text = str(error or "")
    return sanitize(decisive_lines(text))


def _collection(db, uid: str):
    return db.collection("users").document(uid).collection("failure_log")


def _stamp(snap) -> str:
    value = (snap.to_dict() or {}).get("at")
    return value.isoformat() if hasattr(value, "isoformat") else str(value or "")


def _prune(coll) -> None:
    """Keep only the newest :data:`MAX_RECORDS` records (best-effort)."""
    try:
        snaps = list(coll.stream())
    except Exception:  # noqa: BLE001 - pruning must never fail a write
        return
    snaps.sort(key=_stamp, reverse=True)
    for snap in snaps[MAX_RECORDS:]:
        try:
            snap.reference.delete()
        except Exception:  # noqa: BLE001
            logger.exception("failure log prune failed")


def record_failure(db, uid: str, action: str, error: object, surface: str = "") -> bool:
    """Write one failure record for this user. NEVER raises — a failure
    to record a failure must not break the turn that already failed.

    ``error`` is the exception or error text; what lands is the trimmed,
    sanitized decisive line (see :func:`decisive_lines`). Returns True
    when a record was written."""
    if db is None or not uid or not action:
        return False
    line = _error_line(error)
    if not line:
        return False
    try:
        coll = _collection(db, uid)
        coll.add(
            {
                "action": str(action),
                "error": line,
                "surface": str(surface or ""),
                "at": datetime.now(timezone.utc).isoformat(),
            }
        )
        _prune(coll)
    except Exception:  # noqa: BLE001
        logger.exception("failure record write failed for %s (%s)", uid, action)
        return False
    return True


def recent_failures(
    db, uid: str, limit: int = 10, topic: str = ""
) -> list[dict]:
    """This user's failure records, newest first — ``{action, error, at,
    surface}`` dicts. ``topic`` (the user's own words for the thing that
    failed, e.g. "image") keeps only records whose action or error text
    mentions one of its words, so "why did the image fail" returns the
    image-generation failure and not the whole log. Reads ONLY the
    given user's own subcollection — there is no cross-user path."""
    try:
        snaps = list(_collection(db, uid).stream())
    except Exception:  # noqa: BLE001 - a read failure reads as no records
        logger.exception("failure record read failed for %s", uid)
        return []
    rows = []
    for snap in snaps:
        data = snap.to_dict() or {}
        rows.append(
            {
                "action": str(data.get("action") or ""),
                "error": str(data.get("error") or ""),
                "at": _stamp(snap),
                "surface": str(data.get("surface") or ""),
            }
        )
    rows.sort(key=lambda r: r["at"], reverse=True)
    if topic:
        tokens = [
            t for t in re.split(r"[^a-z0-9]+", str(topic).lower()) if len(t) >= 3
        ]
        if tokens:
            def _matches(row: dict) -> bool:
                hay = (row["action"].replace("_", " ") + " " + row["error"]).lower()
                return any(t in hay for t in tokens)

            rows = [r for r in rows if _matches(r)]
    return rows[: max(0, int(limit))]
