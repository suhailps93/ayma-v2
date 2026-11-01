"""Structured physical-profile extraction (ARCHITECTURE.md §6.3 companion).

One record per user that answers "what do they look like" in a filterable
shape. It is built from two sources and merges them with a fixed precedence:

* **stated** — anything the user has explicitly self-reported, read from the
  structured ``profile/main`` fields and, failing that, scanned out of their
  wiki narrative. A stated value always wins and is never overridden by a
  photo.
* **photo** — one multi-image Gemini vision pass over the user's whole profile
  photo set (plus any extra photo they attached to the chat turn). Low
  confidence by design — "unknown" is a first-class value.

The full per-field record (``{value, source, confidence, note}``) is written to
``users/{uid}/physical_attributes/current``; a flat value-only mirror is written
to ``profile/main.physical_attrs`` so Explore can filter on it cheaply without a
second read.

Everything here is best-effort: :func:`refresh` never raises, so a photo upload
or a chat turn is never blocked by it.

Boundary with ``photo_attrs`` (see :mod:`photo_attrs`) — the two mirrors on
``profile/main`` are different pipeline stages, not duplicates:
``physical_attrs`` (this module) is the merged user-level record — one
multi-image photo pass plus the user's stated self-report, stated always
wins, mirrored value-only (known fields) for cheap Explore filtering —
while ``photo_attrs`` is the per-upload snapshot, overwritten by every
profile-photo upload with that photo's record. Explore prefers
``photo_attrs`` for the 7 overlapping ``_PHOTO_FIELDS`` (strict match) and
reads the physical-only fields here with unknown-never-excludes
semantics; per-field visibility gating applies to this mirror only.
Unifying the two would change filter behaviour, so the split is
intentional.
"""

from __future__ import annotations

import json
import logging
import re
from functools import lru_cache
from pathlib import Path

from prompt import load_prompt_file
import gemini
import media_embed
import schema
import token_ledger
from config import CONFIG

logger = logging.getLogger("ayma.physical")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "physical_attributes.md"
_SCHEMA_PATH = Path(__file__).with_name("explore_filter_schema.json")

# users/{uid}/physical_attributes/current
COLLECTION = "physical_attributes"
DOC_ID = "current"
# users/{uid}/physical_attributes/visibility — see `public_fields`/`set_public`
# below. Deliberately a SIBLING doc to `current`, not a key inside it:
# `refresh()` fully overwrites `current` (`.set(doc)`, not a merge) on every
# photo-pipeline run, so a per-field privacy choice stored inside that same
# record would get silently wiped the next time a photo triggers a
# re-extraction. This doc is never touched by `refresh()`.
VISIBILITY_DOC_ID = "visibility"
# users/{uid}/physical_reports/{auto-id} — one immutable doc per explicit,
# user-invoked run, so the app can list past runs and re-open any of them as a
# report (mirrors face_reports / body_reports / deep_dives).
REPORTS_COLLECTION = "physical_reports"
# The flat value-only mirror on profile/main.
PROFILE_MIRROR_FIELD = "physical_attrs"

# How many profile photos to feed the vision pass (newest-first by grid order).
_MAX_PHOTOS = 6

_NUMERIC_FIELDS = ("height_estimate_cm", "weight_estimate_kg")
_FREE_TEXT_FIELDS = ("race_ethnicity", "distinguishing_features")

_PHOTO_NOTE = "extracted from pictures"
_STATED_NOTE = "from your answers"


@lru_cache(maxsize=1)
def _spec() -> list[dict]:
    return json.loads(_SCHEMA_PATH.read_text())["physical_attributes"]


@lru_cache(maxsize=1)
def fields() -> tuple[str, ...]:
    """Ordered tuple of every physical-attribute field name."""
    return tuple(f["field"] for f in _spec())


@lru_cache(maxsize=1)
def _enum_values() -> dict[str, tuple[str, ...]]:
    return {
        f["field"]: tuple(f["values"])
        for f in _spec()
        if f["type"] == "enum"
    }


@lru_cache(maxsize=1)
def field_schema() -> tuple[dict, ...]:
    """Every field shaped for a client-side edit UI: ``{field, type}`` plus
    ``values`` for an ``enum`` field (``unknown`` dropped — it's a sentinel
    for "we don't know", never something a user picks). Backs
    ``GET /physical-attributes/schema``; reads straight off :func:`_spec` so
    the client never carries its own copy of the enum lists validation
    enforces."""
    out: list[dict] = []
    for f in _spec():
        entry = {"field": f["field"], "type": f["type"]}
        if f["type"] == "enum":
            entry["values"] = [v for v in f["values"] if v != "unknown"]
        out.append(entry)
    return tuple(out)


@lru_cache(maxsize=1)
def _response_schema() -> dict:
    """Each field is ``{value, confidence}``; enums constrain ``value``."""
    props: dict[str, dict] = {}
    for f in _spec():
        if f["type"] == "enum":
            value = {"type": "string", "enum": list(f["values"])}
        else:
            # numbers come back as a string ("unknown" or a plain integer) so
            # one schema shape covers every field.
            value = {"type": "string"}
        props[f["field"]] = {
            "type": "object",
            "properties": {
                "value": value,
                "confidence": {
                    "type": "string",
                    "enum": ["low", "medium", "high"],
                },
                # 1-based positions (in the order photos were given) of the
                # photo(s) that actually show this — lets the caller record
                # per-finding provenance (§ appearance report). Optional: an
                # empty/missing list just falls back to "the whole current
                # photo set" for that field.
                "evidence": {"type": "array", "items": {"type": "integer"}},
            },
            "required": ["value", "confidence"],
        }
    return {"type": "object", "properties": props, "required": list(props)}


# --- the photo pass -----------------------------------------------------------


def _sanitize_evidence(raw, n: int) -> list[int]:
    """1-based image positions the model claims support one field, filtered
    to valid range, de-duplicated in order, capped small."""
    if not isinstance(raw, list):
        return []
    out: list[int] = []
    for v in raw:
        try:
            i = int(v)
        except (TypeError, ValueError):
            continue
        if 1 <= i <= n and i not in out:
            out.append(i)
        if len(out) >= 4:
            break
    return out


async def extract_from_photos(
    images: list[tuple[bytes, str]], *, uid: str | None = None
) -> dict:
    """Run the one multi-image vision pass. Returns ``{field: {value,
    confidence, evidence}}`` — ``evidence`` is a list of 1-based positions
    into ``images`` (possibly empty); on any failure every field comes back
    ``unknown``/``low``/``[]``."""
    blank = {
        f: {"value": _blank_value(f), "confidence": "low", "evidence": []}
        for f in fields()
    }
    if not images:
        return blank
    try:
        result = await gemini.generate_json(
            "Extract this person's physical attributes from the photo set.",
            system_prompt=load_prompt_file(_PROMPT_PATH),
            response_schema=_response_schema(),
            images=images,
            uid=uid,
            feature=token_ledger.FEATURE_PHYSICAL_ATTRS,
            enforce_cap=False,
        )
    except Exception:  # noqa: BLE001 - best-effort, like photo_attrs
        logger.exception("physical-attribute extraction failed for %s", uid)
        return blank
    if not isinstance(result, dict):
        return blank

    out: dict[str, dict] = {}
    for f in fields():
        raw = result.get(f)
        if not isinstance(raw, dict):
            out[f] = {"value": _blank_value(f), "confidence": "low", "evidence": []}
            continue
        out[f] = {
            "value": _coerce(f, raw.get("value")),
            "confidence": _conf(raw.get("confidence")),
            "evidence": _sanitize_evidence(raw.get("evidence"), len(images)),
        }
    return out


def _blank_value(field: str):
    return None if field in _NUMERIC_FIELDS else "unknown"


def _conf(value) -> str:
    v = str(value or "").strip().lower()
    return v if v in ("low", "medium", "high") else "low"


def _coerce(field: str, value):
    """Normalise a model / stated raw value into the field's storage type."""
    if field in _NUMERIC_FIELDS:
        return _as_int(value)
    text = str(value or "").strip()
    if field in _enum_values():
        low = text.lower()
        return low if low in _enum_values()[field] else "unknown"
    if field in _FREE_TEXT_FIELDS:
        low = text.lower()
        if not text or low == "unknown":
            return "unknown" if field == "race_ethnicity" else ""
        return text
    return text or "unknown"


def _as_int(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return int(value) if value else None
    m = re.search(r"-?\d+", str(value or ""))
    return int(m.group()) if m else None


def _is_known(field: str, value) -> bool:
    if field in _NUMERIC_FIELDS:
        return isinstance(value, int)
    return bool(value) and str(value).strip().lower() != "unknown"


# --- the stated self-report -------------------------------------------------


def resolve_stated(db, uid: str) -> dict:
    """Explicit self-reports, structured fields first then a wiki scan. Returns
    ``{field: coerced_value}`` for fields the user has actually stated."""
    out: dict = {}
    try:
        prof = (
            db.collection("users")
            .document(uid)
            .collection("profile")
            .document("main")
            .get()
            .to_dict()
        ) or {}
    except Exception:  # noqa: BLE001
        prof = {}
    for f in fields():
        if _is_known(f, _coerce(f, prof.get(f))):
            out[f] = _coerce(f, prof.get(f))

    try:
        import wiki_query

        text = wiki_query.read_wiki_context(db, uid)
    except Exception:  # noqa: BLE001 - a wiki read failure just means no scan
        text = ""
    for f, v in _scan_wiki(text).items():
        out.setdefault(f, v)
    return out


def _scan_wiki(text: str) -> dict:
    """Cheap keyword scan for an explicit self-report of an attribute. Modest
    on purpose — a miss just means the field stays photo-derived."""
    t = (text or "").lower()
    if not t:
        return {}
    out: dict = {}

    def _near(colour: str, noun: str) -> bool:
        return bool(
            re.search(rf"\b{colour}\b[\w\s'-]{{0,14}}\b{noun}\b", t)
            or re.search(rf"\b{noun}\b[\w\s'-]{{0,14}}\b{colour}\b", t)
        )

    for c in ("brown", "blue", "green", "hazel", "grey", "gray"):
        if _near(c, "eyes?"):
            out["eye_color"] = "grey" if c == "gray" else c
            break
    for c in ("black", "brown", "blonde", "blond", "red", "grey", "gray"):
        if _near(c, "hair"):
            out["hair_color"] = {"blond": "blonde", "gray": "grey"}.get(c, c)
            break
    if re.search(r"\bbald\b|\bshaved head\b", t):
        out["hair_length"] = "bald"
    else:
        for c in ("short", "medium", "long", "shoulder-length", "buzzed"):
            if _near(c, "hair"):
                out["hair_length"] = {
                    "shoulder-length": "medium", "buzzed": "short"
                }.get(c, c)
                break
    for c in ("straight", "wavy", "curly", "coily", "kinky"):
        if _near(c, "hair"):
            out["hair_type"] = "coily" if c == "kinky" else c
            break
    for c in ("slim", "slender", "average", "athletic", "muscular", "curvy",
              "heavy", "stocky", "petite"):
        if re.search(rf"\b{c}\b[\w\s]{{0,10}}\b(build|physique|frame|body)\b", t) \
                or re.search(rf"\bi'?m\s+(?:quite\s+|pretty\s+|very\s+)?{c}\b", t):
            out["build"] = {
                "slender": "slim", "petite": "slim",
                "muscular": "athletic", "stocky": "heavy",
            }.get(c, c)
            break
    for c in ("fair", "light", "medium", "olive", "brown", "dark", "pale",
              "tan", "tanned"):
        if _near(c, "skin") or _near(c, "complexion"):
            out["skin_tone"] = {
                "pale": "fair", "tan": "medium", "tanned": "medium",
            }.get(c, c)
            break

    h = _height_cm(t)
    if h:
        out["height_estimate_cm"] = h
    w = _weight_kg(t)
    if w:
        out["weight_estimate_kg"] = w

    win = re.search(
        r"(?:ethnicity|heritage|descent|ancestry|ethnically|i'?m|i am)"
        r"[^.\n]{0,40}?\b("
        r"east asian|south asian|southeast asian|middle eastern|latino|latina|"
        r"hispanic|white|black|caucasian|mixed(?:[- ]race)?|indigenous|pacific "
        r"islander)\b",
        t,
    )
    if win:
        out["race_ethnicity"] = win.group(1).title()
    return out


def _height_cm(t: str) -> int | None:
    m = re.search(r"\b(1[.,]\d{2})\s?m(?:etre|eter)?s?\b", t)
    if m:
        return round(float(m.group(1).replace(",", ".")) * 100)
    m = re.search(r"\b(1[4-9]\d|2[0-2]\d)\s?cm\b", t)
    if m:
        return int(m.group(1))
    m = re.search(r"\b([4-7])\s?(?:'|ft|feet|foot)\s?(\d{1,2})?\s?(?:\"|in|inch|inches)?", t)
    if m:
        feet = int(m.group(1))
        inch = int(m.group(2) or 0)
        return round(feet * 30.48 + inch * 2.54)
    return None


def _weight_kg(t: str) -> int | None:
    m = re.search(r"\b(4\d|[5-9]\d|1\d\d|2[0-4]\d)\s?kg\b", t)
    if m:
        return int(m.group(1))
    m = re.search(r"\b(\d{2,3})\s?(?:lb|lbs|pounds)\b", t)
    if m:
        return round(int(m.group(1)) * 0.45359)
    return None


# --- the merge ------------------------------------------------------------------


def merge(photo: dict, stated: dict, photo_paths: list[str] | None = None) -> dict:
    """``{field: {value, source, confidence, note}}``. A stated value wins and
    is labelled ``source:"stated"``; otherwise the photo read is used with
    ``source:"photo"``; an unknown on both sides is ``source:"none"``.

    ``photo_paths`` — when given (even ``[]``) — turns on a 5th key,
    ``photo_ids``: the Storage paths that are the basis for this field
    (positionally aligned with whatever image list produced ``photo``'s
    per-field ``evidence``, e.g. ``physical_attributes.refresh``'s
    ``images_full``). A ``stated``/``none`` field always gets ``[]`` (no photo
    is the basis); a ``photo`` field falls back to the whole ``photo_paths``
    list when the model gave no usable evidence indices. Omitted entirely
    (the pre-provenance 4-key shape) when ``photo_paths`` is ``None`` — kept
    for callers that never pass photo-set context."""
    track_photos = photo_paths is not None
    paths = list(photo_paths or [])
    out: dict = {}
    for f in fields():
        if f in stated and _is_known(f, stated[f]):
            out[f] = {
                "value": stated[f],
                "source": "stated",
                "confidence": "high",
                "note": _STATED_NOTE,
            }
            if track_photos:
                out[f]["photo_ids"] = []
            continue
        p = photo.get(f) or {}
        pv = _coerce(f, p.get("value"))
        if _is_known(f, pv):
            out[f] = {
                "value": pv,
                "source": "photo",
                "confidence": _conf(p.get("confidence")),
                "note": _PHOTO_NOTE,
            }
            if track_photos:
                evidence = p.get("evidence") or []
                ids = [
                    paths[i - 1] for i in evidence
                    if isinstance(i, int) and 1 <= i <= len(paths) and paths[i - 1]
                ]
                out[f]["photo_ids"] = ids or [path for path in paths if path]
        else:
            out[f] = {
                "value": _blank_value(f),
                "source": "none",
                "confidence": "none",
                "note": "",
            }
            if track_photos:
                out[f]["photo_ids"] = []
    return out


def flat_mirror(record: dict) -> dict:
    """Value-only map for ``profile/main.physical_attrs`` — known fields only."""
    return {
        f: rec["value"]
        for f, rec in record.items()
        if _is_known(f, rec.get("value"))
    }


_LABELS = {
    "race_ethnicity": "ethnicity (apparent)",
    "skin_tone": "skin tone",
    "eye_color": "eyes",
    "hair_color": "hair",
    "hair_length": "hair length",
    "hair_type": "hair type",
    "height_estimate_cm": "height (rough)",
    "weight_estimate_kg": "weight (rough)",
    "build": "build",
    "facial_hair": "facial hair",
    "glasses": "glasses",
    "visible_tattoos": "tattoos",
    "visible_piercings": "piercings",
    "distinguishing_features": "notable features",
}


def _display_value(field: str, value) -> str:
    if field == "height_estimate_cm":
        return f"~{value}cm"
    if field == "weight_estimate_kg":
        return f"~{value}kg"
    return str(value)


def summary(record: dict) -> str:
    """A short human line for Ayma to relay."""
    parts: list[str] = []
    for f in fields():
        rec = record.get(f) or {}
        if not _is_known(f, rec.get("value")):
            continue
        tag = "stated" if rec.get("source") == "stated" else "from photos"
        parts.append(f"{_LABELS[f]}: {_display_value(f, rec['value'])} ({tag})")
    if not parts:
        return "I couldn't read any physical attributes yet — add a clear photo."
    return "Physical profile — " + "; ".join(parts) + "."


def render_markdown(record: dict) -> str:
    """A grouped, source-tagged rendering of the record for the private wiki
    ("AI notes" / the private story). Re-running replaces this block wholesale.
    Returns ``""`` when nothing is known."""
    stated: list[str] = []
    photo: list[str] = []
    for f in fields():
        rec = record.get(f) or {}
        if not _is_known(f, rec.get("value")):
            continue
        line = f"- {_LABELS[f]}: {_display_value(f, rec['value'])}"
        (stated if rec.get("source") == "stated" else photo).append(line)
    if not stated and not photo:
        return ""
    out = [
        "Physical profile — Ayma's structured read of what the user looks "
        "like, used to sharpen matching and Explore search. Stated values are "
        "the user's own answers; photo values are apparent and lower "
        "confidence.",
    ]
    if stated:
        out += ["", "From the user's own answers:", *stated]
    if photo:
        out += ["", "Apparent from their photos:", *photo]
    return "\n".join(out).strip()


# --- orchestration -----------------------------------------------------------


def gather_profile_images(db, uid: str) -> list[tuple[bytes, str, str]]:
    """Download the user's visible grid photos as ``(bytes, mime,
    storage_path)``, in grid order, capped at ``_MAX_PHOTOS``. Failures are
    skipped."""
    try:
        prof = (
            db.collection("users")
            .document(uid)
            .collection("profile")
            .document("main")
            .get()
            .to_dict()
        ) or {}
    except Exception:  # noqa: BLE001
        return []
    # Public grid + removed-from-public photos kept for analysis (§8.3).
    entries = schema.analysis_photo_entries(prof)
    out: list[tuple[bytes, str, str]] = []
    for e in entries[:_MAX_PHOTOS]:
        sp = str(e.get("storage_path") or "").strip()  # legacy inline shape
        if not sp:
            mid = str(e.get("media_id") or "").strip()
            if not mid:
                continue
            try:
                media = (
                    db.collection("users")
                    .document(uid)
                    .collection("user_media")
                    .document(mid)
                    .get()
                    .to_dict()
                ) or {}
            except Exception:  # noqa: BLE001
                continue
            sp = str(media.get("storage_path") or "").strip()
        if not sp:
            continue
        try:
            data, mime = media_embed.download_bytes(sp)
        except Exception:  # noqa: BLE001
            continue
        if data:
            out.append((data, mime or "image/jpeg", sp))
    return out


async def refresh(
    db,
    uid: str,
    *,
    extra_images: list[tuple[bytes, str, str]] | None = None,
    persist_report: bool = False,
) -> dict | None:
    """Rebuild ``uid``'s physical-attributes record and write both docs.

    ``extra_images`` are ``(bytes, mime, storage_path)`` tuples; pass ``""``
    for ``storage_path`` when the caller genuinely has none.

    Idempotent and best-effort — never raises. Safe to run concurrently with a
    photo-pipeline ``background.add_task(refresh)`` (last write wins). Returns
    the stored ``physical_attributes/current`` dict (carrying ``report_id`` when
    ``persist_report``), or ``None`` when there was nothing to read. The
    returned doc's ``photo_paths`` lists the Storage paths actually used to
    derive the record (``photo_count`` is just ``len(photo_paths)``, kept
    alongside it for callers that only need the count).

    ``persist_report`` marks an explicit, user-invoked run: it also appends an
    immutable ``physical_reports`` history doc and promotes the private-wiki
    "Physical profile" section into the user's own story. Background photo-set
    refreshes leave ``persist_report`` off — they still keep ``current``, the
    flat mirror and the ``private`` wiki section fresh.
    """
    if not uid:
        return None
    source = "user" if persist_report else "auto"
    try:
        images_full = gather_profile_images(db, uid) + list(extra_images or [])
        if not images_full:
            logger.info("physical-attrs: no photos for %s, skipping", uid)
            _record_run(db, uid, "skipped", source, "no_photos")
            return None
        images = [(b, m) for b, m, _ in images_full]
        photo_paths_full = [p for _, _, p in images_full]  # aligned with `images`
        photo_paths = [p for p in photo_paths_full if p]

        photo = await extract_from_photos(images, uid=uid)
        stated = resolve_stated(db, uid)
        record = merge(photo, stated, photo_paths_full)
        rendered = summary(record)

        from firebase_admin import firestore

        doc = {
            "fields": record,
            "updated_at": firestore.SERVER_TIMESTAMP,
            "photo_count": len(images),
            "photo_paths": photo_paths,
            "model": CONFIG.gemini_model,
        }
        db.collection("users").document(uid).collection(COLLECTION).document(
            DOC_ID
        ).set(doc)
        db.collection("users").document(uid).collection("profile").document(
            "main"
        ).set({PROFILE_MIRROR_FIELD: flat_mirror(record)}, merge=True)

        report_id = ""
        if persist_report:
            report_id = _store_report(
                db, uid, record, rendered, len(images), photo_paths
            )
            if report_id:
                doc["report_id"] = report_id
                db.collection("users").document(uid).collection(
                    COLLECTION
                ).document(DOC_ID).set(
                    {
                        "report_id": report_id,
                        "reported_at": firestore.SERVER_TIMESTAMP,
                    },
                    merge=True,
                )

        _ingest_wiki(db, uid, record, promote=persist_report)
        _record_run(db, uid, "ok", source, f"photos={len(images)}")
        return doc
    except token_ledger.TokenCapExceeded:
        logger.info("physical-attrs: skipped for %s (credit cap)", uid)
        _record_run(db, uid, "skipped", source, "capped")
        return None
    except Exception as exc:  # noqa: BLE001 - never break the caller
        logger.exception("physical-attrs refresh failed for %s", uid)
        _record_run(db, uid, "error", source, str(exc)[:200])
        return None


def _record_run(db, uid: str, status: str, source: str, detail: str = "") -> None:
    """Stamp the skill-run ledger for this ``physical_attributes`` run. Best-
    effort — a ledger failure never touches the refresh outcome."""
    try:
        import skill_runs

        skill_runs.record(
            db, uid, skill_runs.PHYSICAL_ATTRIBUTES,
            status=status, source=source, detail=detail,
        )
    except Exception:  # noqa: BLE001
        logger.exception("physical-attrs: skill-run record failed for %s", uid)


def _store_report(
    db,
    uid: str,
    record: dict,
    rendered: str,
    photo_count: int,
    photo_paths: list[str] | None = None,
) -> str:
    """Append an immutable ``physical_reports`` history doc. Returns its id, or
    ``""`` on any failure — never raises."""
    try:
        from firebase_admin import firestore

        ref = (
            db.collection("users")
            .document(uid)
            .collection(REPORTS_COLLECTION)
            .add(
                {
                    "fields": record,
                    "photo_count": photo_count,
                    "photo_paths": list(photo_paths or []),
                    "summary": rendered,
                    "model": CONFIG.gemini_model,
                    "created_at": firestore.SERVER_TIMESTAMP,
                }
            )
        )
        if isinstance(ref, tuple):
            return getattr(ref[1], "id", "") or ""
        return getattr(ref, "id", "") or ""
    except Exception:  # noqa: BLE001
        logger.exception("physical-attrs: report history write failed for %s", uid)
        return ""


def _ingest_wiki(db, uid: str, record: dict, *, promote: bool) -> None:
    """Upsert the "Physical profile" section into the user's private wiki so it
    shows in "AI notes"; on an explicit run also promote it into the user's own
    story. Mirrors how face / body reports use ``skill_memory``. Never raises."""
    try:
        import skill_memory

        body = render_markdown(record)
        if not body:
            return
        skill_memory.save_physical_profile(db, uid, body)
        if promote:
            skill_memory.promote(db, uid, "physical_profile")
    except Exception:  # noqa: BLE001 - wiki ingest is best-effort
        logger.exception("physical-attrs: wiki ingest failed for %s", uid)


def current(db, uid: str) -> dict | None:
    """The caller's stored ``physical_attributes/current`` doc, or ``None``."""
    try:
        snap = (
            db.collection("users")
            .document(uid)
            .collection(COLLECTION)
            .document(DOC_ID)
            .get()
        )
    except Exception:  # noqa: BLE001
        return None
    return snap.to_dict() if getattr(snap, "exists", False) else None


# --- attribute visibility (§ founder 2026-09-20: default-private; § founder --
# 2026-09-21: repurposed for heuristic search) --------------------------------
#
# Every physical-attribute field starts PRIVATE — until the user explicitly
# makes a specific field public. Originally (2026-09-20) this gated a display
# section: `report_adapters.story_public_blocks` showed a non-owner only a
# block for a field in `public_fields(...)`. That display section was removed
# again the next day (§ founder: "The attributes section should be part of
# the report that shows face and physique analysis. Don't have to duplicate
# anywhere else") — there is currently no live UI path that ever calls
# `set_public` any more (it briefly did, via `report_hub`'s make-public/
# make-private quick action on an attr: block routed through
# `report_hub._correct_appearance`'s `allow_visibility`, since removed too).
#
# The flag itself lives on: it's now consulted by `explore._passes_filters`
# (§ founder: "Use it for the heuristic search tho") — a private field can't
# be used to find or filter out its owner in an Explore search, the same way
# it couldn't be shown on their public Story.
#
# This is unrelated to Appearance's own "Attributes" section
# (`report_adapters.appearance_blocks`) — that report is always self-owned/
# private-to-the-owner already, so it reads the record directly and never
# consults this at all.


def _visibility_doc(db, uid: str) -> dict:
    try:
        snap = (
            db.collection("users")
            .document(uid)
            .collection(COLLECTION)
            .document(VISIBILITY_DOC_ID)
            .get()
        )
    except Exception:  # noqa: BLE001
        return {}
    return (snap.to_dict() or {}) if getattr(snap, "exists", False) else {}


def public_fields(db, uid: str) -> set[str]:
    """Field names ``uid`` has explicitly made public. Anything NOT in this
    set is private by default — including a field that's never been touched
    at all, and any field name this doc has stale/garbage data for."""
    doc = _visibility_doc(db, uid)
    pub = doc.get("public") if isinstance(doc, dict) else None
    if not isinstance(pub, dict):
        return set()
    return {f for f, v in pub.items() if v and f in fields()}


def is_public(db, uid: str, field: str) -> bool:
    return field in public_fields(db, uid)


def set_public(db, uid: str, field: str, public: bool) -> bool:
    """Make ``field`` public (or private again) on ``uid``'s Story-public
    Living Report. Read-modify-write on the whole ``public`` map, rather than
    a bare ``set({"public": {field: v}}, merge=True)``, so this never
    depends on Firestore's (or a test fake's) nested-map merge semantics —
    it works the same regardless. Returns ``False`` (no-op, nothing written)
    for an unrecognised field; best-effort otherwise — never raises."""
    if field not in fields():
        return False
    try:
        ref = (
            db.collection("users")
            .document(uid)
            .collection(COLLECTION)
            .document(VISIBILITY_DOC_ID)
        )
        cur = ref.get().to_dict() or {}
        pub = dict(cur.get("public") or {})
        pub[field] = bool(public)
        ref.set({"public": pub}, merge=True)
    except Exception:  # noqa: BLE001
        logger.exception("physical-attrs: visibility write failed for %s/%s", uid, field)
        return False
    return True


async def backfill_missing(db, *, user_limit: int = 200) -> dict:
    """Run :func:`refresh` for every user who has a profile but no
    ``physical_attributes/current`` doc yet. Bounded by ``user_limit``."""
    scanned = refreshed = 0
    try:
        users = list(db.collection("users").stream())
    except Exception:  # noqa: BLE001
        logger.exception("physical-attrs backfill: user scan failed")
        return {"users": 0, "refreshed": 0}
    for snap in users:
        if scanned >= user_limit:
            break
        uid = snap.id
        try:
            if current(db, uid) is not None:
                continue
            prof = (
                db.collection("users")
                .document(uid)
                .collection("profile")
                .document("main")
                .get()
                .to_dict()
            ) or {}
            if not prof.get("photos"):
                continue
            scanned += 1
            if await refresh(db, uid) is not None:
                refreshed += 1
        except Exception:  # noqa: BLE001
            logger.exception("physical-attrs backfill failed for %s", uid)
    return {"users": scanned, "refreshed": refreshed}
