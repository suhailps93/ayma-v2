"""Test-only stand-in for Ayma's private Gemini client (``gemini.py``).

Reproduces ONLY the surface the extracted ``llm_provider`` references:

* :class:`Reply` — the chat-reply value object.
* :func:`strip_inline_refs` — tidy leaked grounding-citation brackets.
* ``generate_json`` / ``generate_reply`` / ``generate_reply_events`` — the three
  entrypoints ``GeminiProvider`` delegates to. They raise by default (the real
  calls need Vertex / the Gemini SDK, not part of this repo); the fallback tests
  monkeypatch them to assert Meta→Gemini degradation without any network.

NOT the production client. Added to ``sys.path`` only by ``tests/conftest.py``.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field


@dataclass
class Reply:
    """A chat reply plus the ordered, de-duplicated tool labels used."""

    text: str
    tools_used: list[str] = field(default_factory=list)

    def __str__(self) -> str:
        return self.text


_REF_TOKEN = r"(?=[A-Za-z0-9_-]*[0-9_-])[A-Za-z0-9_-]{24,}={0,2}"
_INLINE_REF_RE = re.compile(
    r"\s*\[\s*(?:" + _REF_TOKEN + r"|\d{1,3})"
    r"(?:\s*,\s*(?:" + _REF_TOKEN + r"|\d{1,3}))*\s*\]"
)


def strip_inline_refs(text: str) -> str:
    """Remove leaked grounding-citation brackets and tidy the spacing."""
    if not text:
        return text
    out = _INLINE_REF_RE.sub("", text)
    out = re.sub(r"\s+([.,;:!?])", r"\1", out)
    out = re.sub(r"[ \t]{2,}", " ", out)
    return out.strip()


_NEEDS_CORE = (
    "gemini.{name} is not available in the public hackathon repo — it binds to "
    "Ayma's private Vertex/Gemini client. Tests that exercise the Gemini path "
    "monkeypatch this function."
)


async def generate_json(*args, **kwargs):  # pragma: no cover - monkeypatched in tests
    raise NotImplementedError(_NEEDS_CORE.format(name="generate_json"))


async def generate_reply(*args, **kwargs):  # pragma: no cover - monkeypatched in tests
    raise NotImplementedError(_NEEDS_CORE.format(name="generate_reply"))


async def generate_reply_events(*args, **kwargs):  # pragma: no cover - monkeypatched
    raise NotImplementedError(_NEEDS_CORE.format(name="generate_reply_events"))
    yield  # make this an async generator, matching the real signature
