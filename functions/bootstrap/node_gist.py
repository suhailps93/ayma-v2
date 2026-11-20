"""The shared GIST derivation — one helper, every node, every surface.

Part of the "less text-heavy" program (Part 1, gist-first rendering). Every node
in every node tree carries a ``gist``: a short punchy one-line headline the
Flutter surfaces render BY DEFAULT, with the full prose revealed only on tap-in.

Contract (shared with Part 3, the writer side, ``fleet/gist-first-writing``):
  - The field name is exactly ``gist``.
  - A STORED ``gist`` (the writer produces one going forward) always wins.
  - When a node has no stored ``gist`` (every existing node today), derive one
    from the node's existing text — generalizably, with NO per-node code:
      * the FIRST COMPLETE SENTENCE of the prose/answer, trailing punctuation
        stripped, returned IN FULL;
      * when there is no sentence boundary (a single run-on line), the whole
        line, likewise in full.
    The derived headline is NEVER chopped mid-word and NEVER ends in an
    ellipsis — the visible line is always a complete thought that wraps to its
    full height on the surface (founder, Nov 17: "no text should cut off
    partially … the visible line itself is never a chopped sentence"). The full
    prose stays in the node's ``text`` for the tap-in detail.

This is the ONE path for every node; image nodes keep their photo (the renderer
never gist-ifies an image's visual), so this helper is only ever meaningful for
text content.
"""

from __future__ import annotations

import re

# Whitespace run → one space (prose spanning newlines becomes one line).
_WS = re.compile(r"\s+")

# A sentence boundary: ``.``/``!``/``?`` followed by whitespace.
_SENTENCE_END = re.compile(r"(?<=[.!?])\s+")

# Trailing characters a headline drops (sentence period, list punctuation,
# dangling dashes/quotes). ``!``/``?`` are kept — they read as a headline.
_TRAIL = " \t\r\n.,;:—–-\"'"

# A run of terse bracket tags at the very end of the content (e.g. "[Scout279]",
# a citation "[1]", a status "[draft]"). These are metadata the user appended to
# the line, not a second sentence — so the first-sentence gist must KEEP them
# rather than drop them off the tail with the rest of the prose (NOTE 279 Leg 3:
# a bullet ending "…introverted nature. [Scout279]" rendered without its marker,
# because the marker sat after the first sentence boundary the gist splits on).
_TRAILING_TAGS = re.compile(r"(?:\[[^\[\]\r\n]+\])(?:\s*\[[^\[\]\r\n]+\])*\s*$")


def _clean(s: str) -> str:
    return _WS.sub(" ", (s or "").strip())


def derive_gist(text: str | None, stored: str | None = None) -> str:
    """The node's gist: the stored headline if the writer produced one, else a
    generalizable fallback derived from ``text`` — the first complete sentence,
    returned IN FULL with no length cap and no ellipsis (a long sentence wraps
    to its full height rather than being chopped mid-word).

    Returns ``""`` only when there is neither a stored gist nor any text (e.g. a
    pure image node) — the renderer then falls back to the node's own content.
    """
    if stored and stored.strip():
        return stored.strip()
    s = _clean(text or "")
    if not s:
        return ""
    first = _SENTENCE_END.split(s, 1)[0].strip()
    gist = (first or s).rstrip(_TRAIL)
    # Keep a trailing bracket tag the first-sentence truncation would otherwise
    # drop (the whole tag is already in the gist for a single-line node, so only
    # append when it isn't there yet).
    tail = _TRAILING_TAGS.search(s)
    if tail:
        marker = tail.group(0).strip()
        if not gist.endswith(marker):
            gist = f"{gist} {marker}".strip()
    return gist
