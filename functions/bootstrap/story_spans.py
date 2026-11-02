"""Private / AI-only inline spans within a Story body.

Tier-2 sweep monolith split #12: the ``--- private spans ---`` section of the
former ``story.py`` monolith, moved verbatim — no behavior change.
"""

from __future__ import annotations

import logging
import re

import report_blocks as rb
from story_common import (
    AI_ONLY_CLOSE,
    AI_ONLY_OPEN,
    PRIVATE_CLOSE,
    PRIVATE_OPEN,
    _SPAN_RE,
)

logger = logging.getLogger("ayma.story")


def parse_spans(body: str) -> list[dict]:
    """Split a body into ``[{"text", "kind"}]`` runs by its markers, where
    ``kind`` is one of ``"public"`` / ``"private"`` / ``"ai_only"``. Public,
    not just an internal helper: ``report_adapters.py`` and ``report_hub.py``
    both need it too (via :func:`sentence_spans`) so that a Living Report
    ``text`` block never shows a raw ``{{private}}``/``{{ai_only}}`` marker.

    Two independent depth counters (one per marker type) rather than a
    general nested-span stack — mirrors the original single-counter
    private-only design. Spans of either kind are always flat and
    non-overlapping in practice (every span is written by
    :func:`apply_span_action`, which never nests one kind inside the other),
    so this is enough; if a body ever did have ``ai_only`` opened while
    ``private`` is also open, ``ai_only`` wins (it's the more-hidden state).
    """
    segments: list[dict] = []
    priv_depth = 0
    ai_depth = 0
    pos = 0

    def _kind() -> str:
        if ai_depth > 0:
            return "ai_only"
        if priv_depth > 0:
            return "private"
        return "public"

    for m in _SPAN_RE.finditer(body or ""):
        chunk = body[pos : m.start()]
        if chunk:
            segments.append({"text": chunk, "kind": _kind()})
        tok = m.group()
        if tok == PRIVATE_OPEN:
            priv_depth += 1
        elif tok == PRIVATE_CLOSE:
            priv_depth = max(0, priv_depth - 1)
        elif tok == AI_ONLY_OPEN:
            ai_depth += 1
        elif tok == AI_ONLY_CLOSE:
            ai_depth = max(0, ai_depth - 1)
        pos = m.end()
    tail = (body or "")[pos:]
    if tail:
        segments.append({"text": tail, "kind": _kind()})
    return segments


def _serialize_spans(segments: list[dict]) -> str:
    merged: list[dict] = []
    for seg in segments:
        if not seg["text"]:
            continue
        if merged and merged[-1]["kind"] == seg["kind"]:
            merged[-1]["text"] += seg["text"]
        else:
            merged.append({"text": seg["text"], "kind": seg["kind"]})
    out = []
    for seg in merged:
        if seg["kind"] == "private":
            out.append(PRIVATE_OPEN + seg["text"] + PRIVATE_CLOSE)
        elif seg["kind"] == "ai_only":
            out.append(AI_ONLY_OPEN + seg["text"] + AI_ONLY_CLOSE)
        else:
            out.append(seg["text"])
    return "".join(out)


def strip_private_spans(text: str) -> str:
    """The body with every non-``public`` span (``private`` or ``ai_only``,
    and its content) removed — what the public profile and the Public view
    show."""
    plain = "".join(
        s["text"] for s in parse_spans(text or "") if s["kind"] == "public"
    )
    return re.sub(r"\n{3,}", "\n\n", plain).strip()


def strip_ai_only_spans(text: str) -> str:
    """The body with only its ``ai_only`` spans (and their content) removed —
    ``private`` spans are kept (still shown, dimmed), since this backs the
    normal editor "Story" view: it must exclude ai-only material but still
    shows private-but-visible-to-the-user passages. Only "Ayma's Notes"
    (:func:`get_ai_notes`) gets the raw, unstripped body."""
    kept = [s for s in parse_spans(text or "") if s["kind"] != "ai_only"]
    out = _serialize_spans(kept)
    return re.sub(r"\n{3,}", "\n\n", out).strip()


def sentence_spans(body: str) -> list[dict]:
    """``body`` broken into ``[{"text", "kind"}]`` sentence-ish pieces —
    :func:`parse_spans` first (so a span's ``{{private}}``/``{{ai_only}}``
    delimiters never end up inside a piece's ``text``), then each span's
    plain text through :func:`report_blocks.split_sentences`. ``kind`` is
    ``"public"``/``"private"``/``"ai_only"``, carried onto every piece cut
    from that span.

    THE canonical way to turn a Story body into indexable sentence-level
    pieces — both the Living Report Story adapters
    (``report_adapters.story_*_blocks``, via ``_story_section_blocks``) and
    the correction router (``report_hub._correct_story_page``) use this, so
    a block's ``page:<id>:sent:<n>`` index always names the same passage in
    both places. For a body with no markers at all (the common case) this is
    exactly ``rb.split_sentences(body)`` with every piece tagged
    ``"public"`` — unchanged from before spans existed. Only a body that
    actually has a ``{{private}}``/``{{ai_only}}`` span splits differently
    (at the span boundary too, in addition to sentence punctuation) — never
    a raw marker leaking into a piece's displayed text is worth that."""
    out: list[dict] = []
    for seg in parse_spans(body or ""):
        for piece in rb.split_sentences(seg["text"]):
            out.append({"text": piece, "kind": seg["kind"]})
    return out


def apply_span_action(body: str, selection: str, action: str) -> str:
    """Wrap / unwrap / delete exactly ``selection`` within ``body``, keeping
    span markers well-formed. ``action`` is ``private`` | ``public`` |
    ``ai_only`` | ``delete``. A selection that isn't found leaves the body
    untouched."""
    if not selection or action not in ("private", "public", "ai_only", "delete"):
        return body
    segments = parse_spans(body)
    plain = "".join(s["text"] for s in segments)
    idx = plain.find(selection)
    if idx < 0:
        return body
    start, end = idx, idx + len(selection)

    new_segments: list[dict] = []
    cursor = 0
    for seg in segments:
        t = seg["text"]
        lo = max(0, min(len(t), start - cursor))
        hi = max(0, min(len(t), end - cursor))
        cursor += len(t)
        before, middle, after = t[:lo], t[lo:hi], t[hi:]
        if before:
            new_segments.append({"text": before, "kind": seg["kind"]})
        if middle and action != "delete":
            new_segments.append({"text": middle, "kind": action})
        if after:
            new_segments.append({"text": after, "kind": seg["kind"]})
    return _serialize_spans(new_segments)
