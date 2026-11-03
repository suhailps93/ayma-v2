"""Explore feed (ARCHITECTURE.md §6.1, §6.2, §6.11 steps 4–5).

A live query over every user who has a ``profile/main`` — the caller included,
with no orientation or community gating (product decision, 2026-08-30). Blocks,
paused profiles and already-passed users are removed; deleted accounts have no
profile doc. Practice-date simulator personas (``demo_practice_*``,
``practice_seed.is_practice_persona``) are never real accounts and are excluded
too. Seeded test fixtures — the ``demo-edge-*`` corner-case accounts
(flagged ``exclude_from_explore`` on their user doc; ``demo-edge-`` uid
prefix is a secondary safety net) — are likewise hidden from real users,
EXCEPT for a designated e2e/demo viewer whose uid is in
``config.explore_fixture_bypass_uids`` (so the e2e harness can still
verify a real dealbreaker profile renders). The curated demo set
``demo-test1/2/3`` carries no such flag and stays visible. Dropdown filters and a once-per-search NL-parsed filter are applied over
the same structured shape; ``matches`` / ``match_candidates`` overlay a score
when present.

A filter on a ``physical_attrs``-mirror field (see :func:`_passes_filters`)
only ever matches against a candidate's PUBLIC attributes —
``physical_attributes.public_fields(db, other)`` — never a field they've kept
private (§ founder 2026-09-21: repurposing the per-field visibility flag that
used to gate the since-removed ``story_public`` Attributes section: "Use it
for the heuristic search tho"). A private field is dropped before any filter
reads it, so it's treated EXACTLY like a missing/unknown one — which, per
field, already means one of two things here: never excludes (the
``_PHYSICAL_ENUM_FIELDS`` group, plus race/height/weight), or excludes the
same as a genuine mismatch would (the ``_PHOTO_FIELDS`` group, which has no
"unknown never excludes" guard even today). Either way, a private value
never gets to act as if it were public.
"""

from __future__ import annotations

import base64
import json
import logging
import re
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from prompt import load_prompt_file
import config
import gemini
import physical_attributes
import practice_seed
import token_ledger
from matching import _age
from matching_schema import block_id
from pair_key import sorted_pair_key

logger = logging.getLogger("ayma.explore")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "explore_nl_filter.md"

_NL_SCHEMA = {
    "type": "object",
    "properties": {
        "gender": {"type": "string"},
        "location": {"type": "string"},
        "age_min": {"type": "integer"},
        "age_max": {"type": "integer"},
        "hair_color": {"type": "string"},
        "eye_color": {"type": "string"},
        "age_range_apparent": {"type": "string"},
        "facial_hair": {"type": "string"},
        "glasses": {"type": "string"},
        "visible_tattoos": {"type": "string"},
        "visible_piercings": {"type": "string"},
        # physical-attributes filters (§ physical attributes) — matched against
        # the flat profile.physical_attrs mirror.
        "race_ethnicity": {"type": "string"},
        "skin_tone": {"type": "string"},
        "hair_length": {"type": "string"},
        "hair_type": {"type": "string"},
        "build": {"type": "string"},
        "height_min_cm": {"type": "integer"},
        "height_max_cm": {"type": "integer"},
        "weight_min_kg": {"type": "integer"},
        "weight_max_kg": {"type": "integer"},
        "keywords": {
            "type": "array",
            "items": {"type": "string"},
        },
    },
}

_PHOTO_FIELDS = (
    "hair_color",
    "eye_color",
    "age_range_apparent",
    "facial_hair",
    "glasses",
    "visible_tattoos",
    "visible_piercings",
)

# Enum fields that live only on the physical-attributes mirror. Missing /
# "unknown" never excludes — only an explicit mismatch does.
_PHYSICAL_ENUM_FIELDS = (
    "skin_tone",
    "hair_length",
    "hair_type",
    "build",
)

# Every filter key `_passes_filters` can satisfy off the `physical_attrs`
# mirror (`physical_attributes.flat_mirror`) — the fallback half of
# `_PHOTO_FIELDS`, all of `_PHYSICAL_ENUM_FIELDS`, plus race/height/weight.
# Used only to skip the extra `physical_attributes.public_fields` read in
# `explore()` when a search has none of these active (the common case).
_PHYSICAL_MIRROR_FILTER_KEYS = frozenset(
    _PHOTO_FIELDS
    + _PHYSICAL_ENUM_FIELDS
    + (
        "race_ethnicity",
        "height_min_cm",
        "height_max_cm",
        "weight_min_kg",
        "weight_max_kg",
    )
)


_STOP_WORDS = frozenset({
    "a", "an", "the", "and", "or", "in", "at", "of", "to", "for", "with",
    "on", "by", "is", "are", "was", "were", "who", "whom", "whose", "which",
    "what", "that", "this", "these", "those", "someone", "somebody", "anyone",
    "anybody", "person", "people", "looking", "look", "loves", "love", "likes",
    "like", "want", "wants", "seeking", "find", "show", "me",
})


def _extract_fallback_keywords(text: str) -> list[str]:
    raw = text.strip().lower()
    if not raw:
        return []
    words = [w for w in re.findall(r"[\w'-]+", raw) if w not in _STOP_WORDS]
    out = []
    if raw not in out:
        out.append(raw)
    for w in words:
        if len(w) > 2 and w not in out:
            out.append(w)
    return out


async def parse_nl_query(text: str, *, uid: str | None = None) -> dict:
    """One LLM call → the filter shape. ``{}`` on anything unclear.
    Billed to ``uid`` in the token ledger (``explore`` feature).

    On an LLM failure the deterministic demographic backstop below still runs,
    so an ethnicity/gender query ("Indian women") keeps filtering on the
    attribute instead of silently falling back to an unfiltered feed."""
    text = text.strip()
    if not text:
        return {}
    try:
        result = await gemini.generate_json(
            text,
            system_prompt=load_prompt_file(_PROMPT_PATH),
            response_schema=_NL_SCHEMA,
            uid=uid,
            feature=token_ledger.FEATURE_EXPLORE,
        )
        llm_ok = True
    except Exception:  # noqa: BLE001
        logger.exception("NL filter parse failed")
        result = {}
        llm_ok = False

    out = dict(result) if isinstance(result, dict) else {}

    # Ethnicity: a demographic query ("Indian women") must filter on the coarse
    # `race_ethnicity` attribute, not leak the demonym into keyword text. Back
    # the LLM up deterministically when it didn't map one, and normalize what
    # it did return ("indian" -> "south asian") to the stored grouping so it
    # actually matches the attribute.
    if not out.get("race_ethnicity"):
        grouping = _ethnicity_from_text(text)
        if grouping:
            out["race_ethnicity"] = grouping
    elif out.get("race_ethnicity"):
        out["race_ethnicity"] = _normalize_ethnicity(out["race_ethnicity"])
    if not out.get("gender"):
        gender = _gender_from_text(text)
        if gender:
            out["gender"] = gender

    raw_kw = out.get("keywords")
    keywords = (
        [str(k).strip().lower() for k in raw_kw if str(k).strip()]
        if isinstance(raw_kw, list)
        else []
    )
    # When no keywords were returned by the model, extract fallback keywords
    # if unmapped search terms remain in text. Only on a real parse — an LLM
    # failure leaves keyword extraction to the endpoint's raw-`q` fallback
    # (so this returns {} for a non-demographic query, unchanged), while the
    # demographic backstop above still runs so ethnicity/gender keep working.
    if not keywords and text and llm_ok:
        structured_vals = {
            str(v).lower() for k, v in out.items() if k != "keywords" and v
        }
        candidate_kws = [
            w for w in _extract_fallback_keywords(text)
            if w not in structured_vals and not any(w in sv for sv in structured_vals)
        ]
        if candidate_kws:
            keywords = candidate_kws

    # A term already consumed by a demographic filter (gender/ethnicity) must
    # not also run as a loose keyword text match (false positives + hides a
    # real match whose ethnicity is only on the attribute).
    keywords = _strip_consumed_terms(keywords, out)

    if keywords:
        out["keywords"] = keywords
    elif "keywords" in out:
        out.pop("keywords")
    return out


_GENDER_ALIASES = {
    "woman": "woman", "women": "woman", "female": "woman", "f": "woman",
    "man": "man", "men": "man", "male": "man", "m": "man", "guy": "man",
    "guys": "man",
    "non-binary": "non-binary", "nonbinary": "non-binary", "nb": "non-binary",
    "enby": "non-binary",
}

# A demographic/ethnicity search ("Indian women") names a *nationality or
# region*, but the stored `race_ethnicity` attribute is a coarse grouping (the
# §6.2 schema vocabulary: "south asian", "east asian", "latino", …). This map
# resolves a demonym the user actually types to that coarse grouping, so the
# search filters on the ethnicity ATTRIBUTE instead of leaking the word into
# loose keyword text matching (which false-positives on "indie"/"individual"
# and misses a real match whose ethnicity lives only in the attribute).
# Each coarse grouping also maps to itself so a model- or dropdown-supplied
# grouping normalizes idempotently. Ambiguous colour words ("black"/"white",
# also hair colours) are intentionally left to the LLM's `race_ethnicity`
# field and the `_ETHNICITY_TEXT_UNAMBIGUOUS` backstop never sets them.
_ETHNICITY_ALIASES = {
    # South Asian
    "south asian": "south asian", "desi": "south asian",
    "indian": "south asian", "pakistani": "south asian",
    "bangladeshi": "south asian", "sri lankan": "south asian",
    "nepali": "south asian", "punjabi": "south asian", "tamil": "south asian",
    # East Asian
    "east asian": "east asian", "chinese": "east asian",
    "japanese": "east asian", "korean": "east asian",
    "taiwanese": "east asian", "mongolian": "east asian",
    # Southeast Asian
    "southeast asian": "southeast asian", "filipino": "southeast asian",
    "filipina": "southeast asian", "vietnamese": "southeast asian",
    "thai": "southeast asian", "indonesian": "southeast asian",
    "malaysian": "southeast asian",
    # Latino / Hispanic
    "latino": "latino", "latina": "latino", "latinx": "latino",
    "hispanic": "latino", "mexican": "latino", "brazilian": "latino",
    "colombian": "latino",
    # Middle Eastern
    "middle eastern": "middle eastern", "arab": "middle eastern",
    "persian": "middle eastern", "iranian": "middle eastern",
    "lebanese": "middle eastern", "turkish": "middle eastern",
    # Black
    "black": "black", "african": "black", "african american": "black",
    "nigerian": "black", "ethiopian": "black", "caribbean": "black",
    # White
    "white": "white", "caucasian": "white", "european": "white",
    # Mixed
    "mixed": "mixed", "biracial": "mixed", "multiracial": "mixed",
}

# Physical-mirror fields that search treats as DEMOGRAPHIC (like gender / age /
# location) rather than as a private Story-appearance attribute: filtered on
# regardless of the per-field Story visibility flag, used only to narrow the
# feed, never displayed on the Explore card (§ founder 2026-11-03 ethnicity
# search ruling — see `_passes_filters`).
_DEMOGRAPHIC_SEARCH_FIELDS = frozenset({"race_ethnicity"})

# Multi-word ethnicity phrases, longest first, for the free-text backstop.
_ETHNICITY_PHRASES = tuple(
    sorted((k for k in _ETHNICITY_ALIASES if " " in k), key=len, reverse=True)
)

# Single-word demonyms the backstop may set `race_ethnicity` from when the LLM
# missed it. Excludes bare colour/loose words ("black", "white", "mixed",
# "african", "european", "caribbean") that are ambiguous out of context — the
# LLM owns those; they're still normalized if it returns them.
_ETHNICITY_TEXT_UNAMBIGUOUS = frozenset(
    w for w, g in _ETHNICITY_ALIASES.items()
    if " " not in w
    and w not in {"black", "white", "mixed", "african", "european",
                  "caribbean", "arab"}
)


def _normalize_ethnicity(value) -> str:
    """Resolve a race/ethnicity value (a demonym or a coarse grouping) to its
    coarse grouping, lower-cased. Unknown values pass through unchanged so a
    richer stored string (e.g. ``"Latino/Hispanic"``) still substring-matches."""
    v = str(value or "").strip().lower()
    return _ETHNICITY_ALIASES.get(v, v)


def _gender_from_text(text: str) -> str | None:
    """Canonical gender implied by an explicit gender word in ``text``, or
    ``None``. A deterministic backstop so "women" filters on gender (and is
    consumed, not left as a loose keyword) even if the LLM returned nothing."""
    for word in re.findall(r"[\w'-]+", str(text or "").lower()):
        canon = _GENDER_ALIASES.get(word)
        # Skip the one-letter aliases ("m"/"f") — too noisy for free text.
        if canon and len(word) > 1:
            return canon
    return None


def _ethnicity_from_text(text: str) -> str | None:
    """Coarse grouping implied by an unambiguous ethnicity term in ``text``,
    or ``None``. A deterministic backstop for the NL filter so a demographic
    query filters on the ethnicity attribute even if the LLM didn't map it."""
    low = f" {str(text or '').lower()} "
    for phrase in _ETHNICITY_PHRASES:
        if f" {phrase} " in low:
            return _ETHNICITY_ALIASES[phrase]
    for word in re.findall(r"[\w'-]+", low):
        if word in _ETHNICITY_TEXT_UNAMBIGUOUS:
            return _ETHNICITY_ALIASES[word]
    return None


def _strip_consumed_terms(keywords: list[str], filters: dict) -> list[str]:
    """Drop keyword entries whose every token was already consumed by a
    structured demographic filter (gender and/or race_ethnicity). Without this
    the raw query ("indian women") leaks "indian"/"women" into loose keyword
    text matching, which false-positives on substrings like "indie" and hides
    a real match whose ethnicity lives only in the attribute."""
    gender_set = bool(str(filters.get("gender") or "").strip())
    race_set = bool(str(filters.get("race_ethnicity") or "").strip())
    if not (gender_set or race_set):
        return list(keywords)
    out = []
    for kw in keywords:
        toks = re.findall(r"[\w'-]+", str(kw).lower())
        if toks and all(
            (gender_set and t in _GENDER_ALIASES)
            or (race_set and t in _ETHNICITY_ALIASES)
            for t in toks
        ):
            continue
        out.append(kw)
    return out


def _is_test_fixture(uid: str, user_doc: dict) -> bool:
    """True when ``uid`` is a seeded test fixture that must never appear in a
    real user's Explore feed. The explicit ``exclude_from_explore`` flag on the
    top-level user doc is authoritative; the ``demo-edge-`` uid prefix is a
    secondary safety net for any fixture seeded before the flag existed. The
    curated demo set (``demo-test1/2/3``) carries neither and stays visible."""
    if (user_doc or {}).get("exclude_from_explore") is True:
        return True
    return str(uid or "").startswith("demo-edge-")


def _matches_keyword(corpus: str, kw: str) -> bool:
    kw = kw.strip().lower()
    if not kw or not corpus:
        return False
    if kw in corpus:
        return True
    parts = [w for w in re.findall(r"[\w'-]+", kw) if w not in _STOP_WORDS]
    if not parts:
        return False
    if len(parts) == 1:
        p = parts[0]
        if p in corpus:
            return True
        if len(p) > 4 and p[:-1] in corpus:
            return True
        if len(p) > 5 and p[:-2] in corpus:
            return True
        return False
    return all(p in corpus or (len(p) > 4 and p[:-1] in corpus) for p in parts)


def _passes_filters(
    profile: dict,
    filters: dict,
    *,
    public_fields: set[str] | None = None,
    extra_text: list[str] | None = None,
) -> bool:
    """``True`` when ``profile`` (a candidate being considered for someone
    else's Explore search) satisfies every set ``filters`` key.

    ``public_fields`` — the subset of ``physical_attributes.fields()`` this
    candidate has made public (``physical_attributes.public_fields(db,
    other)``; see :func:`explore`'s call site). When given, a private field
    is dropped from ``physical_attrs`` before any filter below ever reads
    it — so it's treated exactly as an unset/unknown value already is on
    that same field (never excludes, for the ``_PHYSICAL_ENUM_FIELDS``
    group plus height/weight; excludes the same as a real mismatch,
    for the ``_PHOTO_FIELDS`` group, which forgives no missing value even
    today) — never something more lenient invented for privacy specifically.
    Either way, a search can't use a *Story-appearance* physical attribute
    the candidate chose to keep off their public Story to find OR rule them
    out (§ founder 2026-09-21: repurposing the per-field visibility flag that
    used to only gate the Story-public Living Report's since-removed
    Attributes section — "Use it for the heuristic search tho").

    ``_DEMOGRAPHIC_SEARCH_FIELDS`` (race_ethnicity) are the exception: a
    demographic/ethnicity query ("Indian women") is treated like the other
    demographic filters (gender, age, location — all ungated) and filters on
    the attribute regardless of the Story visibility flag, so the ethnicity a
    user asked for actually narrows the feed (§ founder 2026-11-03: "a
    demographic/ethnicity query must FILTER + rank by the ethnicity attribute
    … non-matching ethnicity is excluded"). The coarse, photo-derived value is
    used only to filter, never shown on the Explore card. ``None`` (the
    default) applies no restriction — every direct unit test of this function
    short of :func:`explore` itself calls it this way."""
    want_g = str(filters.get("gender") or "").strip().lower()
    if want_g:
        norm = _GENDER_ALIASES.get(want_g, want_g)
        if str(profile.get("gender") or "").strip().lower() != norm:
            return False

    age = _age(profile.get("birthdate"))
    if filters.get("age_min") is not None and (
        age is None or age < int(filters["age_min"])
    ):
        return False
    if filters.get("age_max") is not None and (
        age is None or age > int(filters["age_max"])
    ):
        return False
    if filters.get("location"):
        loc = (profile.get("location") or "").lower()
        if filters["location"].lower() not in loc:
            return False

    attrs = profile.get("photo_attrs") or {}
    phys = profile.get("physical_attrs") or {}
    if public_fields is not None:
        phys = {
            f: v for f, v in phys.items()
            if f in public_fields or f in _DEMOGRAPHIC_SEARCH_FIELDS
        }
    for field in _PHOTO_FIELDS:
        want = filters.get(field)
        if not want:
            continue
        # Prefer the per-upload photo_attrs read (existing behaviour); fall back
        # to the physical-attributes mirror only when photo_attrs has no value.
        have = attrs.get(field)
        if have is None:
            have = phys.get(field)
        if str(have or "").lower() != str(want).lower():
            return False

    # Physical-attributes-only enum fields: an unknown / missing value on the
    # profile does NOT exclude — only an explicit, concrete mismatch does.
    for field in _PHYSICAL_ENUM_FIELDS:
        want = str(filters.get(field) or "").strip().lower()
        if not want:
            continue
        have = str(phys.get(field) or "").strip().lower()
        if have and have != "unknown" and have != want:
            return False

    # race_ethnicity: coarse grouping match, unknown/missing never excludes. A
    # demonym the user typed ("indian") is normalized to the stored coarse
    # grouping ("south asian") on both sides so it matches the attribute;
    # either-direction substring keeps richer stored strings
    # ("Latino/Hispanic") matching a plain grouping filter ("latino").
    want_re = _normalize_ethnicity(filters.get("race_ethnicity"))
    if want_re:
        have_raw = str(phys.get("race_ethnicity") or "").strip().lower()
        have_re = _normalize_ethnicity(have_raw)
        if have_raw and have_raw != "unknown" and (
            want_re != have_re
            and want_re not in have_re
            and have_re not in want_re
        ):
            return False

    # Rough height / weight ranges from the physical-attributes mirror. A
    # missing estimate never excludes (photos rarely give a scale cue).
    if not _in_range(
        phys.get("height_estimate_cm"),
        filters.get("height_min_cm"),
        filters.get("height_max_cm"),
    ):
        return False
    if not _in_range(
        phys.get("weight_estimate_kg"),
        filters.get("weight_min_kg"),
        filters.get("weight_max_kg"),
    ):
        return False

    keywords = filters.get("keywords")
    if not keywords and filters.get("q"):
        # Raw-query fallback (no explicit keywords). Strip terms already
        # consumed by a demographic filter so "indian women" doesn't re-enter
        # as loose keyword text matching after the ethnicity/gender filters.
        keywords = _strip_consumed_terms(
            _extract_fallback_keywords(filters["q"]), filters
        )
    elif isinstance(keywords, str):
        keywords = [keywords]

    if keywords:
        corpus_parts = [
            str(profile.get("name") or ""),
            str(profile.get("headline") or ""),
            str(profile.get("location") or ""),
        ]
        if extra_text:
            corpus_parts.extend(extra_text)
        for k, v in profile.items():
            if k.startswith("qz_") and isinstance(v, str):
                corpus_parts.append(v)
        corpus = " ".join(corpus_parts).lower()
        if not any(_matches_keyword(corpus, k) for k in keywords if k):
            return False

    return True


def _in_range(value, lo, hi) -> bool:
    """``True`` unless ``value`` is a real number that falls outside an
    explicitly-set ``[lo, hi]`` bound. Missing values pass."""
    if lo is None and hi is None:
        return True
    try:
        v = int(value)
    except (TypeError, ValueError):
        return True  # no estimate -> don't exclude
    if lo is not None and v < int(lo):
        return False
    if hi is not None and v > int(hi):
        return False
    return True


def _score_for(db, uid: str, other: str):
    match = (
        db.collection("matches")
        .document(sorted_pair_key(uid, other))
        .get()
    )
    if match.exists:
        return (match.to_dict() or {}).get("score")
    cand = (
        db.collection("users")
        .document(uid)
        .collection("match_candidates")
        .document(other)
        .get()
    )
    if cand.exists:
        return (cand.to_dict() or {}).get("heuristic_score")
    return None


def _blocked(db, uid: str, other: str) -> bool:
    blocks = db.collection("blocks")
    return (
        blocks.document(block_id(uid, other)).get().exists
        or blocks.document(block_id(other, uid)).get().exists
    )


def _like_state(db, uid: str, other: str) -> tuple[bool, bool]:
    """``(you_liked, mutual)`` — for the Explore filter chips."""
    try:
        you = (
            db.collection("users").document(uid)
            .collection("likes").document(other).get().exists
        )
        if not you:
            return (False, False)
        them = (
            db.collection("users").document(other)
            .collection("likes").document(uid).get().exists
        )
        return (True, them)
    except Exception:  # noqa: BLE001
        return (False, False)


def _primary_photo_path(db, other: str, photos: list) -> str | None:
    """Storage path of the profile's first *resolvable* photo, or ``None``.

    ``profile.photos`` is ``[{media_id, order}]`` — the real ``storage_path``
    lives on ``users/{other}/user_media/{media_id}``. Older docs inlined
    ``storage_path`` on the entry itself; both shapes are handled. Entries are
    walked in ``order``, and the FIRST that resolves to a real storage path
    wins — a broken lowest-order entry (empty ``media_id`` or a dangling
    ``user_media`` doc) is skipped rather than blanking the tile (Issue F1;
    mirrors ``main._primary_profile_photo_path``). ``None`` only when every
    entry is exhausted. Any lookup failure just yields ``None`` — a missing
    photo never breaks the feed.
    """
    try:
        entries = [p for p in (photos or []) if isinstance(p, dict)]
        if not entries:
            return None
        entries.sort(key=lambda p: p.get("order", 0))
        for e in entries:
            sp = str(e.get("storage_path") or "").strip()  # legacy inline shape
            if sp:
                return sp
            media_id = str(e.get("media_id") or "").strip()
            if not media_id:
                continue
            media = (
                db.collection("users")
                .document(other)
                .collection("user_media")
                .document(media_id)
                .get()
                .to_dict()
            ) or {}
            sp = str(media.get("storage_path") or "").strip()
            if sp:
                return sp
        return None
    except Exception:  # noqa: BLE001 - a photo lookup must never 500 Explore
        logger.warning("explore: photo lookup failed for %s", other, exc_info=True)
        return None


_PAGE_DEFAULT = 24

# Scan rounds per page request. Filters cut candidates after the scan, so one
# page may need several bounded rounds to fill; the cap keeps a single
# request's reads bounded no matter how selective the filters are.
_PAGE_MAX_ROUNDS = 8


def _encode_cursor(last_uid: str) -> str:
    """Opaque page cursor: base64url JSON ``{tier, last_score, last_uid}``.

    Phase 2 pagination design (``docs/perf/phase2-pagination-design.md``
    §3.1.2) cursor shape. Globally score-ordered pages (tier 2) need a
    score-queryable match index the current schema doesn't have, so pages
    scan the deterministic uid-ordered roster (tier 3) and sort score-first
    within the page instead.
    """
    payload = json.dumps(
        {"v": 1, "tier": 3, "last_score": None, "last_uid": last_uid},
        separators=(",", ":"),
    ).encode("utf-8")
    return base64.urlsafe_b64encode(payload).decode("ascii")


def _decode_cursor(cursor: str | None) -> str | None:
    """Last scanned uid from an opaque cursor, or ``None`` for page 1.

    Tolerates missing keys; anything malformed restarts at page 1 rather
    than erroring the feed.
    """
    if not cursor:
        return None
    try:
        raw = base64.urlsafe_b64decode(cursor.encode("ascii")).decode("utf-8")
        data = json.loads(raw)
        last_uid = (data if isinstance(data, dict) else {}).get("last_uid")
        return str(last_uid) if last_uid else None
    except Exception:  # noqa: BLE001 - a malformed cursor restarts page one
        return None


def _card_sort_key(c: dict) -> tuple:
    # Your own card pins to the top; then scored matches high-to-low, then
    # the rest. uid breaks score ties so paging is deterministic.
    return (not c["self"], c["score"] is None, -(c["score"] or 0), c["uid"])


def _scan_user_batch(db, last_uid: str | None, n: int) -> list:
    """One bounded ``users`` id-ordered scan round → user snaps after
    ``last_uid`` (or from the start when ``None``)."""
    q = db.collection("users").order_by("__name__").limit(max(1, int(n)))
    if last_uid:
        anchor = db.collection("users").document(last_uid).get()
        if anchor.exists:
            q = q.start_after(anchor)
        # A deleted anchor restarts the scan rather than erroring; the
        # client's uid dedup absorbs any repeated cards.
    return list(q.stream())


def _batch_docs(db, refs: list) -> list:
    """Batched ``get_all`` fetch with a per-doc fallback for fakes without it."""
    if not refs:
        return []
    get_all = getattr(db, "get_all", None)
    if get_all is None:
        return [r.get() for r in refs]
    return list(get_all(refs))


def _hydrate_candidates(db, uid: str, others: list[str]) -> dict:
    """One batched read for every doc card assembly needs per candidate:
    ``profile/main``, both block directions, both like directions, the pair
    match doc, and the caller's match candidate. Returns
    ``{(other, kind): dict-or-None}``."""
    users = db.collection("users")
    keyed: list[tuple[tuple[str, str], object]] = []
    for other in others:
        if other == uid:
            # Self needs only its profile — pair docs (blocks/likes/match)
            # are never read for the caller's own card.
            keyed.append((
                (other, "profile"),
                users.document(other).collection("profile").document("main"),
            ))
            continue
        keyed.extend([
            ((other, "profile"),
             users.document(other).collection("profile").document("main")),
            ((other, "block_fwd"),
             db.collection("blocks").document(block_id(uid, other))),
            ((other, "block_rev"),
             db.collection("blocks").document(block_id(other, uid))),
            ((other, "like_out"),
             users.document(uid).collection("likes").document(other)),
            ((other, "like_in"),
             users.document(other).collection("likes").document(uid)),
            ((other, "match"),
             db.collection("matches").document(sorted_pair_key(uid, other))),
            ((other, "cand"),
             users.document(uid).collection("match_candidates").document(other)),
        ])
    snaps = _batch_docs(db, [ref for _, ref in keyed])
    # Firestore get_all() returns documents in ARBITRARY order, not the request
    # order, so results MUST be matched back to each requested ref by document
    # path — never by list position. A positional zip mismaps every candidate's
    # profile/blocks/likes: the feed comes back blank (profiles resolve to None
    # → candidates dropped) or, worse, one person's data lands under another's
    # name. (founder bug 2026-11-01)
    by_path = {
        snap.reference.path: snap
        for snap in snaps
        if getattr(snap, "reference", None) is not None
        and getattr(snap.reference, "path", None) is not None
    }
    out: dict[tuple[str, str], dict | None] = {}
    if len(by_path) == len(keyed) == len(snaps):
        for key, ref in keyed:
            snap = by_path.get(ref.path)
            out[key] = (
                snap.to_dict() if (snap is not None and snap.exists) else None
            )
    else:
        # Fallback for test fakes whose get_all() returns snapshots without a
        # resolvable .reference: those fakes always preserve request order, so
        # positional mapping is correct for them (real Firestore snapshots
        # always carry .reference, so the path map above is always used there).
        for key, snap in zip([k for k, _ in keyed], snaps):
            out[key] = snap.to_dict() if snap.exists else None
    return out


def _first_media_id(photos) -> str | None:
    """Media id the batched page read should resolve, or ``None``.

    Walks entries in ``order`` and returns the first non-empty ``media_id``,
    skipping a lowest-order entry whose ``media_id`` is empty (Issue F1) so a
    valid later photo still gets batched. Returns ``None`` once an entry
    carries an inline ``storage_path`` (legacy shape — no lookup needed;
    :func:`_first_photo_path` reads it directly) or no photo needs resolving.
    """
    entries = [p for p in (photos or []) if isinstance(p, dict)]
    if not entries:
        return None
    entries.sort(key=lambda p: p.get("order", 0))
    for e in entries:
        if e.get("storage_path"):  # legacy inline — no user_media lookup
            return None
        media_id = str(e.get("media_id") or "").strip()
        if media_id:
            return media_id
    return None


def _first_photo_path(prof: dict, media_path: str | None) -> str | None:
    entries = [p for p in (prof.get("photos") or []) if isinstance(p, dict)]
    if not entries:
        return None
    first = min(entries, key=lambda p: p.get("order", 0))
    if first.get("storage_path"):  # legacy inline shape
        return str(first["storage_path"])
    return media_path


def _media_paths(db, jobs: list[tuple[str, str]]) -> dict[str, str | None]:
    """``{other: storage_path}`` for candidates whose first photo needs a
    ``user_media`` lookup — one batched read for the whole page."""
    if not jobs:
        return {}
    refs = [
        db.collection("users").document(other)
        .collection("user_media").document(media_id)
        for other, media_id in jobs
    ]
    out: dict[str, str | None] = {}
    for (other, _media_id), snap in zip(jobs, _batch_docs(db, refs)):
        media = snap.to_dict() if snap.exists else None
        out[other] = (
            str(media["storage_path"])
            if media and media.get("storage_path")
            else None
        )
    return out


def _build_card(
    db,
    uid: str,
    other: str,
    prof: dict,
    docs: dict,
    media_path: str | None,
) -> dict:
    photo_path = _first_photo_path(prof, media_path)
    # Fast batched read resolved nothing for the lowest-order photo (a
    # dangling user_media doc, or an inline path that sits on a later entry),
    # yet the profile does list photos — walk them to recover the first that
    # resolves instead of blanking the tile (Issue F1). Only this broken
    # entry-0 case pays the extra per-row read; normal accounts keep the
    # single batched lookup above.
    if not photo_path and any(
        isinstance(p, dict) for p in (prof.get("photos") or [])
    ):
        photo_path = _primary_photo_path(db, other, prof.get("photos"))
    # A ready token URL, not a raw storage path — Storage rules only let a
    # user read their *own* uploads/ tree, so the client can't resolve
    # another person's photo itself.
    photo_url = ""
    photo_url_thumb = ""
    if photo_path:
        try:
            from public_profile import _photo_url, _variant_url

            photo_url = _photo_url(photo_path) or ""
            # Smaller grid-sized variant when it exists (staging only);
            # falls back to the original when the variant is absent or
            # image variants are off (prod) — no extra GCS call then.
            photo_url_thumb = _variant_url(photo_path, "thumb", 400) or photo_url
        except Exception:  # noqa: BLE001 - never sink the feed on a photo
            photo_url = ""
            photo_url_thumb = ""

    if other == uid:
        liked, mutual, score = False, False, None
    else:
        you = docs.get((other, "like_out")) is not None
        liked = you
        mutual = you and docs.get((other, "like_in")) is not None
        match = docs.get((other, "match"))
        if match is not None:
            score = match.get("score")
        else:
            score = (docs.get((other, "cand")) or {}).get("heuristic_score")
    return {
        "uid": other,
        "name": prof.get("name", ""),
        "age": _age(prof.get("birthdate")),
        "location": prof.get("location", ""),
        "photo_path": photo_path,  # kept for back-compat
        "photo_url": photo_url,
        "photo_url_thumb": photo_url_thumb,
        "score": score,
        "liked": liked,
        "mutual": mutual,
        "self": other == uid,
        "paused": other == uid and prof.get("paused") is True,
    }


def _fetch_candidates_wiki_text(db, uids: list[str]) -> dict[str, list[str]]:
    """Public wiki page text for each candidate to evaluate search keywords."""
    if not uids:
        return {}

    def _one(other_uid: str) -> tuple[str, list[str]]:
        try:
            pages = (
                db.collection("users")
                .document(other_uid)
                .collection("wiki_pages")
                .stream()
            )
            texts = []
            for p in pages:
                data = p.to_dict() or {}
                if data.get("visibility") == "public" and not data.get("user_hidden"):
                    title = str(data.get("title") or "")
                    body = str(
                        data.get("ai_body")
                        or data.get("content")
                        or data.get("body")
                        or ""
                    )
                    if title or body:
                        texts.append(f"{title} {body}")
            return (other_uid, texts)
        except Exception:
            return (other_uid, [])

    workers = min(len(uids), 8)
    if workers > 1:
        try:
            with ThreadPoolExecutor(max_workers=workers) as executor:
                return dict(executor.map(_one, uids))
        except Exception:
            return {u: _one(u)[1] for u in uids}
    return {uids[0]: _one(uids[0])[1]}


def explore_page(
    db, uid: str, filters: dict, limit: int = _PAGE_DEFAULT,
    cursor: str | None = None,
) -> tuple[list[dict], str | None]:
    """One bounded page of the Explore feed → ``(cards, next_cursor)``.

    ``next_cursor`` is ``None`` at the end of the feed. Callers must
    deduplicate by uid across pages — a profile edited mid-browse can
    legitimately reappear across a page boundary. Every request costs a
    bounded number of reads (scan rounds × page size), independent of the
    total user count.
    """
    page_size = max(1, min(int(limit or _PAGE_DEFAULT), 60))
    last_uid = _decode_cursor(cursor)
    first_page = last_uid is None

    me = (
        db.collection("users")
        .document(uid)
        .collection("profile")
        .document("main")
        .get()
        .to_dict()
    )
    if not me:
        return ([], None)
    passed = {
        s.id
        for s in db.collection("users")
        .document(uid)
        .collection("explore_passed")
        .stream()
    }
    # A designated e2e/demo viewer (config.explore_fixture_bypass_uids) sees
    # seeded test fixtures so the e2e harness can still verify a real
    # dealbreaker profile renders in Explore; real users never match.
    bypass_fixtures = uid in set(config.CONFIG.explore_fixture_bypass_uids)
    mirror_active = any(filters.get(k) for k in _PHYSICAL_MIRROR_FILTER_KEYS)

    cards: list[dict] = []
    seen: set[str] = set()
    exhausted = False
    has_search = bool(filters.get("keywords") or filters.get("q"))
    for _ in range(_PAGE_MAX_ROUNDS):
        if len(cards) >= page_size:
            break
        batch = _scan_user_batch(db, last_uid, page_size)
        if not batch:
            exhausted = True
            break
        last_uid = batch[-1].id
        if len(batch) < page_size:
            exhausted = True
        user_data = {s.id: (s.to_dict() or {}) for s in batch}
        others = [s.id for s in batch if s.id not in seen]
        seen.update(others)
        docs = _hydrate_candidates(db, uid, others)
        wiki_texts = _fetch_candidates_wiki_text(db, others) if has_search else {}
        passers: list[tuple[str, dict]] = []
        for other in others:
            # Explore lists everyone with a profile, the caller included — no
            # orientation or community gating (product decision, 2026-08-30).
            # Only blocks / paused / already-passed, practice-date personas
            # and the EXPLICIT search filters cut the roster down. The viewer's
            # saved partner age range (qz_partner_age_min/max) is never a hard
            # filter on the default feed — a dealbreaker surfaces as a 0% score,
            # not a hidden person (founder bug 2026-11-01).
            if other in passed:
                continue
            # Practice-date simulator personas are never real people (BUG E).
            if practice_seed.is_practice_persona(other):
                continue
            # Seeded test fixtures (demo-edge-*, flagged exclude_from_explore)
            # must never reach a real user's Explore. A designated e2e/demo
            # viewer still sees them (bypass_fixtures). Self is always exempt.
            if (
                other != uid
                and not bypass_fixtures
                and _is_test_fixture(other, user_data.get(other) or {})
            ):
                continue
            if not first_page and other == uid:
                continue  # self pins to page 1 only
            prof = docs.get((other, "profile"))
            if not prof:
                continue
            # A profile with no name isn't a real, set-up person —
            # half-finished onboarding or a test fixture. Keep it out of the
            # feed (self is exempt so you always see your own card).
            if other != uid and not str(prof.get("name") or "").strip():
                continue
            # "Pause matching" (§14.2) hides you from *other* people's
            # Explore; you still see your own card (so you can tell you're
            # paused and un-pause).
            if other != uid and prof.get("paused") is True:
                continue
            if other != uid and (
                docs.get((other, "block_fwd")) is not None
                or docs.get((other, "block_rev")) is not None
            ):
                continue
            # Only spend the extra read on a search that actually touches a
            # physical-attributes filter key (the common case doesn't).
            public_fields = (
                physical_attributes.public_fields(db, other)
                if mirror_active
                else None
            )
            if not _passes_filters(
                prof,
                filters,
                public_fields=public_fields,
                extra_text=wiki_texts.get(other),
            ):
                continue
            passers.append((other, prof))
        media_jobs = [
            (other, media_id)
            for other, prof in passers
            if (media_id := _first_media_id(prof.get("photos")))
        ]
        media = _media_paths(db, media_jobs)
        for other, prof in passers:
            try:
                cards.append(
                    _build_card(db, uid, other, prof, docs, media.get(other))
                )
            except Exception:  # noqa: BLE001 - one bad row never sinks a page
                logger.warning(
                    "explore: skipped %s (row build failed)",
                    other, exc_info=True,
                )
                continue
            if len(cards) >= page_size:
                break
        if exhausted:
            break

    if first_page and not any(c["uid"] == uid for c in cards):
        # Self pins to page 1 even when the uid scan hasn't reached it yet —
        # the caller's own card is always shown first (it still honors the
        # active search filters, exactly as before). Page 1 may then hold
        # one card over the page size; trimming would lose a scanned row.
        try:
            me_wiki = _fetch_candidates_wiki_text(db, [uid]).get(uid) if has_search else None
            if _passes_filters(me, filters, extra_text=me_wiki):
                self_media_id = _first_media_id(me.get("photos"))
                self_media = (
                    _media_paths(db, [(uid, self_media_id)]).get(uid)
                    if self_media_id
                    else None
                )
                cards.insert(
                    0,
                    _build_card(db, uid, uid, me, {(uid, "profile"): me},
                                self_media),
                )
        except Exception:  # noqa: BLE001 - a bad self row never sinks page 1
            logger.warning("explore: skipped self row", exc_info=True)

    cards.sort(key=_card_sort_key)
    next_cursor = (
        _encode_cursor(last_uid) if (not exhausted and last_uid) else None
    )
    return (cards, next_cursor)


def explore(db, uid: str, filters: dict, limit: int = 30) -> list[dict]:
    """Full-roster Explore feed (legacy shape) — backend callers that need
    every candidate (e.g. DM outreach) and pre-pagination tests.

    Pages internally through :func:`explore_page` and sorts once globally,
    so results match the old full-scan order: self pinned, scored
    high-to-low, then the rest.
    """
    if limit is not None and int(limit) <= 0:
        return []
    want = max(1, min(int(limit or 30), 10_000))
    out: list[dict] = []
    seen_ids: set[str] = set()
    cursor: str | None = None
    while len(out) < want:
        page, cursor = explore_page(
            db, uid, filters, limit=min(want - len(out), 100), cursor=cursor
        )
        for c in page:
            if c["uid"] not in seen_ids:
                seen_ids.add(c["uid"])
                out.append(c)
        if cursor is None:
            break
    out.sort(key=_card_sort_key)
    return out[:want]


def merge_filters(query_params: dict, nl_filters: dict) -> dict:
    """Explicit dropdown filters win over the NL parse."""
    merged = {k: v for k, v in (nl_filters or {}).items() if v not in (None, "", [])}
    merged.update({k: v for k, v in query_params.items() if v not in (None, "", [])})
    return merged


def apply_saved_age_range(filters: dict, profile: dict | None) -> dict:
    """Default the Explore age filter to the user's saved partner age range
    (``qz_partner_age_min`` / ``qz_partner_age_max``). A bound the search
    itself set (dropdown or natural language) is never overridden."""
    out = dict(filters)
    profile = profile or {}
    for key, saved in (
        ("age_min", profile.get("qz_partner_age_min")),
        ("age_max", profile.get("qz_partner_age_max")),
    ):
        if out.get(key) is None and isinstance(saved, int):
            out[key] = saved
    return out
