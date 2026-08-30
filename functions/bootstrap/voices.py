"""Gemini Live built-in HD voice presets (ARCHITECTURE.md §13.3).

A fixed set — not free-form synthesis. ``ayma_voice_name`` on
``users/{uid}/profile/main`` holds the chosen preset; the agent worker reads it
at session start (voice can't hot-swap mid-call). The default preset comes from
``CONFIG.gemini_live_voice`` per the AGENTS.md "model strings live in config"
rule; this module only names the selectable set and their character.
"""

from __future__ import annotations

# name -> short description used both for the settings picker and for the
# LLM "closest match" selection in the set_voice_preference skill.
VOICE_PRESETS: dict[str, str] = {
    "Aoede": "warm, bright, mid-range — the default",
    "Kore": "calm, even, gently authoritative — leans feminine",
    "Leda": "youthful, light, upbeat — leans feminine",
    "Zephyr": "airy, soft, soothing — leans feminine",
    "Puck": "playful, quick, expressive — gender-neutral",
    "Charon": "deep, steady, measured — leans masculine",
    "Fenrir": "gravelly, low, intense — leans masculine",
    "Orus": "clear, firm, confident — leans masculine",
}


def voice_names() -> list[str]:
    return list(VOICE_PRESETS)


def is_valid_voice(name: str) -> bool:
    return name in VOICE_PRESETS


def presets_block() -> str:
    return "\n".join(f"- {n}: {d}" for n, d in VOICE_PRESETS.items())
