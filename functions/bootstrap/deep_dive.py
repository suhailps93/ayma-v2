"""Deep-dive web research on a named person (§ deep dive).

Given a full name (+ optional disambiguating context) this runs a two-step
Gemini pass:

1. a grounded research call (``google_search`` + ``url_context``) that sweeps
   the open web and writes up what it finds, with source links;
2. a structured digest of that write-up — a short "who this appears to be",
   the specific claims (each with a source and a confidence), and the links
   (each flagged likely / maybe / unclear as being the same person).

Two callers:

* the user on **themselves** — "look me up so I don't have to repeat it".
  Ayma then walks the digest with them; their confirmations land in the wiki
  through the normal ingest path (nothing is written to the wiki here).
* the user on **someone they're meeting** — a private research note shown only
  to them. Never written to anyone's wiki.
"""

from __future__ import annotations

import hashlib
import logging
import re
import time
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path

import gemini
import report_blocks as rb
import schema
from token_ledger import FEATURE_DEEPDIVE

_PROMPTS_PATH = Path(__file__).with_name("prompts") / "deep_dive.md"

logger = logging.getLogger("ayma.deepdive")

# A dive is cached per (caller, subject) and reused instead of re-searching the
# web, as long as it's younger than this. The web changes slowly for the kind
# of facts a dive surfaces, and a fresh search is the single most expensive
# thing Ayma does (§ cost review 2026-09-07).
_MAX_CACHE_AGE_DAYS = 60
_CACHE_COL = "deep_dives"


def _cache_key(target_uid: str, name: str) -> str:
    """Stable id for a dive subject: the app uid when we have one, else a slug
    of the name so a free-text "look up Jane Doe" reuses too."""
    t = (target_uid or "").strip()
    if t:
        return f"uid_{t}"
    slug = re.sub(r"[^a-z0-9]+", "-", (name or "").strip().lower()).strip("-")
    return f"name_{slug}" if slug else ""


def _cache_ref(db, uid: str, key: str):
    return (
        db.collection("users")
        .document(uid)
        .collection(_CACHE_COL)
        .document(key)
    )


def _epoch(ts) -> float:
    try:
        return ts.timestamp()
    except Exception:  # noqa: BLE001
        return 0.0


def cached_dive(
    db,
    uid: str,
    *,
    target_uid: str = "",
    name: str = "",
    max_age_days: int = _MAX_CACHE_AGE_DAYS,
) -> dict | None:
    """A stored digest for this (caller, subject) if one exists and is younger
    than ``max_age_days`` — else ``None``. Best-effort; a read failure is a miss.
    The returned dict carries ``from_cache`` / ``cached_age_days``."""
    key = _cache_key(target_uid, name)
    if not db or not uid or not key:
        return None
    try:
        snap = _cache_ref(db, uid, key).get()
        if not snap.exists:
            return None
        data = snap.to_dict() or {}
        digest = data.get("digest")
        if not isinstance(digest, dict):
            return None
        age_days = (time.time() - _epoch(data.get("created_at"))) / 86400
        if age_days < 0 or age_days > max_age_days:
            return None
        out = dict(digest)
        out["from_cache"] = True
        out["cached_age_days"] = round(age_days, 1)
        return out
    except Exception:  # noqa: BLE001
        logger.exception("deep-dive cache read failed for %s/%s", uid, key)
        return None


def store_dive(
    db, uid: str, digest: dict, *, target_uid: str = "", name: str = ""
) -> None:
    """Persist a fresh digest so the next dive on the same subject reuses it —
    this is the ONE persistent "about me" report doc for a subject, updated in
    place run after run, never a new doc per run (§ persistent web-search
    report).

    A fresh research pass fully replaces ``digest`` (it's a new sweep of the
    live web), but three things a user has told Ayma directly must survive
    that replacement rather than silently vanish on the next re-run:
    ``disputed_facts`` (§ Part 2, fact disputes), ``corrections`` (free-text
    corrections, § deep-dive corrections) and any user-confirmed reverse-image
    photo (``digest.confirmed_photos`` — § web photo search) that the fresh
    digest wouldn't independently know about. Everything else in the new
    digest wins outright — the whole point of re-running is to trust what the
    live web says now.
    """
    key = _cache_key(target_uid, name)
    if not db or not uid or not key or not isinstance(digest, dict):
        return
    try:
        from firebase_admin import firestore

        ref = _cache_ref(db, uid, key)
        prior = {}
        try:
            snap = ref.get()
            if getattr(snap, "exists", False):
                prior = snap.to_dict() or {}
        except Exception:  # noqa: BLE001
            prior = {}

        digest = dict(digest)
        prior_confirmed = (prior.get("digest") or {}).get("confirmed_photos") or []
        if prior_confirmed and not digest.get("confirmed_photos"):
            digest["confirmed_photos"] = prior_confirmed

        payload = {
            "digest": digest,
            "name": digest.get("name") or name,
            "target_uid": (target_uid or "").strip(),
            "created_at": prior.get("created_at") or firestore.SERVER_TIMESTAMP,
            "updated_at": firestore.SERVER_TIMESTAMP,
        }
        if prior.get("disputed_facts"):
            payload["disputed_facts"] = prior["disputed_facts"]
        if prior.get("corrections"):
            payload["corrections"] = prior["corrections"]
        ref.set(payload)
    except Exception:  # noqa: BLE001
        logger.exception("deep-dive cache write failed for %s/%s", uid, key)


def dive_report_id(target_uid: str = "", name: str = "") -> str:
    """The stable id of the stored dive for a subject — same value used as the
    ``deep_dives`` doc id and the ``[deep_dive:<id>]`` chat marker."""
    return _cache_key(target_uid, name)


def merge_confirmed_photo(db, uid: str, report_id: str, photo: dict) -> bool:
    """Append one user-confirmed reverse-image-search photo
    (:mod:`reverse_image_search`) into this self-dive's persisted
    ``digest.confirmed_photos`` — the one place a confirmed web photo becomes
    part of the persistent "about me" report. ``photo`` is
    ``{candidate_id, image_url, source_url, source_title, confirmed_at}``.

    Deduped by ``image_url`` — confirming the same candidate twice is a
    no-op. Returns ``False`` (no-op) when there's no report to attach to yet
    — the confirmation itself still lives on the candidate doc, so the next
    self-dive research run picks it up once a report exists (§ store_dive)."""
    report_id = (report_id or "").strip()
    if not db or not uid or not report_id or not isinstance(photo, dict):
        return False
    ref = _cache_ref(db, uid, report_id)
    try:
        snap = ref.get()
        if not getattr(snap, "exists", False):
            return False
        data = snap.to_dict() or {}
        digest = data.get("digest")
        if not isinstance(digest, dict):
            return False
        digest = dict(digest)
        confirmed = list(digest.get("confirmed_photos") or [])
        if any(c.get("image_url") == photo.get("image_url") for c in confirmed):
            return True
        confirmed.append(photo)
        digest["confirmed_photos"] = confirmed
        ref.set({"digest": digest}, merge=True)
        return True
    except Exception:  # noqa: BLE001
        logger.exception(
            "deep-dive: merging confirmed photo failed for %s/%s", uid, report_id
        )
        return False


def read_dive(db, uid: str, report_id: str) -> dict | None:
    """The stored dive doc for ``report_id`` (a :func:`dive_report_id` value),
    or ``None``. Best-effort — a read failure is a miss."""
    report_id = (report_id or "").strip()
    if not db or not uid or not report_id:
        return None
    try:
        snap = _cache_ref(db, uid, report_id).get()
        if not getattr(snap, "exists", False):
            return None
        data = snap.to_dict() or {}
        if not isinstance(data.get("digest"), dict):
            return None
        return data
    except Exception:  # noqa: BLE001
        logger.exception("deep-dive report read failed for %s/%s", uid, report_id)
        return None


def has_dive(db, uid: str, *, target_uid: str = "", name: str = "") -> bool:
    """Whether a stored dive exists for this subject (any age)."""
    return read_dive(db, uid, _cache_key(target_uid, name)) is not None


def report_owner(report_id: str, requester_uid: str) -> str:
    """The Firestore owner (subject) uid a stored dive id should be read
    from. A ``uid_<subject>``-shaped id is self-describing — it names a known
    app user, and that person's own collection is where their persistent
    "about me" report lives, shared by every caller who's ever searched them
    (§ persistent web-search report). Anything else (a name-only self/unlinked
    dive) always lives under whoever's asking — unchanged, existing
    behaviour."""
    report_id = (report_id or "").strip()
    if report_id.startswith("uid_") and len(report_id) > len("uid_"):
        return report_id[len("uid_"):]
    return requester_uid


def subject_report(
    db, target_uid: str, name: str, *, max_age_days: int = _MAX_CACHE_AGE_DAYS
) -> dict | None:
    """The best existing persisted report on a known app user ``target_uid``
    that a fresh web search should defer to, checked in priority order:

    1. Their own self-dive (name-keyed, under their own collection) — this is
       their confirmed word, corrections already applied
       (:func:`correct_finding` / :func:`dispute_fact` write straight to this
       doc) — so it's reused regardless of age.
    2. The shared cross-user report (``uid_<target_uid>``, also under their
       own collection — see :func:`store_dive`'s caller) — reused within
       ``max_age_days``, same staleness rule as any other dive.

    Returns ``{"report_id", "digest", "mirror"}`` or ``None`` when neither
    exists yet (a fresh search is needed). ``mirror`` is ``True`` when the
    caller should also write this digest to the ``uid_<target_uid>`` doc, so
    that id (self-describing, shared by everyone who searches this person)
    resolves to it too."""
    target_uid = (target_uid or "").strip()
    name = (name or "").strip()
    if not db or not target_uid or not name:
        return None
    self_data = read_dive(db, target_uid, _cache_key("", name))
    if self_data is not None:
        digest = dict(self_data.get("digest") or {})
        return {
            "report_id": dive_report_id(target_uid=target_uid),
            "digest": digest,
            "mirror": True,
        }
    hit = cached_dive(
        db, target_uid, target_uid=target_uid, name=name, max_age_days=max_age_days
    )
    if hit is not None:
        return {
            "report_id": dive_report_id(target_uid=target_uid),
            "digest": hit,
            "mirror": False,
        }
    return None


def reusable_report(
    db,
    uid: str,
    *,
    target_uid: str = "",
    name: str = "",
    is_self: bool = False,
    max_age_days: int = _MAX_CACHE_AGE_DAYS,
) -> dict | None:
    """A dive digest servable without a fresh web search, or ``None`` to go
    ahead and search. Self dives never reuse — always ``None``.

    A dive on a known app user (``target_uid`` given) prefers *that person's
    own* existing report over a private per-caller cache — see
    :func:`subject_report` — so "user A searches user B" shares B's report
    (with B's own corrections) with every A/C/D who searches B, rather than
    each searcher quietly re-running the same web search
    (§ founder: don't rerun a search when the subject already has a report).
    An unlinked name-only lookup (no ``target_uid``) keeps the old, private,
    per-caller cache — unchanged."""
    if not db or not uid or is_self:
        return None
    target_uid = (target_uid or "").strip()
    if target_uid:
        existing = subject_report(db, target_uid, name, max_age_days=max_age_days)
        if existing is None:
            return None
        digest = dict(existing["digest"])
        digest["is_self"] = False
        digest.setdefault("from_cache", True)
        digest.setdefault("cached_age_days", 0)
        if existing["mirror"]:
            store_dive(db, target_uid, digest, target_uid=target_uid, name=name)
        return digest
    return cached_dive(db, uid, target_uid=target_uid, name=name, max_age_days=max_age_days)


def _profile_dict(db, uid: str) -> dict:
    try:
        return schema.profile_doc(db, uid).get().to_dict() or {}
    except Exception:  # noqa: BLE001 - a profile read must never break a lookup
        return {}


def profile_full_name(db, uid: str) -> str:
    """The subject's research name: ``"{first_name} {last_name}"`` when the
    profile carries both, else the plain ``name`` field (``""`` if neither)."""
    data = _profile_dict(db, uid)
    first = str(data.get("first_name", "")).strip()
    last = str(data.get("last_name", "")).strip()
    if first and last:
        return f"{first} {last}"
    return str(data.get("name", "")).strip()


# Wiki page types a self-dive can draw a compact disambiguation line from —
# enough to tell apart "same name, different person" or narrow a common name,
# never a full narrative dump (§ Part 1). "career" covers studies too, per
# wiki_schema.json's own description of that page type.
_WIKI_CONTEXT_TYPES = ("identity", "career", "interests")
_MAX_WIKI_CONTEXT = 350
_MAX_DISPUTED_CONTEXT = 300


def _first_sentence(body: str, limit: int) -> str:
    """The first sentence of ``body``, hard-capped at ``limit`` chars — a
    one-line pull, not the page's full prose."""
    body = re.sub(r"\s+", " ", (body or "")).strip()
    if not body:
        return ""
    m = re.match(r"(.{1,%d}?[.!?])(\s|$)" % max(limit, 1), body)
    sentence = (m.group(1) if m else body[:limit]).strip()
    if not sentence:
        return ""
    if not sentence.endswith((".", "!", "?")):
        sentence += "."
    return sentence


def wiki_dive_context(db, uid: str) -> str:
    """A compact, factual one-liner-per-page pull from the user's own wiki
    (``identity`` / ``career`` / ``interests``) — e.g. "Works as a robotics
    engineer at Acme; lives in Austin." Purely disambiguation material for a
    *self* web search: helping tell the right person apart from someone who
    shares their name, never a source of "fact" to report back or trust over
    what the web search actually turns up (the research/digest prompts in
    ``prompts/deep_dive.md`` say this explicitly)."""
    if not db or not uid:
        return ""
    try:
        snaps = list(
            db.collection("users").document(uid).collection("wiki_pages").stream()
        )
    except Exception:  # noqa: BLE001 - a wiki read failure must not break a dive
        logger.exception("deep-dive wiki-context read failed for %s", uid)
        return ""
    bodies: dict[str, str] = {}
    for snap in snaps:
        data = snap.to_dict() or {}
        pt = data.get("page_type")
        body = str(data.get("ai_body") or "").strip()
        if pt in _WIKI_CONTEXT_TYPES and body and pt not in bodies:
            bodies[pt] = body
    bits = [
        _first_sentence(bodies[pt], 140)
        for pt in _WIKI_CONTEXT_TYPES
        if bodies.get(pt)
    ]
    bits = [b for b in bits if b]
    if not bits:
        return ""
    return " ".join(bits)[:_MAX_WIKI_CONTEXT]


def disputed_facts_context(db, uid: str, name: str) -> str:
    """A note of claims the user already told Ayma are wrong about *this*
    subject, from a prior self-dive report — so a re-search doesn't just
    resurrect the same wrong claim (§ Part 2). Empty when there's no stored
    report for ``name`` yet, or nothing has been disputed on it."""
    key = _cache_key("", name)
    if not db or not uid or not key:
        return ""
    try:
        snap = _cache_ref(db, uid, key).get()
        if not getattr(snap, "exists", False):
            return ""
        data = snap.to_dict() or {}
        disputed = data.get("disputed_facts") or []
        claims = [
            str(d.get("claim", "")).strip()
            for d in disputed
            if isinstance(d, dict) and str(d.get("claim", "")).strip()
        ]
        if not claims:
            return ""
        note = (
            "The user has already told Ayma these specific claims are WRONG "
            "— do not report them again unless the web independently "
            "re-verifies them with new evidence: " + "; ".join(claims[:8]) + "."
        )
        return note[:_MAX_DISPUTED_CONTEXT]
    except Exception:  # noqa: BLE001
        logger.exception(
            "deep-dive disputed-facts read failed for %s/%s", uid, key
        )
        return ""


def profile_dive_context(db, uid: str, name: str = "") -> str:
    """Extra disambiguation drawn from the user's own profile and wiki for a
    *self* lookup: location as plain context, the phone number as a
    use-only-to-disambiguate note never fed into the search query, a compact
    factual pull from the user's own wiki (:func:`wiki_dive_context`), and —
    when ``name`` is given and this subject has a prior report with disputed
    facts — a note of the specific claims already told wrong
    (:func:`disputed_facts_context`). All of it is disambiguation material,
    never a source of "fact" the research/digest prompts should copy or trust
    over the live web (see ``prompts/deep_dive.md``)."""
    data = _profile_dict(db, uid)
    bits: list[str] = []
    loc = str(data.get(schema.PF_LOCATION, "")).strip()
    if loc:
        bits.append(f"Location: {loc}.")
    phone = str(data.get("phone", "")).strip()
    if phone:
        bits.append(
            f"(the user also gave the phone number {phone} — only use it to "
            f"disambiguate, never publish or repeat it)"
        )
    wiki_bit = wiki_dive_context(db, uid)
    if wiki_bit:
        bits.append(
            "What the user has told Ayma before (background for "
            f"disambiguation only, not verified — see instructions): {wiki_bit}"
        )
    if name:
        disputed_bit = disputed_facts_context(db, uid, name)
        if disputed_bit:
            bits.append(disputed_bit)
    return " ".join(bits)


def fact_id(fact: dict) -> str:
    """Stable id for one digest fact, derived from its claim + category text
    rather than array position — position shifts once facts start getting
    removed by a dispute (§ Part 2)."""
    claim = str((fact or {}).get("claim", "")).strip().lower()
    category = str((fact or {}).get("category", "")).strip().lower()
    basis = f"{category}|{claim}"
    return hashlib.sha1(basis.encode("utf-8")).hexdigest()[:12]


def dispute_fact(db, uid: str, report_id: str, target_fact_id: str) -> dict | None:
    """Mark one fact on a stored dive report incorrect: remove it from the
    persisted ``digest.facts`` and remember it as the user's own correction in
    ``disputed_facts`` on the same doc, so :func:`disputed_facts_context` picks
    it up on the next dive for this subject.

    Returns the updated ``{report_id, digest, disputed_facts}`` on success, or
    ``None`` when there's no such report or no such fact on it. Raises
    ``PermissionError`` when the report is about someone other than the
    caller — disputing a fact is a *self*-dive action only, never available on
    a report about someone the user looked up."""
    report_id = (report_id or "").strip()
    target_fact_id = (target_fact_id or "").strip()
    if not db or not uid or not report_id or not target_fact_id:
        return None
    ref = _cache_ref(db, uid, report_id)
    snap = ref.get()
    if not getattr(snap, "exists", False):
        return None
    data = snap.to_dict() or {}
    digest = data.get("digest")
    if not isinstance(digest, dict):
        return None
    target = str(data.get("target_uid") or "").strip()
    if target and target != uid:
        raise PermissionError("dispute is only ever available on a self-dive")

    kept: list[dict] = []
    removed: dict | None = None
    for f in digest.get("facts") or []:
        if not isinstance(f, dict):
            continue
        this_id = str(f.get("id") or "") or fact_id(f)
        if removed is None and this_id == target_fact_id:
            removed = f
            continue
        kept.append(f)
    if removed is None:
        return None

    digest = dict(digest)
    digest["facts"] = kept
    disputed = list(data.get("disputed_facts") or [])
    disputed.append(
        {
            "claim": str(removed.get("claim", "")).strip(),
            "category": str(removed.get("category", "")).strip(),
            "disputed_at": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        }
    )
    ref.set({"digest": digest, "disputed_facts": disputed}, merge=True)
    return {"report_id": report_id, "digest": digest, "disputed_facts": disputed}


def dispute_social_link(db, uid: str, report_id: str, url: str) -> dict | None:
    """Mark one social-profile link on a stored dive report as not the
    subject's: remove it from the persisted `digest.social_handles` and
    remember it in `disputed_social` on the same doc (audit trail, mirrors
    `disputed_facts` — parallel structure, not currently read back into a
    future re-dive's prompt the way `disputed_facts_context` is for facts;
    that's a known gap, matching the "known gap" precedent noted elsewhere
    in this file for face/body corrections).

    Returns the updated `{report_id, digest, disputed_social}` on success,
    `None` when there's no such report or no matching link. Raises
    `PermissionError` for a report about someone other than the caller —
    self-dive only, same rule as `dispute_fact`."""
    report_id = (report_id or "").strip()
    url = (url or "").strip()
    if not db or not uid or not report_id or not url:
        return None
    ref = _cache_ref(db, uid, report_id)
    snap = ref.get()
    if not getattr(snap, "exists", False):
        return None
    data = snap.to_dict() or {}
    digest = data.get("digest")
    if not isinstance(digest, dict):
        return None
    target = str(data.get("target_uid") or "").strip()
    if target and target != uid:
        raise PermissionError("dispute is only ever available on a self-dive")

    kept: list[dict] = []
    removed: dict | None = None
    for s in digest.get("social_handles") or []:
        if not isinstance(s, dict):
            continue
        if removed is None and str(s.get("url") or "").strip() == url:
            removed = s
            continue
        kept.append(s)
    if removed is None:
        return None

    digest = dict(digest)
    digest["social_handles"] = kept
    disputed = list(data.get("disputed_social") or [])
    disputed.append(
        {
            "url": url,
            "platform": str(removed.get("platform", "")).strip(),
            "disputed_at": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        }
    )
    ref.set({"digest": digest, "disputed_social": disputed}, merge=True)
    return {"report_id": report_id, "digest": digest, "disputed_social": disputed}


def dispute_web_image(db, uid: str, report_id: str, url: str) -> dict | None:
    """Same as `dispute_social_link` but for one entry of `digest.web_images`
    (a "photos of you found online" thumbnail), tracked in `disputed_photos`.
    Self-dive only; same return/exception shape."""
    report_id = (report_id or "").strip()
    url = (url or "").strip()
    if not db or not uid or not report_id or not url:
        return None
    ref = _cache_ref(db, uid, report_id)
    snap = ref.get()
    if not getattr(snap, "exists", False):
        return None
    data = snap.to_dict() or {}
    digest = data.get("digest")
    if not isinstance(digest, dict):
        return None
    target = str(data.get("target_uid") or "").strip()
    if target and target != uid:
        raise PermissionError("dispute is only ever available on a self-dive")

    kept: list[dict] = []
    removed: dict | None = None
    for im in digest.get("web_images") or []:
        if not isinstance(im, dict):
            continue
        if removed is None and str(im.get("url") or "").strip() == url:
            removed = im
            continue
        kept.append(im)
    if removed is None:
        return None

    digest = dict(digest)
    digest["web_images"] = kept
    disputed = list(data.get("disputed_photos") or [])
    disputed.append(
        {
            "url": url,
            "source_page": str(removed.get("source_page", "")).strip(),
            "disputed_at": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        }
    )
    ref.set({"digest": digest, "disputed_photos": disputed}, merge=True)
    return {"report_id": report_id, "digest": digest, "disputed_photos": disputed}


_MAX_CORRECTIONS = 30


async def correct_finding(
    db, uid: str, report_id: str, *, target: str, feedback: str
) -> dict | None:
    """One turn of free-text feedback on a single "about me" web-search
    finding — the same tap-a-claim-and-tell-Ayma-in-plain-language pattern as
    the Story editor's passage chat (``story.edit_section``), applied to a
    deep-dive report instead of a wiki section.

    ``target`` is ``"summary"`` or ``"fact:<fact_id>"``. Gemini reads the
    targeted claim (or the summary) plus the user's feedback and decides
    ``remove`` / ``revise`` / ``caveat`` / ``keep``; the change is applied to
    the persisted digest immediately, so it survives a reload and isn't lost
    to the next research re-run (:func:`store_dive` carries ``corrections``
    and any resulting ``disputed_facts`` entry forward). Every turn — whatever
    Gemini decides — is appended to ``corrections`` as a short audit trail,
    capped at :data:`_MAX_CORRECTIONS` (oldest dropped first).

    Returns ``{report_id, digest, reply, action}`` on success. ``None`` when
    there's no such report, or ``target`` names a fact that isn't on it.
    Raises ``PermissionError`` for a report about someone other than the
    caller — self-dives only, same rule as :func:`dispute_fact`. Propagates
    ``token_ledger.TokenCapExceeded``.
    """
    report_id = (report_id or "").strip()
    target = (target or "").strip()
    feedback = (feedback or "").strip()[:1000]
    if not db or not uid or not report_id or not target or not feedback:
        return None
    ref = _cache_ref(db, uid, report_id)
    snap = ref.get()
    if not getattr(snap, "exists", False):
        return None
    data = snap.to_dict() or {}
    digest = data.get("digest")
    if not isinstance(digest, dict):
        return None
    owner = str(data.get("target_uid") or "").strip()
    if owner and owner != uid:
        raise PermissionError(
            "a correction is only ever available on a self-dive"
        )

    fid = ""
    claim_text = ""
    source_url = ""
    if target == "summary":
        claim_text = str(digest.get("summary", "")).strip()
    elif target.startswith("fact:"):
        fid = target[len("fact:"):]
        for f in digest.get("facts") or []:
            if isinstance(f, dict) and (str(f.get("id") or "") or fact_id(f)) == fid:
                claim_text = str(f.get("claim", "")).strip()
                source_url = str(f.get("source_url", "")).strip()
                break
        else:
            return None
    else:
        return None

    result = await gemini.generate_json(
        f"Targeted item: {claim_text or '(empty)'}\n"
        f"Source: {source_url or '(none)'}\n"
        f"User's feedback: {feedback}",
        system_prompt=_CORRECTION_SYSTEM,
        response_schema=_CORRECTION_SCHEMA,
        uid=uid,
        feature=FEATURE_DEEPDIVE,
    )
    result = result if isinstance(result, dict) else {}
    action = str(result.get("action") or "keep").strip().lower()
    if action not in ("remove", "revise", "caveat", "keep"):
        action = "keep"
    reply = (
        str(result.get("reply") or "").strip()
        or "Got it — thanks for the correction."
    )
    note = str(result.get("note") or "").strip()
    revised_claim = str(result.get("revised_claim") or "").strip()

    digest = dict(digest)
    disputed = list(data.get("disputed_facts") or [])
    if target == "summary":
        if action == "revise" and revised_claim:
            digest["summary"] = revised_claim
        elif action == "caveat" and note:
            digest["caveats"] = f"{digest.get('caveats', '')} {note}".strip()
        # "remove" has no sensible meaning for the whole summary — nothing to
        # drop, so it falls through and only the audit trail records it.
    else:
        kept: list[dict] = []
        for f in digest.get("facts") or []:
            if not isinstance(f, dict):
                kept.append(f)
                continue
            this_id = str(f.get("id") or "") or fact_id(f)
            if this_id != fid:
                kept.append(f)
                continue
            if action == "remove":
                disputed.append(
                    {
                        "claim": claim_text,
                        "category": str(f.get("category", "")).strip(),
                        "disputed_at": datetime.now(timezone.utc).strftime(
                            "%Y-%m-%d"
                        ),
                    }
                )
                continue
            if action == "revise" and revised_claim:
                f = {**f, "claim": revised_claim, "id": fid}
            elif action == "caveat" and note:
                f = {**f, "claim": f"{f.get('claim', '')} ({note})".strip()}
            kept.append(f)
        digest["facts"] = kept

    corrections = list(data.get("corrections") or [])
    corrections.append(
        {
            "target": target,
            "feedback": feedback,
            "action": action,
            "reply": reply,
            "corrected_at": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        }
    )
    corrections = corrections[-_MAX_CORRECTIONS:]

    payload: dict = {"digest": digest, "corrections": corrections}
    if disputed:
        payload["disputed_facts"] = disputed
    ref.set(payload, merge=True)
    return {"report_id": report_id, "digest": digest, "reply": reply, "action": action}


@lru_cache(maxsize=1)
def _prompt_sections() -> dict[str, str]:
    """The ``## name`` sections of ``prompts/deep_dive.md``."""
    text = _PROMPTS_PATH.read_text(encoding="utf-8")
    out: dict[str, str] = {}
    key: str | None = None
    buf: list[str] = []
    for line in text.splitlines():
        m = re.match(r"^##\s+([\w-]+)\s*$", line)
        if m:
            if key is not None:
                out[key] = "\n".join(buf).strip()
            key, buf = m.group(1), []
        elif key is not None:
            buf.append(line)
    if key is not None:
        out[key] = "\n".join(buf).strip()
    return out


_RESEARCH_SYSTEM = _prompt_sections()["research_system"]

_DIGEST_SYSTEM = _prompt_sections()["digest_system"]

_CORRECTION_SYSTEM = _prompt_sections()["correction_system"]

_CORRECTION_SCHEMA = {
    "type": "object",
    "properties": {
        "action": {
            "type": "string",
            "enum": ["remove", "revise", "caveat", "keep"],
        },
        "revised_claim": {"type": "string"},
        "note": {"type": "string"},
        "reply": {"type": "string"},
    },
    "required": ["action", "reply"],
}

_DIGEST_SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "confidence": {
            "type": "string",
            "enum": ["high", "medium", "low", "not_found"],
        },
        "facts": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "claim": {"type": "string"},
                    "category": {
                        "type": "string",
                        "description": "work | education | location | "
                        "projects | writing | press | social | other",
                    },
                    "source_url": {"type": "string"},
                    "confidence": {
                        "type": "string",
                        "enum": ["high", "medium", "low"],
                    },
                },
                "required": ["claim", "category", "confidence"],
            },
        },
        "links": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "url": {"type": "string"},
                    "title": {"type": "string"},
                    "is_them": {
                        "type": "string",
                        "enum": ["likely", "maybe", "unclear"],
                    },
                    "note": {"type": "string"},
                },
                "required": ["url", "is_them"],
            },
        },
        "social_profiles": {
            "type": "array",
            "description": "Social-media profiles the notes tie to this "
            "person — never a guessed handle.",
            "items": {
                "type": "object",
                "properties": {
                    "platform": {
                        "type": "string",
                        "description": "instagram | x | twitter | linkedin | "
                        "facebook | tiktok | github | youtube",
                    },
                    "handle": {"type": "string"},
                    "url": {"type": "string"},
                    "tie_signal": {
                        "type": "string",
                        "description": "why this profile is this person "
                        "(name match, photo match, bio, linked from a "
                        "confirmed page)",
                    },
                },
                "required": ["platform"],
            },
        },
        "caveats": {"type": "string"},
    },
    "required": ["summary", "confidence", "facts", "links"],
}

_MAX_NAME = 120
# Room for the original location/phone bits plus the new wiki-disambiguation
# and disputed-facts additions (each separately capped above) — still a
# handful of short lines, never paragraphs.
_MAX_CONTEXT = 1000


async def run(
    name: str,
    *,
    db=None,
    uid: str | None = None,
    context: str = "",
    is_self: bool = False,
    target_uid: str = "",
    force: bool = False,
) -> dict:
    """Research ``name`` and return
    ``{name, summary, confidence, facts, links, caveats, is_self}``.

    Raises ``ValueError`` for an empty name. Metered to ``uid`` under the
    ``deepdive`` feature; a cap hit propagates ``TokenCapExceeded``.

    When ``db`` is given, a dive on *someone else* who is a known app user
    (``target_uid`` set) reuses THEIR OWN persisted report — their self-dive
    if they have one (any age, corrections included), else whatever the
    first person to search them already found (``_MAX_CACHE_AGE_DAYS``) —
    before ever searching again (see :func:`reusable_report`); an unlinked
    name-only lookup keeps the older, private, per-caller cache. Unless
    ``force`` is set. Researching **yourself** always re-searches — the cache
    exists so someone else looking you up (or reopening your saved report)
    doesn't retrigger a search, not so your own re-run goes stale; a fresh
    dive is written back to that same persisted report either way, and — for
    a dive on someone else — becomes THEIR persistent report too, not a
    private artifact only the searcher can see (§ persistent web-search
    report)."""
    name = (name or "").strip()[:_MAX_NAME]
    if not name:
        raise ValueError("a full name is required")
    context = (context or "").strip()[:_MAX_CONTEXT]
    target_uid = (target_uid or "").strip()

    if db is not None and uid and not force and not is_self:
        hit = reusable_report(
            db, uid, target_uid=target_uid, name=name, is_self=is_self
        )
        if hit is not None:
            hit["is_self"] = is_self
            logger.info(
                "deep-dive cache hit for %s (%.1fd old)",
                target_uid or uid,
                hit.get("cached_age_days", -1),
            )
            return hit

    who = "yourself" if is_self else "this person"
    # If the user has given Ayma their own LinkedIn URL (their own consent,
    # their own public page — never scraped, never an unofficial API call),
    # hand it straight to Gemini's `url_context` tool (already attached to
    # this call, see gemini.research) so it reads that page directly as part
    # of the same grounded research pass. § Your Story career timeline.
    linkedin_note = ""
    if is_self and db is not None and uid:
        try:
            import career_timeline

            linkedin_url = career_timeline.get_linkedin_url(db, uid)
            if linkedin_url:
                linkedin_note = (
                    "\nThe user has also given you their own LinkedIn profile "
                    f"URL — review it directly: {linkedin_url}"
                )
        except Exception:  # noqa: BLE001
            logger.exception("deep-dive: linkedin url lookup failed for %s", uid)
    ask = (
        f"Full name: {name}\n"
        f"Context: {context or '(none given)'}\n\n"
        f"Research {who} and write up everything you can find, with source "
        f"URLs inline.{linkedin_note}"
    )
    prose, sources = await gemini.research(
        ask,
        system_prompt=_RESEARCH_SYSTEM,
        uid=uid,
        feature=FEATURE_DEEPDIVE,
        max_output_tokens=6000,
    )

    src_lines = "\n".join(
        f"- {s['url']}  ({s.get('title', '')})" for s in sources
    )
    digest = await gemini.generate_json(
        f"Full name: {name}\nContext: {context or '(none)'}\n\n"
        f"RESEARCH NOTES:\n{prose or '(the search returned little)'}\n\n"
        f"SOURCE LINKS SEEN:\n{src_lines or '(none)'}",
        system_prompt=_DIGEST_SYSTEM,
        response_schema=_DIGEST_SCHEMA,
        uid=uid,
        feature=FEATURE_DEEPDIVE,
    )
    if not isinstance(digest, dict):
        digest = {}

    def _real_url(u: str) -> str:
        # Gemini grounding hands back opaque redirect URLs — useless to a
        # reader and ugly in the wiki. Drop them.
        u = str(u or "").strip()
        bad = ("vertexaisearch.cloud.google.com", "grounding-api-redirect")
        return "" if any(b in u for b in bad) else u

    facts = []
    for f in (digest.get("facts") or []):
        if not isinstance(f, dict):
            continue
        f = dict(f)
        f["source_url"] = _real_url(f.get("source_url", ""))
        # A stable id per fact — array position shifts once a dispute (§ Part
        # 2) starts removing entries, so the client needs something durable.
        f["id"] = fact_id(f)
        facts.append(f)
    links = []
    for ln in (digest.get("links") or []):
        if not isinstance(ln, dict):
            continue
        ln = dict(ln)
        ln["url"] = _real_url(ln.get("url", ""))
        if ln["url"]:
            links.append(ln)

    # Find photos of this person on the open web and keep only the ones whose
    # face matches their own profile photos. Works for self *and* an Explore
    # user — keyed to whichever person the dive is about. Best-effort.
    #
    # Two sources, merged: the Programmable Search image API (richer, needs
    # IMAGE_SEARCH_API_KEY / IMAGE_SEARCH_CSE_ID) and — always on, no key — the
    # primary image (og:image / twitter:image) of each link the dive already
    # tied to this person.
    web_images: list[dict] = []
    social_handles: list[dict] = []
    img_target = target_uid or (uid if is_self else "")
    if db is not None:
        try:
            import deep_dive_images

            loc = (
                str(_profile_dict(db, img_target).get("location") or "").strip()
                if img_target
                else ""
            )
            web_images = await deep_dive_images.find_web_images(
                db, img_target, name, extra_terms=loc, links=links, uid=uid
            )
        except Exception:  # noqa: BLE001
            logger.exception("deep-dive image step failed for %s", img_target)

        # Social-media handles the dive can tie to this person by name and/or a
        # profile-photo face match. Confidence-gated — an empty list when
        # nothing clears the bar (never a low-confidence guess).
        try:
            import deep_dive_social

            social_handles = deep_dive_social.find_social_handles(
                links,
                facts,
                name,
                summary_text=str(digest.get("summary", "")),
                digest_socials=digest.get("social_profiles") or [],
                db=db,
                target_uid=img_target or None,
            )
        except Exception:  # noqa: BLE001
            logger.exception("deep-dive social step failed")

    result = {
        "name": name,
        "is_self": is_self,
        "summary": str(digest.get("summary", "")).strip(),
        "confidence": str(digest.get("confidence", "not_found")),
        "facts": facts,
        "links": links,
        "web_images": web_images,
        "social_handles": social_handles,
        "caveats": str(digest.get("caveats", "")).strip(),
    }
    if db is not None and uid:
        # A dive on a known app user is stored under THAT PERSON's own
        # collection, never the caller's — it's their persistent "about me"
        # report from here on, whoever ran the search (§ persistent
        # web-search report). Self dives are unaffected (target_uid is empty,
        # subject_uid falls back to the caller = the subject).
        subject_uid = target_uid or uid
        store_dive(db, subject_uid, result, target_uid=target_uid, name=name)
        if target_uid and not is_self:
            # Also land it at the subject's own name-keyed self-dive slot —
            # the same doc `dive_report_id(name=...)` / "Search the web about
            # me" / corrections would use — so the person just searched sees
            # (and can correct) this same report if they later look
            # themselves up, instead of running a redundant search.
            store_dive(db, target_uid, result, target_uid="", name=name)
    return result


def teaser(digest: dict) -> str:
    """A one-line chat pointer at a stored dive — never the summary, facts,
    links, or photos themselves (those live in the report view; a chat
    message announcing a finished/reused dive should be a teaser + link, not
    the report's contents dumped inline — see :func:`render` for the older,
    full write-up this replaces in chat).

    "Is there anything to show yet" is :func:`report_blocks.digest_is_empty`
    — the same check ``report_adapters.deep_dive_blocks`` uses to decide
    between a real Summary section and a "Nothing found yet." placeholder —
    rather than a second, independently-maintained copy of that condition
    living here (§ founder: converge the drifted face/body/deep-dive
    ``teaser()`` functions). The "from_cache" reused-report note and the
    fresh-search line below it stay deep-dive's own: process metadata about
    HOW this result was produced, not something derivable from the block
    content itself."""
    name = digest.get("name") or "them"
    if rb.digest_is_empty(digest):
        return (
            f"I searched the web for {name} and didn't find much I could "
            f"confidently pin to one person. Want to tell me the basics yourself?"
        )
    who = "you" if digest.get("is_self") else name
    if digest.get("from_cache"):
        return f"Already had a web-search report on {who} — sharing that instead of searching again."
    return f"I looked {who} up online — here's what I found."


def render(digest: dict) -> str:
    """A short chat-ready summary of a :func:`run` result — what Ayma says
    before she starts confirming details with the user."""
    name = digest.get("name", "them")
    conf = digest.get("confidence", "not_found")
    if conf == "not_found" or (not digest.get("facts") and not digest.get("summary")):
        return (
            f"I searched the web for {name} and didn't find much I could "
            f"confidently pin to one person. Want to tell me the basics yourself?"
        )

    lines = []
    if digest.get("from_cache"):
        age = digest.get("cached_age_days") or 0
        when = "earlier today" if age < 1 else (
            "yesterday" if age < 2 else f"about {round(age)} days ago"
        )
        lines.append(f"_Reusing the search I ran {when} — nothing here changes "
                     f"fast. Ask me to search again if you want it fresh._")
        lines.append("")
    lines.append(digest.get("summary", "").strip())
    facts = digest.get("facts") or []
    if facts:
        lines.append("")
        for f in facts[:8]:
            claim = str(f.get("claim", "")).strip()
            if claim:
                lines.append(f"- {claim}")
    links = [ln for ln in (digest.get("links") or []) if ln.get("url")]
    if links:
        lines.append("")
        lines.append("Links I think are you/them:")
        for ln in links[:6]:
            tag = ln.get("is_them", "unclear")
            lines.append(f"- [{ln.get('title') or ln['url']}]({ln['url']}) ({tag})")
    imgs = digest.get("web_images") or []
    verified_imgs = [im for im in imgs if im.get("verified")]
    who_p = "you" if digest.get("is_self") else "them"
    if verified_imgs:
        n = len(verified_imgs)
        lines.append("")
        lines.append(
            f"I also found {n} photo{'s' if n != 1 else ''} online that look "
            f"like {who_p} — see them in the report."
        )
    elif imgs:
        lines.append("")
        lines.append(
            f"I found some photos online that might be {who_p}, but couldn't "
            "confirm the face — they're in the report, unverified."
        )
    socials = [s for s in (digest.get("social_handles") or []) if s.get("url")]
    if socials:
        lines.append("")
        lines.append(
            "Profiles I'm fairly sure are you:"
            if digest.get("is_self")
            else "Profiles I'm fairly sure are them:"
        )
        for s in socials[:6]:
            plat = str(s.get("platform", "")).strip() or "profile"
            handle = str(s.get("handle", "")).strip()
            label = f"@{handle}" if handle else (
                str(s.get("display_name", "")).strip() or s["url"]
            )
            tag = "verified" if s.get("confidence") == "high" else "likely"
            lines.append(
                f"- {plat.capitalize()}: [{label}]({s['url']}) ({tag})"
            )
    if digest.get("caveats"):
        lines.append("")
        lines.append(f"_{digest['caveats']}_")
    lines.append("")
    lines.append(
        "Which of these are right, and is anything off or missing?"
        if digest.get("is_self")
        else "Anything here you want me to keep in mind, or that looks wrong?"
    )
    return "\n".join(x for x in lines if x is not None).strip()
