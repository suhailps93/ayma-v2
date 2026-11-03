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

import asyncio
import hashlib
import logging
import re
import time
from datetime import datetime, timezone
from pathlib import Path

from prompt import load_prompt_sections
import deep_dive_links
import feature_flags
import gemini
import report_blocks as rb
import schema
import token_ledger
from timefmt import iso_or_str
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
    live web), but what a user has told Ayma directly must survive that
    replacement rather than silently vanish on the next re-run:
    ``disputed_facts`` (§ Part 2, fact disputes), ``disputed_links`` /
    ``disputed_social`` / ``disputed_photos`` (link/photo removals — the
    fresh sweep is also filtered against those URLs below, so a removed
    item doesn't resurface), ``corrections`` (free-text corrections,
    § deep-dive corrections) and any user-confirmed reverse-image photo
    (``digest.confirmed_photos`` — § web photo search) that the fresh
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

        # A user-removed link/social/photo must not resurface on a re-run:
        # the fresh sweep is filtered against the prior run's dispute audits
        # (facts get the same treatment via `disputed_facts_context` in the
        # research prompt instead — claims need fuzzy matching, URLs don't).
        for digest_key, audit_key in (
            ("links", "disputed_links"),
            ("social_handles", "disputed_social"),
            ("web_images", "disputed_photos"),
        ):
            bad = {
                str(a.get("url") or "").strip()
                for a in (prior.get(audit_key) or [])
                if isinstance(a, dict) and str(a.get("url") or "").strip()
            }
            if bad and isinstance(digest.get(digest_key), list):
                digest[digest_key] = [
                    e
                    for e in digest[digest_key]
                    if not (
                        isinstance(e, dict)
                        and str(e.get("url") or "").strip() in bad
                    )
                ]

        payload = {
            "digest": digest,
            "name": digest.get("name") or name,
            "target_uid": (target_uid or "").strip(),
            "created_at": prior.get("created_at") or firestore.SERVER_TIMESTAMP,
            "updated_at": firestore.SERVER_TIMESTAMP,
        }
        for key in (
            "disputed_facts",
            "disputed_links",
            "disputed_social",
            "disputed_photos",
        ):
            if prior.get(key):
                payload[key] = prior[key]
        if prior.get("corrections"):
            payload["corrections"] = prior["corrections"]
        ref.set(payload)
    except Exception:  # noqa: BLE001
        logger.exception("deep-dive cache write failed for %s/%s", uid, key)


def dive_report_id(target_uid: str = "", name: str = "") -> str:
    """The stable id of the stored dive for a subject — same value used as the
    ``deep_dives`` doc id and the ``[deep_dive:<id>]`` chat marker."""
    return _cache_key(target_uid, name)


# --- run status ---------------------------------------------------------------
# A queued dive is a background job; the app shows "Searching the web…" only
# while the caller's run doc for that report says ``running``. The doc lives
# beside the report (``users/{caller}/deep_dive_runs/{report_id}``), never in
# the report doc itself, so a run on someone with no report yet doesn't
# create a digest-less report. A job killed mid-run (instance shutdown) never
# writes its finish, so a ``running`` doc older than ``RUN_STALE_MINUTES`` is
# rewritten to ``failed`` the next time it's read.

_RUNS_COL = schema.DEEP_DIVE_RUNS
RUN_STALE_MINUTES = 10
RUN_RUNNING = "running"
RUN_DONE = "done"
RUN_FAILED = "failed"


def _run_ref(db, uid: str, report_id: str):
    return (
        db.collection("users")
        .document(uid)
        .collection(_RUNS_COL)
        .document(report_id)
    )


def mark_run(db, uid: str, report_id: str, status: str) -> None:
    """Record a dive run's status for ``uid``'s view of ``report_id``.
    ``running`` starts a new run; ``done`` / ``failed`` finish it.
    Best-effort: a write failure is logged, never raised."""
    report_id = (report_id or "").strip()
    if not db or not uid or not report_id:
        return
    try:
        from firebase_admin import firestore

        ref = _run_ref(db, uid, report_id)
        if status == RUN_RUNNING:
            ref.set({
                "status": RUN_RUNNING,
                "started_at": firestore.SERVER_TIMESTAMP,
                "finished_at": None,
            })
        else:
            ref.set(
                {"status": status, "finished_at": firestore.SERVER_TIMESTAMP},
                merge=True,
            )
    except Exception:  # noqa: BLE001
        logger.exception("deep-dive run status write failed for %s/%s", uid, report_id)


def run_status(db, uid: str, report_id: str, *, now: float | None = None) -> str:
    """``running`` / ``done`` / ``failed`` for ``uid``'s latest run on
    ``report_id``, or ``""`` when there's no run record. A ``running`` run
    started more than ``RUN_STALE_MINUTES`` ago is treated as failed and
    rewritten so (cleanup for jobs that died without finishing)."""
    report_id = (report_id or "").strip()
    if not db or not uid or not report_id:
        return ""
    try:
        snap = _run_ref(db, uid, report_id).get()
    except Exception:  # noqa: BLE001
        logger.exception("deep-dive run status read failed for %s/%s", uid, report_id)
        return ""
    if not getattr(snap, "exists", False):
        return ""
    data = snap.to_dict() or {}
    status = str(data.get("status") or "")
    if status != RUN_RUNNING:
        return status
    age = (now if now is not None else time.time()) - _epoch(data.get("started_at"))
    if age > RUN_STALE_MINUTES * 60:
        logger.warning(
            "deep-dive run for %s/%s stuck running for %ds; marking failed",
            uid, report_id, int(age),
        )
        mark_run(db, uid, report_id, RUN_FAILED)
        return RUN_FAILED
    return RUN_RUNNING


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


def _dispute_url_matches(entry: dict, url: str) -> bool:
    """Match one digest link-like entry against a stripped dispute URL."""
    return str(entry.get("url") or "").strip() == url


def _dispute_entry(
    db,
    uid: str,
    report_id: str,
    target: str,
    *,
    digest_key: str,
    disputed_key: str,
    matches,
    audit,
) -> dict | None:
    """One parameterized dispute path behind the four ``dispute_*`` wrappers.

    Removes the first ``digest[digest_key]`` entry for which
    ``matches(entry, target)`` holds and appends ``audit(removed, target)``
    to ``disputed_key`` on the same doc. Self-dive only; ``None`` when the
    report or the entry is missing.
    """
    report_id = (report_id or "").strip()
    target = (target or "").strip()
    if not db or not uid or not report_id or not target:
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
        raise PermissionError("dispute is only ever available on a self-dive")

    kept: list[dict] = []
    removed: dict | None = None
    for entry in digest.get(digest_key) or []:
        if not isinstance(entry, dict):
            continue
        if removed is None and matches(entry, target):
            removed = entry
            continue
        kept.append(entry)
    if removed is None:
        return None

    digest = dict(digest)
    digest[digest_key] = kept
    disputed = list(data.get(disputed_key) or [])
    disputed.append(audit(removed, target))
    ref.set({"digest": digest, disputed_key: disputed}, merge=True)
    return {"report_id": report_id, "digest": digest, disputed_key: disputed}


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
    def _matches(entry: dict, tid: str) -> bool:
        return (str(entry.get("id") or "") or fact_id(entry)) == tid

    def _audit(removed: dict, _target: str) -> dict:
        return {
            "claim": str(removed.get("claim", "")).strip(),
            "category": str(removed.get("category", "")).strip(),
            "disputed_at": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        }

    return _dispute_entry(
        db,
        uid,
        report_id,
        target_fact_id,
        digest_key="facts",
        disputed_key="disputed_facts",
        matches=_matches,
        audit=_audit,
    )


def dispute_link(db, uid: str, report_id: str, url: str) -> dict | None:
    """Mark one plain web link on a stored dive report as not the subject's
    (or otherwise wrong): remove it from the persisted `digest.links` and
    remember it in `disputed_links` on the same doc (audit trail, mirrors
    `disputed_social`/`disputed_photos` — same known gap: not currently read
    back into a future re-dive's prompt).

    Returns the updated `{report_id, digest, disputed_links}` on success,
    `None` when there's no such report or no matching link. Raises
    `PermissionError` for a report about someone other than the caller —
    self-dive only, same rule as `dispute_fact`."""
    def _audit(removed: dict, target: str) -> dict:
        return {
            "url": target,
            "title": str(removed.get("title", "")).strip(),
            "disputed_at": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        }

    return _dispute_entry(
        db,
        uid,
        report_id,
        url,
        digest_key="links",
        disputed_key="disputed_links",
        matches=_dispute_url_matches,
        audit=_audit,
    )


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
    def _audit(removed: dict, target: str) -> dict:
        return {
            "url": target,
            "platform": str(removed.get("platform", "")).strip(),
            "disputed_at": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        }

    return _dispute_entry(
        db,
        uid,
        report_id,
        url,
        digest_key="social_handles",
        disputed_key="disputed_social",
        matches=_dispute_url_matches,
        audit=_audit,
    )


def dispute_web_image(db, uid: str, report_id: str, url: str) -> dict | None:
    """Same as `dispute_social_link` but for one entry of `digest.web_images`
    (a "photos of you found online" thumbnail), tracked in `disputed_photos`.
    Self-dive only; same return/exception shape."""
    def _audit(removed: dict, target: str) -> dict:
        return {
            "url": target,
            "source_page": str(removed.get("source_page", "")).strip(),
            "disputed_at": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        }

    return _dispute_entry(
        db,
        uid,
        report_id,
        url,
        digest_key="web_images",
        disputed_key="disputed_photos",
        matches=_dispute_url_matches,
        audit=_audit,
    )


_MAX_CORRECTIONS = 30

# Digest list + audit-trail key for each URL-keyed correction target — the
# same lists :func:`dispute_link` / :func:`dispute_social_link` /
# :func:`dispute_web_image` remove from (see :func:`correct_finding`).
_URL_TARGET_LISTS = {
    "link": ("links", "disputed_links"),
    "social": ("social_handles", "disputed_social"),
    "photo": ("web_images", "disputed_photos"),
}


# --- provenance questions (#28) -------------------------------------------
# Founder retest Nov 2, 2026: "where did you get this information from?"
# about a summary item dodged ("I don't have a single specific link saved")
# while the keyword "source" ask returned the stored URL. Prompt-only routing
# proved fragile, so provenance turns are detected structurally and answered
# from the stored source deterministically — no model round-trip, repeat asks
# answer alike.

# A message that SUPPLIES a link, or that also corrects/rejects the finding,
# is not a pure provenance question — it must still reach Gemini (which sees
# the populated Source line and can do both).
_PROVENANCE_URL_RE = re.compile(r"https?://|www\.", re.IGNORECASE)
_PROVENANCE_CORRECTION_RE = re.compile(
    r"\b(wrong|incorrect|untrue|false|made up"
    r"|not (mine|me|my|true|right|correct|accurate)"
    r"|didn'?t|never|delete|remove|change|fix|update|correct)\b",
    re.IGNORECASE,
)

_PROVENANCE_PATTERNS = (
    # "where did you get/find this ... from", "where's this from"
    r"\bwhere\b.{0,25}\b(from|get|gets|got|find|finds|found|come|comes|came)\b",
    r"\bwheres?\b.{0,25}\bfrom\b",
    r"\bhow\b.{0,25}\bknow\b",  # "how do you know"
    r"\bbased on\b",  # "what's this based on"
    r"\bwho says\b",  # "who says that"
    r"\bprove it\b",
    r"\bwhat\b.{0,15}\blink\b",  # "what's the link"
    r"\bshow\b.{0,20}\blink\b",  # "show me the link"
    r"\bwhich\b.{0,20}\b(sites?|websites?|pages?|urls?|links?|sources?)\b",
    # "source" only with an asking trigger before it — "my income source is
    # Acme" (a correction) must not fire.
    r"\b(what|which|where|show|give|gave|share|see|saw|post|send|sent|quote"
    r"|have|has|had|got|gotten|please|links?)\b.{0,25}\bsources?\b",
    r"\bsources?\b.{0,6}([?]|$)",  # trailing "source?" / bare "source"
)
_PROVENANCE_RES = tuple(re.compile(p, re.IGNORECASE) for p in _PROVENANCE_PATTERNS)


def is_provenance_question(text: str) -> bool:
    """Whether ``text`` purely asks where a finding came from — any phrasing,
    not just the keyword "source". ``False`` for corrections (even mixed
    "that's wrong, where did you get it?"), link supplies, and chatter."""
    text = (text or "").strip()
    if not text:
        return False
    if _PROVENANCE_URL_RE.search(text) or _PROVENANCE_CORRECTION_RE.search(text):
        return False
    return any(r.search(text) for r in _PROVENANCE_RES)


_SUMMARY_SOURCE_STOPWORDS = frozenset({
    "the", "and", "for", "from", "with", "that", "this", "these", "those",
    "his", "her", "their", "its", "your", "you", "has", "have", "had", "was",
    "were", "are", "been", "also", "into", "over", "such", "more", "most",
    "very", "who", "what", "about",
})


def _content_tokens(text: str) -> set[str]:
    return {
        w for w in re.findall(r"[a-z0-9]+", (text or "").lower())
        if len(w) >= 3 and w not in _SUMMARY_SOURCE_STOPWORDS
    }


def _summary_source_url(digest: dict) -> str:
    """The stored URL behind a report summary: the ``source_url`` of the fact
    whose claim overlaps the summary text most (the summary is synthesised
    from the facts, so the top-overlap fact is the sentence's backing).
    ``""`` when no sourced fact overlaps — the honest-empty case."""
    summary_tokens = _content_tokens(str(digest.get("summary") or ""))
    if not summary_tokens:
        return ""
    best_url, best_score = "", 0
    for fact in digest.get("facts") or []:
        if not isinstance(fact, dict):
            continue
        url = str(fact.get("source_url") or "").strip()
        if not url:
            continue
        score = len(summary_tokens & _content_tokens(str(fact.get("claim") or "")))
        if score > best_score:
            best_url, best_score = url, score
    return best_url


def focused_item_source(db, uid: str, report_id: str, target: str) -> dict:
    """The stored source of one report item — ``{"url", "quote", "when"}``,
    or ``{}`` when the item has no stored source. ``target`` is a
    :func:`correct_finding` target (``"summary"`` resolves to its backing
    fact's URL). Best-effort: any read failure is ``{}``. Used by
    ``find_fact_source`` so a bare sheet ask ("where's this from") resolves
    deictically to the focused item."""
    report_id = (report_id or "").strip()
    target = (target or "").strip()
    if not db or not uid or not report_id or not target:
        return {}
    try:
        data = read_dive(db, uid, report_id)
    except Exception:  # noqa: BLE001 - a read failure is "no source"
        return {}
    if not data:
        return {}
    digest = data.get("digest") or {}
    when = iso_or_str(data.get("created_at"), none="")
    if target == "summary":
        url = _summary_source_url(digest)
        if not url:
            return {}
        return {
            "url": url,
            "quote": str(digest.get("summary") or "").strip()[:300],
            "when": when,
        }
    if target.startswith("fact:"):
        fid = target[len("fact:"):]
        for fact in digest.get("facts") or []:
            if not isinstance(fact, dict):
                continue
            if (str(fact.get("id") or "") or fact_id(fact)) != fid:
                continue
            url = str(fact.get("source_url") or "").strip()
            return {"url": url, "quote": str(fact.get("claim") or ""), "when": when} if url else {}
        return {}
    kind, _, url = target.partition(":")
    if kind in _URL_TARGET_LISTS and url.strip():
        digest_key = _URL_TARGET_LISTS[kind][0]
        for entry in digest.get(digest_key) or []:
            if isinstance(entry, dict) and str(entry.get("url") or "").strip() == url.strip():
                return {"url": url.strip(), "quote": url.strip(), "when": when}
    return {}


async def correct_finding(
    db, uid: str, report_id: str, *, target: str, feedback: str
) -> dict | None:
    """One turn of free-text feedback on a single "about me" web-search
    finding — the same tap-a-claim-and-tell-Ayma-in-plain-language pattern as
    the Story editor's passage chat (``story.edit_section``), applied to a
    deep-dive report instead of a wiki section.

    ``target`` is ``"summary"``, ``"fact:<fact_id>"``, or one of
    ``"link:<url>"`` / ``"social:<url>"`` / ``"photo:<url>"``. Gemini reads
    the targeted claim (or the summary, or the link/photo's label + URL) plus
    the user's feedback and decides ``remove`` / ``revise`` / ``caveat`` /
    ``keep`` — a bare link or photo has no wording to revise, so only
    ``remove`` mutates there (anything else is audit-only, normalised to
    ``keep``); the change is applied to the persisted digest immediately, so
    it survives a reload and isn't lost to the next research re-run
    (:func:`store_dive` carries ``corrections`` and any resulting
    ``disputed_*`` entry forward). Every turn — whatever
    Gemini decides — is appended to ``corrections`` as a short audit trail,
    capped at :data:`_MAX_CORRECTIONS` (oldest dropped first).

    One turn type never reaches Gemini: a pure provenance question
    (:func:`is_provenance_question` — any phrasing, not just "source") about
    an item WITH a stored source is answered from that source directly
    (``keep``, deterministic — #28). An item with no stored source still goes
    through Gemini, which answers honestly from ``Source: (none)``.

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
    url_kind = ""
    url = ""
    url_entry: dict | None = None
    if target == "summary":
        claim_text = str(digest.get("summary", "")).strip()
        # The summary is synthesised from the facts — its Source is the
        # backing fact's URL, not "(none)" (#28: every summary turn used to
        # send "(none)" even when backing URLs existed).
        source_url = _summary_source_url(digest)
    elif target.startswith("fact:"):
        fid = target[len("fact:"):]
        for f in digest.get("facts") or []:
            if isinstance(f, dict) and (str(f.get("id") or "") or fact_id(f)) == fid:
                claim_text = str(f.get("claim", "")).strip()
                source_url = str(f.get("source_url", "")).strip()
                break
        else:
            return None
    elif target.startswith(("link:", "social:", "photo:")):
        url_kind, _, url = target.partition(":")
        url = url.strip()
        digest_key = _URL_TARGET_LISTS[url_kind][0]
        for entry in digest.get(digest_key) or []:
            if isinstance(entry, dict) and str(entry.get("url") or "").strip() == url:
                url_entry = entry
                break
        else:
            return None
        if url_kind == "link":
            claim_text = str(url_entry.get("title") or "").strip()
        elif url_kind == "social":
            handle = str(url_entry.get("handle") or "").strip()
            platform = str(url_entry.get("platform") or "").strip()
            claim_text = (
                f"{platform} @{handle}".strip()
                if handle
                else str(url_entry.get("display_name") or platform).strip()
            )
        else:
            claim_text = str(
                url_entry.get("source_page") or url_entry.get("caption") or ""
            ).strip()
        source_url = url
    else:
        return None

    if source_url and is_provenance_question(feedback):
        # #28: the stored source, quoted directly — no model round-trip, so
        # every phrasing and every re-ask answers alike. (No source, or a
        # correction mixed in, falls through to Gemini below.)
        action = "keep"
        reply = f"I found that here: {source_url}"
        note = ""
        revised_claim = ""
    else:
        result = await gemini.generate_json(
            f"Targeted item: {claim_text or '(empty)'}\n"
            f"Source: {source_url or '(none)'}\n"
            f"User's feedback: {feedback}",
            system_prompt=(
                _CORRECTION_SYSTEM_URL if url_entry is not None else _CORRECTION_SYSTEM
            ),
            response_schema=_CORRECTION_SCHEMA,
            uid=uid,
            feature=FEATURE_DEEPDIVE,
        )
        result = result if isinstance(result, dict) else {}
        action = str(result.get("action") or "keep").strip().lower()
        if action not in ("remove", "revise", "caveat", "keep"):
            action = "keep"
        if url_entry is not None and action in ("revise", "caveat"):
            # A bare link or photo has no wording to revise — audit-only.
            action = "keep"
        reply = (
            str(result.get("reply") or "").strip()
            or "Got it — thanks for the correction."
        )
        note = str(result.get("note") or "").strip()
        revised_claim = str(result.get("revised_claim") or "").strip()

    digest = dict(digest)
    disputed = list(data.get("disputed_facts") or [])
    extra_audits: dict[str, list] = {}
    if target == "summary":
        if action == "revise" and revised_claim:
            digest["summary"] = revised_claim
        elif action == "caveat" and note:
            digest["caveats"] = f"{digest.get('caveats', '')} {note}".strip()
        # "remove" has no sensible meaning for the whole summary — nothing to
        # drop, so it falls through and only the audit trail records it.
    elif url_entry is not None:
        # Only `remove` mutates a bare link/photo (anything else was
        # normalised to `keep` above) — same removal + audit shape as the
        # `dispute_*` wrappers, applied to this already-loaded digest.
        if action == "remove":
            digest_key, audit_key = _URL_TARGET_LISTS[url_kind]
            kept: list = []
            for e in digest.get(digest_key) or []:
                if isinstance(e, dict) and str(e.get("url") or "").strip() == url:
                    continue
                kept.append(e)
            digest[digest_key] = kept
            audit: dict = {"url": url}
            if url_kind == "link":
                audit["title"] = str(url_entry.get("title", "")).strip()
            elif url_kind == "social":
                audit["platform"] = str(url_entry.get("platform", "")).strip()
            else:
                audit["source_page"] = str(url_entry.get("source_page", "")).strip()
            audit["disputed_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%d")
            entries = list(data.get(audit_key) or [])
            entries.append(audit)
            extra_audits[audit_key] = entries
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
    payload.update(extra_audits)
    ref.set(payload, merge=True)
    return {"report_id": report_id, "digest": digest, "reply": reply, "action": action}



_RESEARCH_SYSTEM = load_prompt_sections(_PROMPTS_PATH)["research_system"]

_DIGEST_SYSTEM = load_prompt_sections(_PROMPTS_PATH)["digest_system"]

_CORRECTION_SYSTEM = load_prompt_sections(_PROMPTS_PATH)["correction_system"]

_CORRECTION_SYSTEM_URL = load_prompt_sections(_PROMPTS_PATH)["correction_system_url"]

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
                    "source_index": {
                        "type": "integer",
                        "description": "0-based index into the numbered "
                        "SOURCE LINKS SEEN list, when source_url is one of "
                        "those entries (almost always) — set this instead of "
                        "trusting yourself to retype the URL exactly. Omit "
                        "only when source_url came from somewhere else in "
                        "the notes.",
                    },
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
                    "source_index": {
                        "type": "integer",
                        "description": "0-based index into the numbered "
                        "SOURCE LINKS SEEN list, when url is one of those "
                        "entries (almost always) — set this instead of "
                        "trusting yourself to retype the URL exactly. Omit "
                        "only when url came from somewhere else in the "
                        "notes.",
                    },
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

# The deep dive runs as a polled BACKGROUND job (the client POSTs /deep-dive
# then polls /deep-dive/mine), so it is NOT bound by the client's long-request
# budget — a longer grounded-research timeout plus one retry is safe here and
# never leaves the user staring at a bare failure (founder directive: the
# backend auto-retries, the user never has to re-tap). Bounded: 2 attempts
# total, short backoff, worst case ≈ 2 × the per-attempt research timeout. We
# stay on the chosen Brain — NO model fallback / fallback_to_google (that flag
# flip is the founder's call, not this reliability change).
_RESEARCH_ATTEMPTS = 2
_RESEARCH_RETRY_BACKOFF_SECONDS = 2.0


def _research_error_retryable(exc: Exception) -> bool:
    """A grounded-research failure worth one more attempt: an inference
    timeout or a transient server-side error (5xx, plus 408/429), or a
    transport error with no HTTP status. A deterministic bad request (a 4xx
    other than those) would just fail again, so it is NOT retried. A credit
    cap is terminal for this job, so it is NOT retried either."""
    if isinstance(exc, token_ledger.TokenCapExceeded):
        return False
    if isinstance(exc, asyncio.TimeoutError):
        return True
    code = getattr(exc, "code", None)
    if code is None:
        code = getattr(exc, "status_code", None)
    try:
        code = int(code)
    except (TypeError, ValueError):
        # No HTTP status (e.g. a connection/transport error): treat as transient.
        return True
    if code in (408, 429):
        return True
    return code >= 500


async def _grounded_research(ask: str, *, uid: str | None) -> tuple[str, list]:
    """Run the dive's grounded web-research call, retrying ONCE on an inference
    TimeoutError (or a transient 5xx) — never on a deterministic bad request.

    No double-charge: :func:`gemini.research` records the spend only after the
    call returns, so a timed-out attempt (which raises before ``record``) bills
    nothing; only the succeeding attempt is metered, exactly once."""
    for attempt in range(_RESEARCH_ATTEMPTS):
        try:
            return await gemini.research(
                ask,
                system_prompt=_RESEARCH_SYSTEM,
                uid=uid,
                feature=FEATURE_DEEPDIVE,
                max_output_tokens=6000,
                timeout=gemini.RESEARCH_TIMEOUT_SECONDS,
            )
        except Exception as exc:  # noqa: BLE001 - classified by _research_error_retryable
            last = attempt + 1 >= _RESEARCH_ATTEMPTS
            if not _research_error_retryable(exc) or last:
                raise
            logger.warning(
                "deep-dive research failed (%s: %s) on attempt %d/%d — retrying",
                type(exc).__name__, exc, attempt + 1, _RESEARCH_ATTEMPTS,
            )
            await asyncio.sleep(_RESEARCH_RETRY_BACKOFF_SECONDS * (attempt + 1))
    raise RuntimeError("unreachable: research retry loop exhausted")  # pragma: no cover


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
    prose, sources = await _grounded_research(ask, uid=uid)

    validate_links = feature_flags.enabled("deepdive_validate_links")
    if validate_links:
        # Grounding hands back opaque Google redirects; swap in the real page
        # so the digest pass cites (and we validate) actual URLs.
        sources = await asyncio.to_thread(deep_dive_links.resolve_sources, sources)
        sources = [s for s in sources if s.get("url")]
    grounded_urls = {s["url"] for s in sources}

    # Numbered so the digest pass can point back at a source by index instead
    # of retyping its URL — see the `source_index` handling below.
    src_lines = "\n".join(
        f"{i}. {s['url']}  ({s.get('title', '')})" for i, s in enumerate(sources)
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

    def _source_url(d: dict, key: str) -> str:
        # The digest pass free-types `key` (source_url / url) by retyping it
        # from the numbered SOURCE LINKS SEEN list it was shown — a model
        # regenerating a long URL from memory can misremember a character or
        # even copy a *different* list entry's URL onto the right-looking
        # title (this is the "title is right, link goes to the wrong site"
        # bug). When the model also gave a `source_index` into that same
        # numbered list, trust the index over the retyped string — it can
        # only select a URL that was actually seen, never invent or scramble
        # one. Fall back to the free-typed string only when no valid index
        # was given (e.g. a URL from outside the grounding list, such as the
        # user's own supplied LinkedIn URL).
        idx = d.get("source_index")
        if isinstance(idx, bool):
            idx = None  # bool is an int subclass; never a real index
        if isinstance(idx, int) and 0 <= idx < len(sources):
            return sources[idx]["url"]
        return _real_url(d.get(key, ""))

    facts = []
    for f in (digest.get("facts") or []):
        if not isinstance(f, dict):
            continue
        f = dict(f)
        f["source_url"] = _source_url(f, "source_url")
        f.pop("source_index", None)
        # A stable id per fact — array position shifts once a dispute (§ Part
        # 2) starts removing entries, so the client needs something durable.
        f["id"] = fact_id(f)
        facts.append(f)
    links = []
    for ln in (digest.get("links") or []):
        if not isinstance(ln, dict):
            continue
        ln = dict(ln)
        ln["url"] = _source_url(ln, "url")
        ln.pop("source_index", None)
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
    image_stats: dict = {}
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
                db, img_target, name, extra_terms=loc, links=links, uid=uid,
                location=loc, stats=image_stats,
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

    links, social_handles = deep_dive_links.clean_links_and_socials(
        links, social_handles
    )
    link_stamp = {}
    if validate_links:
        links, social_handles, web_images, facts = await asyncio.to_thread(
            deep_dive_links.validate_report_urls,
            links, social_handles, web_images, facts, grounded_urls,
        )
        link_stamp = {"links_validated_at": datetime.now(timezone.utc).isoformat()}

    result = {
        **link_stamp,
        "name": name,
        "is_self": is_self,
        "summary": str(digest.get("summary", "")).strip(),
        "confidence": str(digest.get("confidence", "not_found")),
        "facts": facts,
        "links": links,
        "web_images": web_images,
        "web_image_stats": image_stats,
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
    links, clean_socials = deep_dive_links.clean_links_and_socials(
        digest.get("links"), digest.get("social_handles")
    )
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
    socials = clean_socials
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
