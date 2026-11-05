"""Runtime provider routing: all inference goes through LiveKit Inference.

Founder rule (2026-11-04, permanent — see
``docs/DIRECT_GOOGLE_KILL_AUDIT.md``): every Gemini call is served by the
LiveKit Inference gateway. There is no direct-Google path anymore: no Vertex
branch, no Developer-API branch, no silent fallback. When the gateway is down
the call fails honestly.

The ``llm_route_*`` / ``voice_provider`` / ``llm_percent_*`` /
``llm_allowlist_*`` / ``llm_fallback_to_google`` settings are retained in the
:mod:`feature_flags` registry (so old Firestore/env values fail no validation
and stay visible) but are NO LONGER HONORED — :func:`route_for` always returns
``"inference"`` and :func:`fallback_enabled` always returns ``False``, whatever
they say. Do not re-arm a direct path here.
"""

from __future__ import annotations


class DirectGoogleDisabledError(RuntimeError):
    """A direct-Google inference sub-path was called after the kill.

    Raised by the disabled sub-paths (grounded research, image generate/edit,
    TTS previews, embeddings, Vertex batch) instead of calling Google. The
    ``code`` marks the failure deterministic so retry classifiers (e.g.
    ``deep_dive._research_error_retryable``) do not treat it as transient.
    """

    code = 400


def route_for(group: str, uid: str | None = None) -> str:
    """Always ``"inference"`` — the only provider. ``group``/``uid`` are kept
    so every existing call site keeps working unchanged."""
    return "inference"


def fallback_enabled() -> bool:
    """Always ``False`` — a failed Inference call surfaces, never retries on
    a direct provider."""
    return False


def reset_cache() -> None:
    import feature_flags

    feature_flags.reset_cache()
