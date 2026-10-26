"""Test-only stand-in for Ayma's Story span parser (``story.py``).

Reproduces ONLY :func:`strip_private_spans`: the production serializer and this
stand-in both remove every non-public span (``{{private}}…{{/private}}`` and
``{{ai_only}}…{{/ai_only}}``, content included) before a body is shown publicly.
The real module has a full span parser/serializer; this regex version is
sufficient for the public-wiki bodies the extraction test uses.

NOT the production parser. Added to ``sys.path`` only by ``tests/conftest.py``.
"""

from __future__ import annotations

import re

# Strip paired private / ai_only spans and their content (non-greedy, across
# newlines). Any stray unmatched opening marker is also removed defensively so a
# malformed span can never leak its tail into public text.
_SPAN_RE = re.compile(
    r"\{\{(private|ai_only)\}\}.*?\{\{/\1\}\}", re.DOTALL
)
_STRAY_MARKER_RE = re.compile(r"\{\{/?(?:private|ai_only)\}\}")


def strip_private_spans(text: str) -> str:
    """The body with every non-``public`` span (and its content) removed."""
    if not text:
        return text
    plain = _SPAN_RE.sub("", text)
    plain = _STRAY_MARKER_RE.sub("", plain)
    return re.sub(r"\n{3,}", "\n\n", plain).strip()
