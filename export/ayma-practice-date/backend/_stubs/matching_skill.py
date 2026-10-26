"""Test-only stand-in for Ayma's private matching skill.

The extracted ``tests/test_llm_provider.py`` passes a *real* compatibility JSON
schema through the Meta provider's ``response_format`` mapping to prove the
mapping is schema-agnostic. The real schema comes from Ayma's private
``matching_skill._response_schema``; the matching logic itself is NOT part of
this public repo. This stand-in returns a representative compatibility schema of
the same shape (dimensions + explanations) so that test exercises the real
mapping path without pulling in matching internals.

NOT the production matching skill. Added to ``sys.path`` only by
``tests/conftest.py``.
"""

from __future__ import annotations

_DIM_KEYS = ["values", "lifestyle", "communication", "goals"]


def _response_schema(dim_keys: list[str]) -> dict:
    """A compatibility-scoring JSON schema (same shape as the private one)."""
    return {
        "type": "object",
        "properties": {
            "dimensions": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "key": {"type": "string", "enum": dim_keys or _DIM_KEYS},
                        "score": {"type": "number"},
                        "rationale": {"type": "string"},
                    },
                    "required": ["key", "score", "rationale"],
                },
            },
            "user_explanation": {
                "type": "object",
                "properties": {
                    "A": {"type": "string"},
                    "B": {"type": "string"},
                },
                "required": ["A", "B"],
            },
            "ai_explanation": {"type": "string"},
        },
        "required": ["dimensions", "user_explanation", "ai_explanation"],
    }
