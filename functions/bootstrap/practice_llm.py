"""Practice Date LLM seam (hackathon deliverable B).

Every Practice Date model call — the simulated-persona reply, the live coach
nudge, and the debrief — goes through the shared ``"practice"`` surface of the
merged provider abstraction (``llm_provider.get_llm_provider``, Deliverable A).
That means Practice Date runs on Gemini tonight and flips to Meta Muse Spark the
moment ``LLM_PROVIDER_PRACTICE=meta`` is set (with Gemini fallback), with no
change in this module or in ``practice_date.py``. Provider selection, metering
and fallback are owned by ``llm_provider`` — this module only adapts its two
call shapes to what Practice Date needs and carries a test-injection seam.

Tests install a deterministic stand-in via :func:`set_override` so the privacy
extraction test runs offline against a worst-case "leaky" model.
"""

from __future__ import annotations

from typing import Awaitable, Callable, Optional

import token_ledger
from llm_provider import get_llm_provider

SURFACE = "practice"

# Signature: (system_prompt, message, uid, feature, session_id) -> str
_TextFn = Callable[[str, str, Optional[str], str, str], Awaitable[str]]
# Signature: (system_prompt, contents, schema, uid, feature) -> object
_JsonFn = Callable[[str, str, Optional[dict], Optional[str], str], Awaitable[object]]

_override_text: Optional[_TextFn] = None
_override_json: Optional[_JsonFn] = None


def set_override(*, text: Optional[_TextFn] = None, json: Optional[_JsonFn] = None) -> None:
    """Install deterministic LLM stand-ins (tests only). Pass ``None`` to clear."""
    global _override_text, _override_json
    _override_text = text
    _override_json = json


def clear_override() -> None:
    set_override(text=None, json=None)


async def generate_text(
    system_prompt: str,
    message: str,
    *,
    uid: Optional[str] = None,
    feature: str = token_ledger.FEATURE_PRACTICE,
    session_id: str = "",
) -> str:
    """A single plain-text model turn for Practice Date, via the practice
    surface's provider. Returns the reply text; raises on provider failure."""
    if _override_text is not None:
        return await _override_text(system_prompt, message, uid, feature, session_id)
    reply = await get_llm_provider(SURFACE).generate_reply(
        message,
        system_prompt=system_prompt,
        uid=uid,
        feature=feature,
        session_id=session_id,
    )
    return reply.text


async def generate_structured(
    system_prompt: str,
    contents: str,
    response_schema: Optional[dict] = None,
    *,
    uid: Optional[str] = None,
    feature: str = token_ledger.FEATURE_PRACTICE,
) -> object:
    """A single structured (JSON) model call for Practice Date (coach/debrief),
    via the practice surface's provider. Returns the parsed JSON value."""
    if _override_json is not None:
        return await _override_json(system_prompt, contents, response_schema, uid, feature)
    return await get_llm_provider(SURFACE).generate_json(
        contents,
        system_prompt,
        response_schema=response_schema,
        uid=uid,
        feature=feature,
        enforce_cap=False,
    )
