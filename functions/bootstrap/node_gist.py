"""The shared GIST derivation — one helper, every node, every surface.

Part of the "less text-heavy" program (Part 1, gist-first rendering). Every node
in every node tree carries a ``gist``: a short punchy one-line headline the
Flutter surfaces render BY DEFAULT, with the full prose revealed only on tap-in.

Contract (shared with Part 3, the writer side, ``fleet/gist-first-writing``):
  - The field name is exactly ``gist``.
  - A STORED ``gist`` (the writer produces one going forward) always wins.
  - When a node has no stored ``gist`` (every existing node today), derive one
    from the node's existing text — generalizably, with NO per-node code:
      * first sentence of the prose/answer, when it fits the length budget;
      * otherwise a trimmed summary of that text, cut on a word boundary,
        trailing punctuation stripped, an ellipsis appended.

This is the ONE path for every node; image nodes keep their photo (the renderer
never gist-ifies an image's visual), so this helper is only ever meaningful for
text content.
"""

from __future__ import annotations

import re

# Aim for a short headline. ~80 chars keeps a single line at phone width.
GIST_MAX = 80

# Whitespace run → one space (prose spanning newlines becomes one line).
_WS = re.compile(r"\s+")

# A sentence boundary: ``.``/``!``/``?`` followed by whitespace.
_SENTENCE_END = re.compile(r"(?<=[.!?])\s+")

# Trailing characters a headline drops (sentence period, list punctuation,
# dangling dashes/quotes). ``!``/``?`` are kept — they read as a headline.
_TRAIL = " \t\r\n.,;:—–-\"'"


def _clean(s: str) -> str:
    return _WS.sub(" ", (s or "").strip())


def _trim(s: str) -> str:
    """Trim ``s`` to the length budget on a word boundary, strip trailing
    punctuation, and append an ellipsis when it was actually cut."""
    s = s.strip()
    if len(s) <= GIST_MAX:
        return s.rstrip(_TRAIL)
    cut = s[:GIST_MAX]
    sp = cut.rfind(" ")
    if sp > 0:
        cut = cut[:sp]
    return cut.rstrip(_TRAIL) + "…"


def derive_gist(text: str | None, stored: str | None = None) -> str:
    """The node's gist: the stored headline if the writer produced one, else a
    generalizable fallback derived from ``text`` (first sentence, else trimmed).

    Returns ``""`` only when there is neither a stored gist nor any text (e.g. a
    pure image node) — the renderer then falls back to the node's own content.
    """
    if stored and stored.strip():
        return stored.strip()
    s = _clean(text or "")
    if not s:
        return ""
    first = _SENTENCE_END.split(s, 1)[0].strip()
    if first and len(first) <= GIST_MAX:
        return first.rstrip(_TRAIL)
    return _trim(first or s)
