"""Per-user skill-run ledger + reconcile job (§ skill runs).

Ayma runs two "about the user" profile-building skills — a consented web
``deep_dive`` on the user, and one ``appearance`` read of their photos that
folds together the structured ``physical_attributes`` record and the honest
face / physique analyses. Each one promotes its findings into the user's
private wiki. This module tracks *when* each skill last ran for a user and runs
any that never have, so every user's wiki ends up fully populated.

The former ``face_report`` / ``body_report`` / ``physical_attributes`` skills
are still accepted by :func:`record` for back-compat (the per-upload silent
``physical_attributes.refresh`` still stamps its own ledger doc, and Ayma may
still invoke a "face report" by name), but the reconciler only ever runs
``deep_dive`` and ``appearance`` — a legacy ``face_reports`` /
``body_reports`` / ``physical_attributes/current`` artifact counts as
satisfying ``appearance`` for a pre-migration user.

Ledger: one doc per skill at ``users/{uid}/skill_runs/{skill}`` ::

    {last_run_at, last_status: "ok"|"skipped"|"error",
     source: "user"|"auto", detail: str}

Everything here is best-effort: :func:`record` never raises, and
:func:`reconcile` / :func:`sweep` wrap each skill so one failure never aborts
the batch.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta, timezone

import token_ledger

logger = logging.getLogger("ayma.skillruns")

DEEP_DIVE = "deep_dive"
APPEARANCE = "appearance"
# Retired as standalone reconcile targets — kept so :func:`record` and callers
# that still name them (the silent per-upload physical-attrs refresh, an
# Ayma-invoked "face report") keep working.
FACE_REPORT = "face_report"
BODY_REPORT = "body_report"
PHYSICAL_ATTRIBUTES = "physical_attributes"

# Every skill the reconciler tracks / runs.
ALL: tuple[str, ...] = (DEEP_DIVE, APPEARANCE)

# Every skill name :func:`record` will store a ledger doc for.
_RECORDABLE: frozenset[str] = frozenset(
    ALL + (FACE_REPORT, BODY_REPORT, PHYSICAL_ATTRIBUTES)
)

# Lighter-touch first — :func:`reconcile` works this order and the per-session
# nudge only takes the first (``user_limit=1``), so an active user's profile
# fills in without a latency / credit spike. ``appearance`` is up to three
# vision passes, so it goes last.
_RECONCILE_ORDER: tuple[str, ...] = (DEEP_DIVE, APPEARANCE)

STATUS_OK = "ok"
STATUS_SKIPPED = "skipped"
STATUS_ERROR = "error"

# A run older than this is "stale" — tracked for later, never acted on here.
_STALE_DAYS = 90

_DETAIL_CAP = 500


def _col(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("skill_runs")
    )


# --- ledger ----------------------------------------------------------------


def record(
    db,
    uid: str,
    skill: str,
    *,
    status: str,
    source: str,
    detail: str = "",
) -> None:
    """Upsert ``users/{uid}/skill_runs/{skill}`` with ``last_run_at`` set to the
    server clock. Best-effort — never raises."""
    if not db or not uid or skill not in _RECORDABLE:
        return
    try:
        from firebase_admin import firestore

        _col(db, uid).document(skill).set(
            {
                "skill": skill,
                "last_run_at": firestore.SERVER_TIMESTAMP,
                "last_status": status,
                "source": source,
                "detail": (detail or "")[:_DETAIL_CAP],
            },
            merge=True,
        )
    except Exception:  # noqa: BLE001 - the ledger is best-effort, never fail a skill
        logger.exception("skill_runs.record failed for %s/%s", uid, skill)


def get_all(db, uid: str) -> dict[str, dict]:
    """``{skill: {last_run_at, last_status, source, detail}}`` for every skill
    that has a ledger doc. Best-effort — a read failure returns ``{}``."""
    out: dict[str, dict] = {}
    if not db or not uid:
        return out
    try:
        for snap in _col(db, uid).stream():
            out[snap.id] = snap.to_dict() or {}
    except Exception:  # noqa: BLE001
        logger.exception("skill_runs.get_all failed for %s", uid)
    return out


def _doc_exists(db, uid: str, collection: str, doc_id: str) -> bool:
    try:
        snap = (
            db.collection("users")
            .document(uid)
            .collection(collection)
            .document(doc_id)
            .get()
        )
        return bool(getattr(snap, "exists", False))
    except Exception:  # noqa: BLE001
        return False


def _has_any(db, uid: str, collection: str) -> bool:
    """Whether ``users/{uid}/{collection}`` holds at least one doc."""
    try:
        coll = db.collection("users").document(uid).collection(collection)
        try:
            coll = coll.limit(1)
        except Exception:  # noqa: BLE001 - a fake / older client without .limit
            pass
        return any(True for _ in coll.stream())
    except Exception:  # noqa: BLE001
        return False


def _artifact_seen(db, uid: str, skill: str) -> bool:
    """Whether the skill left its own artifact behind on a prior run. Lets
    :func:`missing` skip a skill that predates this ledger so we don't re-run
    it. For ``appearance`` a *legacy* ``face_reports`` / ``body_reports`` /
    ``physical_attributes/current`` artifact also counts — a pre-migration user
    has already had their photos read."""
    if skill == DEEP_DIVE:
        return _has_any(db, uid, "deep_dives")
    if skill == APPEARANCE:
        return (
            _doc_exists(db, uid, "appearance", "current")
            or _has_any(db, uid, "appearance_reports")
            or _has_any(db, uid, "face_reports")
            or _has_any(db, uid, "body_reports")
            or _doc_exists(db, uid, "physical_attributes", "current")
        )
    return False


def missing(db, uid: str, skills: tuple[str, ...] = ALL) -> list[str]:
    """The skills in ``skills`` that have never run for ``uid`` — no
    ``skill_runs`` doc **and** no artifact from a pre-ledger run. Order follows
    ``skills``. A stale-but-present run still counts as present (see
    :func:`stale`)."""
    ledger = get_all(db, uid)
    out: list[str] = []
    for skill in skills:
        if skill not in ALL or skill in ledger:
            continue
        if _artifact_seen(db, uid, skill):
            continue
        out.append(skill)
    return out


def _as_dt(ts) -> datetime | None:
    if isinstance(ts, datetime):
        return ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)
    for attr in ("timestamp",):
        fn = getattr(ts, attr, None)
        if callable(fn):
            try:
                return datetime.fromtimestamp(fn(), tz=timezone.utc)
            except Exception:  # noqa: BLE001
                return None
    return None


def stale(db, uid: str, max_age_days: int = _STALE_DAYS) -> list[str]:
    """Skills whose last recorded run is older than ``max_age_days``. Not acted
    on today — :func:`missing` / :func:`reconcile` ignore staleness — but kept
    here for a later "refresh" pass."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=max_age_days)
    out: list[str] = []
    for skill, rec in get_all(db, uid).items():
        dt = _as_dt(rec.get("last_run_at"))
        if dt is not None and dt < cutoff:
            out.append(skill)
    return out


# --- reconcile: run the missing ones -------------------------------------------


async def _run_one(db, uid: str, skill: str) -> tuple[str, str]:
    """Invoke one missing skill headlessly. Returns ``(status, detail)``;
    raises :class:`token_ledger.TokenCapExceeded` or any engine error for the
    caller to record."""
    if skill == APPEARANCE:
        import appearance
        import photo_attrs

        cov = photo_attrs.coverage(db, uid)
        doc = await appearance.run_appearance(
            db, uid,
            want_face=bool(cov.get("has_face_photo")),
            want_body=bool(cov.get("has_body_photo")),
            source="auto",
        )
        if doc is None:
            return STATUS_SKIPPED, "no_photo"
        return STATUS_OK, "auto"

    if skill == DEEP_DIVE:
        import deep_dive
        import skill_memory

        name = deep_dive.profile_full_name(db, uid)
        if not name:
            return STATUS_SKIPPED, "no_name"
        digest = await deep_dive.run(
            name,
            db=db,
            uid=uid,
            context=deep_dive.profile_dive_context(db, uid, name),
            is_self=True,
        )
        skill_memory.save_web_findings(db, uid, digest)
        skill_memory.promote(db, uid, "web_findings")
        return STATUS_OK, "auto"

    return STATUS_SKIPPED, "unknown_skill"


async def reconcile(db, uid: str, *, user_limit: int | None = None) -> dict:
    """Run every profile-building skill that has never run for ``uid`` and
    record each outcome (``source="auto"``). ``user_limit`` caps how many
    missing skills are attempted this call, cheapest first — the per-session
    nudge passes ``user_limit=1``; ``None`` attempts them all.

    Each skill is wrapped: a credit-cap hit records ``skipped/capped`` and any
    other error records ``error`` — the batch is never aborted. Never raises.
    Returns ``{"uid", "ran": {skill: detail}, "skipped": {skill: reason},
    "errors": n}``.
    """
    result: dict = {"uid": uid, "ran": {}, "skipped": {}, "errors": 0}
    if not db or not uid:
        return result

    try:
        want = missing(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception("skill_runs.reconcile: missing() failed for %s", uid)
        return result
    ordered = [s for s in _RECONCILE_ORDER if s in want]
    if user_limit is not None:
        ordered = ordered[: max(0, int(user_limit))]
    if not ordered:
        return result

    try:
        await asyncio.to_thread(token_ledger.check, uid)
    except token_ledger.TokenCapExceeded:
        for skill in ordered:
            record(
                db, uid, skill,
                status=STATUS_SKIPPED, source="auto", detail="capped",
            )
            result["skipped"][skill] = "capped"
        return result
    except Exception:  # noqa: BLE001 - a ledger read failure shouldn't stop us
        logger.exception("skill_runs.reconcile: credit check failed for %s", uid)

    for skill in ordered:
        try:
            status, detail = await _run_one(db, uid, skill)
        except token_ledger.TokenCapExceeded:
            record(
                db, uid, skill,
                status=STATUS_SKIPPED, source="auto", detail="capped",
            )
            result["skipped"][skill] = "capped"
            continue
        except Exception as exc:  # noqa: BLE001 - never abort the batch
            logger.exception(
                "skill_runs.reconcile: %s failed for %s", skill, uid
            )
            record(
                db, uid, skill,
                status=STATUS_ERROR, source="auto", detail=str(exc)[:_DETAIL_CAP],
            )
            result["errors"] += 1
            continue
        record(db, uid, skill, status=status, source="auto", detail=detail)
        if status == STATUS_OK:
            result["ran"][skill] = detail or "ok"
        else:
            result["skipped"][skill] = detail or status
    return result


async def sweep(db, user_limit: int = 200) -> dict:
    """Reconcile every user's missing profile-building skills. Scans up to
    ``user_limit`` users (mirrors ``physical_attributes.backfill_missing``).
    Returns ``{"users", "ran": {skill: n}, "skipped": {skill: n}, "errors": n}``.
    """
    out: dict = {"users": 0, "ran": {}, "skipped": {}, "errors": 0}
    try:
        users = list(db.collection("users").stream())
    except Exception:  # noqa: BLE001
        logger.exception("skill_runs.sweep: user scan failed")
        return out

    for snap in users:
        if out["users"] >= user_limit:
            break
        uid = snap.id
        out["users"] += 1
        try:
            r = await reconcile(db, uid)
        except Exception:  # noqa: BLE001
            logger.exception("skill_runs.sweep: reconcile failed for %s", uid)
            out["errors"] += 1
            continue
        for skill in r.get("ran", {}):
            out["ran"][skill] = out["ran"].get(skill, 0) + 1
        for skill in r.get("skipped", {}):
            out["skipped"][skill] = out["skipped"].get(skill, 0) + 1
        out["errors"] += int(r.get("errors", 0))
    return out
