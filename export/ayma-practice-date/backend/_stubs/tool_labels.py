"""Test-only stand-in for Ayma's user-facing tool-label map.

The real module maps internal tool names to the short "Searching the web…" /
"Looked up the web" style labels Ayma shows in chat. The extracted
``llm_provider`` imports it lazily only on the Meta chat tool round-trip. These
stand-ins return simple, deterministic labels so that path runs offline.

NOT the production map. Added to ``sys.path`` only by ``tests/conftest.py``.
"""

from __future__ import annotations


def working_label(name: str) -> str:
    """The transient "doing X…" label shown while a tool runs."""
    return f"Running {name}…"


def tool_label(name: str) -> str:
    """The settled label recorded for a tool that was used."""
    return name
