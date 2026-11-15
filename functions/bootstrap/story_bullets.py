"""Bullet view over a Your Story page body.

The story-sections / person-graph redesign (founder order Nov 14) makes every
piece of story content a **bullet** — one idea, individually tagged
``public`` / ``private`` / ``ai_only`` (Ayma-only). This module is the
**read-time split / write-time compose** layer that presents an existing page
body as bullets and turns an edited bullet list back into a body, WITHOUT a
separate store or a migration: a bullet maps 1:1 onto the existing
``{{private}}`` / ``{{ai_only}}`` span model (``story_spans``), so
``public_profile``, ``get_ai_notes`` and ``wiki_query.read_wiki_context`` keep
working unchanged.

Visibility model (the single rule that delivers "public profile shows only
public bullets", "empty/all-private section hidden from public", and
"Relationships private-by-default, surfaces only via a public bullet"):

* A bullet's **effective** visibility is its span kind clamped by the page's
  own visibility, in publicness order ``public > private > ai_only``. On a
  private page an un-wrapped sentence is private, not public; on an ai_only
  page everything is ai_only.
* **Compose** sets the page visibility to the most-public bullet present
  (public if any public bullet, else private if any private, else ai_only),
  wraps every ``private`` bullet in ``{{private}}`` and every ``ai_only``
  bullet in ``{{ai_only}}``, and leaves ``public`` bullets plain. So a section
  with no public bullet composes to a private (or ai_only) page and drops out
  of the public profile automatically.
"""

from __future__ import annotations

import hashlib
import re

from story_common import (
    AI_ONLY_CLOSE,
    AI_ONLY_OPEN,
    PRIVATE_CLOSE,
    PRIVATE_OPEN,
    VIS_AI_ONLY,
    VIS_PRIVATE,
    VIS_PUBLIC,
)
from story_spans import parse_spans

# Publicness order — a smaller number is more public. Used both to clamp a
# bullet by its page and to pick a page's visibility from its bullets.
_RANK = {VIS_PUBLIC: 0, VIS_PRIVATE: 1, VIS_AI_ONLY: 2}
_BY_RANK = {v: k for k, v in _RANK.items()}

# Sentence splitter: break on . ! ? (optionally closing quotes/brackets)
# followed by whitespace, but NOT after a short abbreviation token or inside a
# decimal number. Deliberately conservative — the editor lets the user merge or
# split further, so we favour not over-splitting ("e.g." stays one bullet).
_ABBREV = {
    "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g",
    "i.e", "u.s", "u.k", "a.m", "p.m", "no", "approx", "inc", "ltd", "co",
}
_SENT_END = re.compile(r'([.!?]+["\')\]]?)(\s+)')
_WORD_BEFORE = re.compile(r'([A-Za-z0-9.]+)[.!?"\')\]]*$')


def _is_abbrev(chunk: str) -> bool:
    m = _WORD_BEFORE.search(chunk)
    if not m:
        return False
    tok = m.group(1).rstrip(".").lower()
    if tok in _ABBREV:
        return True
    # a single trailing capital letter ("A." / initials) or a bare number
    return len(tok) == 1 or tok.isdigit()


def split_sentences(text: str) -> list[str]:
    """Split a run of prose into one-thought sentences. Newlines (and common
    bullet markers at line starts) are always boundaries; within a line we
    break on sentence punctuation, keeping the punctuation on the sentence and
    not splitting inside abbreviations or decimals."""
    out: list[str] = []
    for line in (text or "").replace("\r\n", "\n").split("\n"):
        line = re.sub(r"^\s*[-*•]\s+", "", line).strip()
        if not line:
            continue
        start = 0
        for m in _SENT_END.finditer(line):
            end = m.end(1)
            chunk = line[start:end]
            if _is_abbrev(line[start:m.end(1)]):
                continue
            s = chunk.strip()
            if s:
                out.append(s)
            start = m.end()
        tail = line[start:].strip()
        if tail:
            out.append(tail)
    return out


def _bullet_id(page_id: str, visibility: str, text: str, index: int) -> str:
    """A stable id for a bullet so the client can diff/track it across reads.
    Derived from the page, the bullet's content and its position (position
    disambiguates two identical sentences)."""
    h = hashlib.sha1(
        f"{page_id}\x1f{visibility}\x1f{text}\x1f{index}".encode("utf-8")
    ).hexdigest()
    return h[:12]


def _clamp(span_kind: str, page_visibility: str) -> str:
    """A bullet's effective visibility: the more-private of its span kind and
    the page's own visibility."""
    pv = page_visibility if page_visibility in _RANK else VIS_PRIVATE
    return _BY_RANK[max(_RANK.get(span_kind, 0), _RANK[pv])]


def parse_bullets(body: str, page_visibility: str, *, page_id: str = "") -> list[dict]:
    """Split ``body`` into ``[{id, text, visibility}]`` bullets. ``visibility``
    is the bullet's effective visibility (span kind clamped by the page)."""
    bullets: list[dict] = []
    for seg in parse_spans(body or ""):
        vis = _clamp(seg.get("kind", VIS_PUBLIC), page_visibility)
        for sentence in split_sentences(seg.get("text", "")):
            bullets.append(
                {
                    "id": _bullet_id(page_id, vis, sentence, len(bullets)),
                    "text": sentence,
                    "visibility": vis,
                }
            )
    return bullets


def _norm_vis(v) -> str:
    # Fail closed on privacy: a bullet that arrives without a valid visibility
    # tag is treated as PRIVATE, never public. Composing an untagged bullet as
    # public writes it unwrapped, and on a page that carries any private bullet
    # it then reads back public — an edited fragment silently leaking to the
    # public profile (Scout NOTE 221). Private is the safe default and matches
    # this module's private-by-default model.
    v = str(v or "").strip().lower()
    return v if v in _RANK else VIS_PRIVATE


def compose_body(bullets: list[dict]) -> dict:
    """Turn an edited bullet list back into ``{"body", "visibility"}``.

    Consecutive bullets of the same (wrapped) kind share one span, so the body
    stays tidy. The page visibility is the most-public bullet present; an empty
    list composes to an empty private page (hidden from the public profile)."""
    clean = [
        {"text": str(b.get("text", "")).strip(), "visibility": _norm_vis(b.get("visibility"))}
        for b in (bullets or [])
        if str(b.get("text", "")).strip()
    ]
    if not clean:
        return {"body": "", "visibility": VIS_PRIVATE}

    page_vis = _BY_RANK[min(_RANK[b["visibility"]] for b in clean)]

    # Marker pair per kind; public bullets are written plain.
    wrap = {
        VIS_PRIVATE: (PRIVATE_OPEN, PRIVATE_CLOSE),
        VIS_AI_ONLY: (AI_ONLY_OPEN, AI_ONLY_CLOSE),
    }
    parts: list[str] = []
    run: list[str] = []
    run_kind: str | None = None

    def _flush() -> None:
        if not run:
            return
        joined = " ".join(run)
        if run_kind in wrap:
            o, c = wrap[run_kind]
            parts.append(f"{o}{joined}{c}")
        else:
            parts.append(joined)

    for b in clean:
        kind = b["visibility"]
        if kind != run_kind:
            _flush()
            run = []
            run_kind = kind
        run.append(b["text"])
    _flush()
    return {"body": " ".join(p for p in parts if p).strip(), "visibility": page_vis}
