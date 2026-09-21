"""Reverse-image search for "other pictures of me" (§ web photo search).

The existing deep-dive (``deep_dive.py``) finds photos of a person by
searching the web for their *name* and face-embedding-verifying whatever
comes back (``deep_dive_images.py``) — fully automatic, no user confirmation,
because a name+face match is already a strong identity signal.

This module answers a different question: given the user's own photo, where
else on the open web does that image (or an edit/crop/derivative of it) show
up, and what does Google's index consider visually similar to it? That's
Google Cloud Vision's **Web Detection** API — an image-similarity search, not
a face-identity match. It can misidentify: a "visually similar" hit can
easily be a different person entirely (same pose, same lighting, a shared
background), and even a "matching image" hit is only proof the *pixels*
appear elsewhere, not that the page is about this person.

Because of that materially higher misidentification risk (founder decision,
§ web search about me), nothing found here is ever written into the
persistent "about me" report automatically. Every result is staged as a
**candidate** — ``users/{uid}/web_photo_candidates/{candidate_id}`` — that the
user must explicitly confirm (:func:`confirm_candidate`) before it becomes
part of the record, or reject (:func:`reject_candidate`) to dismiss it.
Confirming merges ``{image_url, source_url, source_title, confirmed_at}``
into the self-dive digest's ``confirmed_photos`` list
(``deep_dive.py``'s ``store_dive`` carries that list forward across future
research re-runs).

Two triggers call :func:`scan`:

* once, automatically, right after onboarding completes
  (:func:`auto_scan`, called from ``POST /onboarding/complete`` and, as a
  fallback, from ``POST /bootstrap`` — same one-time-flag pattern as
  ``auto_analysis.analyse_web``'s ``auto_dive_done``);
* again whenever the user's photo set changes — a later photo batch should
  re-run this against the new photo(s), not just once at onboarding (founder
  decision). **Placeholder hook**: the appearance-report agent (parallel
  work, same session) owns the actual "a photo batch just finished
  processing" detection/trigger — this module doesn't know when that is. Until
  that lands, ``POST /web-search/photos/rescan`` is the callable hook: whoever
  ends up owning the real batch-completion signal should call that endpoint
  (or straight up ``reverse_image_search.scan(db, uid, storage_paths=[...])``
  server-side) once a batch settles, passing the newly added photo(s).

Best-effort throughout: any failure is logged, never raised. No-ops quietly
— logs one warning — when the Cloud Vision API isn't reachable (dependency
not installed, or the API not enabled on the GCP project; see the module's
``requirements.txt`` entry and ``docs/deploy.md``).
"""

from __future__ import annotations

import hashlib
import logging
import urllib.parse
from datetime import datetime, timezone

logger = logging.getLogger("ayma.reverseimagesearch")

_CANDIDATES_COL = "web_photo_candidates"
_SCAN_DONE_FIELD = "web_photo_scan_done"
_SCAN_AT_FIELD = "web_photo_scan_at"

STATUS_PENDING = "pending"
STATUS_CONFIRMED = "confirmed"
STATUS_REJECTED = "rejected"

# Cloud Vision's web detection can come back with dozens of near-duplicates
# of a popular/well-indexed photo — cap what gets staged per scan so the
# confirmation UI stays a short, reviewable list, not a wall.
_MAX_CANDIDATES_PER_SCAN = 12


def _candidates_col(db, uid: str):
    return db.collection("users").document(uid).collection(_CANDIDATES_COL)


def _candidate_id(image_url: str) -> str:
    """Stable id per image URL, so re-scanning never duplicates a candidate
    already staged (pending, confirmed, or rejected) — a decision the user
    already made (or hasn't gotten to) sticks across scans."""
    return hashlib.sha1(image_url.strip().encode("utf-8")).hexdigest()[:20]


def _domain(url: str) -> str:
    try:
        return urllib.parse.urlparse(url).netloc
    except Exception:  # noqa: BLE001
        return ""


def _vision_client():
    """Lazy import so the module (and every caller that merely imports it)
    works fine without ``google-cloud-vision`` installed — :func:`scan` is the
    only thing that needs it, and it fails closed (empty candidates, one log
    line) rather than blocking import of this module or anything upstream of
    it, exactly like ``deep_dive_images``'s no-key fallback for the
    Programmable Search key."""
    from google.cloud import vision  # type: ignore[import-not-found]

    return vision.ImageAnnotatorClient()


def _web_detect(image_bytes: bytes):
    """Raw Cloud Vision Web Detection call. Raises on any failure — the only
    caller, :func:`scan`, treats that as "no candidates this run"."""
    from google.cloud import vision  # type: ignore[import-not-found]

    client = _vision_client()
    image = vision.Image(content=image_bytes)
    response = client.web_detection(image=image)
    if response.error and response.error.message:
        raise RuntimeError(f"Vision web_detection error: {response.error.message}")
    return response.web_detection


def _candidates_from_detection(detection) -> list[dict]:
    """``[{image_url, match_type, source_url, source_title}]`` from a Vision
    ``WebDetection`` result (or any object exposing the same attributes —
    tests use a plain ``types.SimpleNamespace`` double instead of the real
    protobuf type, so this reads everything defensively with ``getattr``).

    Two categories, both gated behind user confirmation the same way (see
    module docstring):

    * "full" / "partial" matching images — Vision found this exact image (or
      a crop/edit of it) elsewhere. Cross-referenced against
      ``pages_with_matching_images`` to attach the page it was found on.
    * "similar" — Vision's broader "visually similar" bucket. Lower
      confidence, most likely to include a different photo of the same
      person, but also most likely to include someone else entirely — hence
      never auto-merged, same as the other two.
    """
    if detection is None:
        return []

    # url -> (source_url, source_title), built from each page's own nested
    # matching-image lists so a candidate's source attribution is exact, not
    # a guess.
    page_for_url: dict[str, tuple[str, str]] = {}
    for page in getattr(detection, "pages_with_matching_images", None) or []:
        page_url = str(getattr(page, "url", "") or "").strip()
        page_title = str(getattr(page, "page_title", "") or "").strip()
        if not page_url:
            continue
        for img in list(getattr(page, "full_matching_images", None) or []) + list(
            getattr(page, "partial_matching_images", None) or []
        ):
            u = str(getattr(img, "url", "") or "").strip()
            if u and u not in page_for_url:
                page_for_url[u] = (page_url, page_title)

    def _entries(attr: str, match_type: str) -> list[dict]:
        out = []
        for img in getattr(detection, attr, None) or []:
            u = str(getattr(img, "url", "") or "").strip()
            if not u:
                continue
            source_url, source_title = page_for_url.get(u, ("", ""))
            out.append(
                {
                    "image_url": u,
                    "match_type": match_type,
                    "source_url": source_url,
                    "source_title": source_title,
                }
            )
        return out

    candidates = (
        _entries("full_matching_images", "full")
        + _entries("partial_matching_images", "partial")
        + _entries("visually_similar_images", "similar")
    )

    seen: set[str] = set()
    deduped: list[dict] = []
    for c in candidates:
        if c["image_url"] in seen:
            continue
        seen.add(c["image_url"])
        deduped.append(c)
    return deduped[:_MAX_CANDIDATES_PER_SCAN]


async def scan(
    db, uid: str, *, storage_paths: list[str] | None = None
) -> list[dict]:
    """Run reverse-image search over one or more of the user's own photos and
    stage any new-to-us results as pending candidates. Returns the newly
    created candidate dicts (each ``{candidate_id, image_url, match_type,
    source_url, source_title}``) — an empty list on any failure, or when
    every result Vision returned was already staged from an earlier scan.

    ``storage_paths`` defaults to just the user's current primary profile
    photo (the one-time onboarding scan, :func:`auto_scan`). Pass the
    specific photo(s) from a newly added batch to re-run this against just
    what's new (§ the module docstring's batch-hook note).

    Never raises — Cloud Vision being unreachable, unconfigured, or erroring
    on one photo never blocks the others or fails the caller.
    """
    if not db or not uid:
        return []
    if not storage_paths:
        import skill_reports

        path = skill_reports.primary_profile_photo_path(db, uid)
        storage_paths = [path] if path else []
    if not storage_paths:
        return []

    import media_embed

    created: list[dict] = []
    for path in storage_paths:
        if not path:
            continue
        try:
            image_bytes, _mime = media_embed.download_bytes(path)
        except Exception:  # noqa: BLE001 - an unreadable photo is not fatal
            logger.exception("web-photo-search: unreadable photo %s", path)
            continue
        if not image_bytes:
            continue
        try:
            detection = _web_detect(image_bytes)
        except ModuleNotFoundError:
            logger.warning(
                "web-photo-search: google-cloud-vision is not installed — "
                "add it to requirements.txt and redeploy"
            )
            return created
        except Exception:  # noqa: BLE001
            logger.exception("web-photo-search: web_detection failed for %s", path)
            continue

        for c in _candidates_from_detection(detection):
            cid = _candidate_id(c["image_url"])
            ref = _candidates_col(db, uid).document(cid)
            try:
                if getattr(ref.get(), "exists", False):
                    continue  # already staged (or already decided) — skip
                from firebase_admin import firestore

                doc = {
                    "candidate_id": cid,
                    "image_url": c["image_url"],
                    "match_type": c["match_type"],
                    "source_url": c["source_url"],
                    "source_title": c["source_title"],
                    "source_domain": _domain(c["source_url"] or c["image_url"]),
                    "status": STATUS_PENDING,
                    "found_from": path,
                    "created_at": firestore.SERVER_TIMESTAMP,
                }
                ref.set(doc)
                created.append({**doc, "created_at": None})
            except Exception:  # noqa: BLE001
                logger.exception(
                    "web-photo-search: candidate write failed for %s/%s",
                    uid, cid,
                )
    return created


async def auto_scan(db, uid: str) -> None:
    """Once per user: run :func:`scan` against the primary profile photo and
    set the one-time flag, mirroring ``auto_analysis.analyse_web``'s
    ``auto_dive_done`` pattern exactly. Called from the onboarding-completion
    endpoint and, as a fallback, from ``/bootstrap``.

    Leaves the flag unset (so a later caller retries) when there's no primary
    photo yet. Never raises."""
    if not uid:
        return
    try:
        snap = db.collection("users").document(uid).get()
        if getattr(snap, "exists", False) and (snap.to_dict() or {}).get(
            _SCAN_DONE_FIELD
        ):
            return
    except Exception:  # noqa: BLE001
        logger.exception("web-photo-search: scan-flag read failed for %s", uid)
        return

    import skill_reports

    if not skill_reports.primary_profile_photo_path(db, uid):
        return  # no photo yet — leave the flag unset, retry later

    try:
        await scan(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception("web-photo-search: auto scan failed for %s", uid)

    try:
        from firebase_admin import firestore

        db.collection("users").document(uid).set(
            {_SCAN_DONE_FIELD: True, _SCAN_AT_FIELD: firestore.SERVER_TIMESTAMP},
            merge=True,
        )
    except Exception:  # noqa: BLE001
        logger.exception("web-photo-search: scan-flag write failed for %s", uid)


def list_candidates(db, uid: str, *, include_decided: bool = False) -> list[dict]:
    """The user's staged candidates, newest first — pending only by default;
    ``include_decided=True`` also returns already confirmed/rejected ones
    (e.g. for a "recently confirmed" section). Best-effort — ``[]`` on any
    read failure."""
    out: list[dict] = []
    try:
        for snap in _candidates_col(db, uid).stream():
            data = snap.to_dict() or {}
            if not include_decided and data.get("status") != STATUS_PENDING:
                continue
            data.setdefault("candidate_id", snap.id)
            created = data.get("created_at")
            data["created_at"] = (
                created.isoformat() if hasattr(created, "isoformat") else None
            )
            out.append(data)
    except Exception:  # noqa: BLE001
        logger.exception("web-photo-search: list_candidates failed for %s", uid)
        return []
    out.sort(key=lambda d: d.get("created_at") or "", reverse=True)
    return out


def _merge_confirmed_photo(db, uid: str, candidate: dict) -> None:
    """Append one confirmed candidate into the self-dive digest's
    ``confirmed_photos`` (:func:`deep_dive.merge_confirmed_photo`) — the
    persistent "about me" report. No-ops quietly if the caller has no
    self-dive report yet; the confirmation itself is never lost (it's still
    recorded on the candidate doc), so the next self-dive research run picks
    it up once a report exists."""
    import deep_dive

    name = deep_dive.profile_full_name(db, uid)
    if not name:
        return
    report_id = deep_dive.dive_report_id(name=name)
    photo = {
        "candidate_id": candidate.get("candidate_id", ""),
        "image_url": candidate.get("image_url", ""),
        "source_url": candidate.get("source_url", ""),
        "source_title": candidate.get("source_title", ""),
        "confirmed_at": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
    }
    deep_dive.merge_confirmed_photo(db, uid, report_id, photo)


def confirm_candidate(db, uid: str, candidate_id: str) -> dict | None:
    """The user says a staged candidate is really them: mark it confirmed and
    merge it into the persistent report. Returns the updated candidate dict,
    or ``None`` if there's no such (still-pending) candidate."""
    candidate_id = (candidate_id or "").strip()
    if not db or not uid or not candidate_id:
        return None
    ref = _candidates_col(db, uid).document(candidate_id)
    snap = ref.get()
    if not getattr(snap, "exists", False):
        return None
    data = snap.to_dict() or {}
    from firebase_admin import firestore

    data["status"] = STATUS_CONFIRMED
    ref.set(
        {"status": STATUS_CONFIRMED, "decided_at": firestore.SERVER_TIMESTAMP},
        merge=True,
    )
    _merge_confirmed_photo(db, uid, data)
    data.setdefault("candidate_id", candidate_id)
    return data


def reject_candidate(db, uid: str, candidate_id: str) -> dict | None:
    """The user says a staged candidate is NOT them: mark it rejected. Never
    touches the persistent report. Returns the updated candidate dict, or
    ``None`` if there's no such candidate."""
    candidate_id = (candidate_id or "").strip()
    if not db or not uid or not candidate_id:
        return None
    ref = _candidates_col(db, uid).document(candidate_id)
    snap = ref.get()
    if not getattr(snap, "exists", False):
        return None
    from firebase_admin import firestore

    ref.set(
        {"status": STATUS_REJECTED, "decided_at": firestore.SERVER_TIMESTAMP},
        merge=True,
    )
    data = snap.to_dict() or {}
    data["status"] = STATUS_REJECTED
    data.setdefault("candidate_id", candidate_id)
    return data
