"""Deterministic "goodbye Ayma" hang-up command (voice backstop).

Mirrors the strict pre-model detectors (``app_control_navigation``,
``guided_tour``): a finalized in-call transcript that IS a live sign-off to
Ayma ends the call deterministically (agent.py ``detect_voice_command`` runs
this first, before every other command family), so hanging up never depends
on the realtime model. Everything else — talking ABOUT goodbye, recounting
one, a goodbye to someone else, a goodbye buried in a longer request — stays
with the model.

Strict by design (a false hang-up kills the call, while a missed one just
gets Ayma's spoken "bye!" and the call continues): after stripping the
goodbye word(s) and the Ayma address, every remaining word must be a
discourse filler or a thanks/politeness tail — anything else means the
utterance is not the sign-off itself.
"""

from __future__ import annotations

import re

# The goodbye words that can carry a sign-off. Singulars only: the plural
# ("say our goodbyes") talks ABOUT goodbye, never signs off.
_GOODBYE_WORDS = frozenset({"goodbye", "bye"})

# An Ayma address, mirroring agent.py ``_AYMA_CALLOUT_RE`` (kept in sync with
# it): Gemini Live's input transcription routinely garbles the name (AY-muh),
# so the common near-misses and split forms count as naming her. Whole words
# only. Only ever consulted together with a goodbye word plus the filler-only
# remainder below, so "Emma" alone can never hang a call up.
_AYMA_RE = re.compile(
    r"\b(?:"
    r"a[iy]m{1,2}[ae]r?"
    r"|a[iy][eu]m[ae]"
    r"|[ae]ym[ae]"
    r"|amya"
    r"|a\s+ima"
    r"|a[iy]\s+ma"
    r"|ima"
    r"|emma|amma|ema"
    r")\b",
    re.IGNORECASE,
)

# Words that may surround the sign-off without changing what the utterance
# is: leading discourse ("okay, goodbye Ayma"), a thanks tail ("goodbye
# Ayma, thanks a lot"), and the "for now" of "goodbye for now". Anything
# outside this set ("open", "said", "Sofia", …) means the utterance is a
# request, a recounting, or a third-party goodbye — never a hang-up.
_FILLER_WORDS = frozenset(
    "ok okay well so alright all right oh then "
    "thanks thank you very much a lot lots "
    "for now".split()
)


def is_goodbye_command(message: str) -> bool:
    """True when ``message`` (a finalized user turn) IS a live sign-off to
    Ayma: a goodbye word plus an explicit Ayma address ("goodbye Ayma",
    "bye Ayma, thank you"), or a bare "goodbye" that is essentially the
    whole utterance.

    A bare "bye" alone never fires: it is one STT-confusable syllable
    ("buy"/"by"), and a ghosted hang-up is far worse than a missed one —
    the model just says "bye!" back and the call continues. Longer
    utterances need the Ayma address AND a filler-only remainder, so
    recounting ("I said goodbye to her yesterday"), third-party goodbyes
    ("say goodbye to Sofia for me"), talking-about-goodbye, and goodbye
    tails on real requests ("open my messages, goodbye Ayma") all stay
    with the model (the request part still matches its own family)."""
    m = (message or "").strip()
    if not m or len(m) > 200:
        return False
    low = m.lower()
    ayma = _AYMA_RE.search(low) is not None
    # Unify the spelled variants before tokenizing ("good-bye" / "good bye"
    # → "goodbye"; "bye-bye" / "bye bye" / "byebye" → "bye").
    text = re.sub(r"\bgood(?:\s*-\s*|\s+)bye\b", "goodbye", low)
    text = re.sub(r"\bbye(?:\s*-\s*|\s+)bye\b", "bye", text)
    text = re.sub(r"\bbyebye\b", "bye", text)
    text = _AYMA_RE.sub(" ", text)
    words = re.sub(r"[^a-z0-9\s]", " ", text).split()
    if not any(w in _GOODBYE_WORDS for w in words):
        return False
    if not ayma and "goodbye" not in words:
        return False
    rest = [w for w in words if w not in _GOODBYE_WORDS]
    return all(w in _FILLER_WORDS for w in rest)
