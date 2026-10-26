"""The generic report hub (§ generic reports): report-type registry, owner
resolution, and the ONE correction router every report type's tap-to-correct
goes through.

Two entry points, meant to back exactly two endpoints in ``main.py``:

* :func:`get_report` — ``GET /report/{report_type}/{id}``. Builds the block
  report via the right adapter (``report_adapters.py``) and wraps it with
  ``meta``. Raises ``KeyError`` (-> 404) when there's nothing to report yet,
  ``PermissionError`` (-> 403) when this report type is never readable by
  anyone but its owner and the caller isn't them.

* :func:`correct` — ``POST /report/{report_type}/{id}/correct``. Resolves
  which block(s) ``{block_ids, scope}`` actually names, checks the caller
  owns the report (``PermissionError`` -> 403 otherwise — a non-owner's
  mutation attempt is rejected server-side, never just hidden client-side),
  and routes each block to its OWNING PRODUCER's real mutation function:
  ``appearance.correct_finding`` / ``.clear_finding``,
  ``deep_dive.correct_finding`` / ``.dispute_fact`` / ``.dispute_social_link``
  / ``.dispute_web_image``, or a small composition of
  ``story.edit_section`` + ``story.apply_span_action`` /
  ``.save_section`` / ``.set_visibility`` / ``.remove_section`` — never a
  re-implementation of any of that logic.

Quick actions ("Make public" / "Make private" / "Delete" — the only default
buttons per the founder's spec; everything else is free-form chat) travel
through the exact same ``{block_ids, scope, message}`` shape: a client sends
one of the three fixed phrases (:data:`QUICK_MAKE_PUBLIC` etc.) as ``message``
and :func:`correct` recognises them and applies the change directly —
deterministically, no Gemini call — instead of treating them as free text for
a producer's LLM-mediated correction path. Anything else in ``message`` is
free text, handled by that producer's own correction call.

A pending reverse-image-search candidate (a ``candidate:<id>`` block in
``deep_dive``'s own "Photos to confirm" section — § founder: replaces the
standalone Photo candidates screen) gets a DIFFERENT fixed pair instead of
the make-public/make-private/delete set: :data:`QUICK_CONFIRM_ME` ("This is
me") and :data:`QUICK_NOT_ME` ("Not me"), routed straight to
``reverse_image_search.confirm_candidate`` / ``.reject_candidate``. There is
no free-text correction path for a candidate — those two are the only real
decisions to make about it, so anything else just asks for one of them
rather than spending a Gemini call on what's really a yes/no.

``"match"`` is READ-ONLY for both its participants and has NO correction path
at all — a match score is algorithmically computed
(``matching_skill.score_pair``), not user-authored content, so there is
nothing to "correct" the way a Story passage or an Appearance finding is.
See :func:`resolve_owner` (both participants resolve to themselves as
"owner", a non-participant resolves to nothing at all — a 404, never a 403,
so a non-participant learns nothing about whether the pair has even been
scored), :func:`get_report` (``viewer_can_edit`` is force-``False`` for this
type regardless of participancy — no quick-action / correction affordance is
ever offered client-side), and :func:`correct` (a stray write attempt still
gets a clear, deterministic "nothing to correct" reply instead of silently
no-op'ing or falling into the generic "unsupported report type" case meant
for an actually-unknown type).
"""

from __future__ import annotations

import logging

import appearance
import deep_dive
import pair_key
import physical_attributes
import report_adapters
import report_blocks as rb
import reverse_image_search
import story
import token_ledger

logger = logging.getLogger("ayma.report_hub")

REPORT_TYPES = (
    "appearance",
    "deep_dive",
    "story_private",
    "story_public",
    "story_ai_notes",
    "match",
    "public_profile",
)

# Report types that are NEVER editable by anyone, whoever is asking —
# `get_report` force-clears `viewer_can_edit` and `correct` answers any
# stray write with a deterministic "nothing to correct here" reply instead
# of routing to a producer mutation. `match`: a score is algorithmically
# computed, not user-authored (§ module docstring). `public_profile`:
# ANOTHER member's public profile as seen from Explore — a viewer never
# corrects someone else's profile, and the owner edits their own through
# Your Story / `story_public`, never through this read-only view.
_READ_ONLY_TYPES = {"match", "public_profile"}

# Report types that are never shown to anyone but their owner today — no
# other endpoint in the app exposes them cross-user, so the generic reader
# doesn't invent new exposure either. `story_public` and `deep_dive` ARE
# readable by any authenticated caller, same as their existing endpoints
# (`GET /deep-dive-report/{id}`, the public-profile screen). `match` is here
# too, but for a different reason: it isn't "only ONE owner" in the usual
# single-subject sense — BOTH participants may read it — `resolve_owner`
# gets there by handing back the CALLER's own uid whenever they're one of
# the two people in the pair (and `None` — a 404, not a 403, for anyone
# else), so `owner_uid == viewer_uid` already IS the exact "is this one of
# the two participants" check by the time this runs.
_OWNER_ONLY_READ = {"appearance", "story_private", "story_ai_notes", "match"}

QUICK_MAKE_PUBLIC = "make public"
QUICK_MAKE_PRIVATE = "make private"
QUICK_DELETE = "delete"
# Candidate-only (§ founder: replaces the Photo candidates screen) — see the
# module docstring. Matched against the Flutter side's own existing button
# labels on that screen (`photo_candidates_screen.dart`) verbatim.
QUICK_CONFIRM_ME = "this is me"
QUICK_NOT_ME = "not me"
_QUICK_ACTIONS = {
    QUICK_MAKE_PUBLIC, QUICK_MAKE_PRIVATE, QUICK_DELETE,
    QUICK_CONFIRM_ME, QUICK_NOT_ME,
}


def _iso(v):
    return v if isinstance(v, str) or v is None else (
        v.isoformat() if hasattr(v, "isoformat") else None
    )


# --- ownership --------------------------------------------------------


def resolve_owner(report_type: str, report_id: str, viewer_uid: str) -> str | None:
    """The Firestore owner uid for ``(report_type, report_id)``, or ``None``
    when ``report_type`` is unrecognised. Never itself checks read/write
    permission — see :func:`_can_read` and :func:`correct`."""
    if report_type == "appearance":
        return report_id  # self-owned: the id IS the subject uid
    if report_type in ("story_private", "story_public", "story_ai_notes"):
        return report_id  # same — Story has one doc per user, keyed by uid
    if report_type == "public_profile":
        return report_id  # the id IS the subject's uid, one profile per user
    if report_type == "deep_dive":
        return deep_dive.report_owner(report_id, viewer_uid)
    if report_type == "match":
        # `report_id` is a sorted-pair key (`pair_key.sorted_pair_key`) —
        # NOT a single subject uid. There's no one "owner"; instead, hand
        # back the CALLER's own uid iff they're actually one of the two
        # people in the pair, else `None` (-> 404 in `get_report`/`correct`,
        # never a 403 that would leak "this pair has been scored" to a
        # stranger). See the module docstring's "match" paragraph.
        try:
            a, b = pair_key.uids_from_pair_key(report_id)
        except ValueError:
            return None
        return viewer_uid if viewer_uid in (a, b) else None
    return None


def _can_read(report_type: str, owner_uid: str, viewer_uid: str) -> bool:
    if report_type in _OWNER_ONLY_READ:
        return viewer_uid == owner_uid
    # story_public, deep_dive, public_profile: any authenticated caller —
    # same audience their existing endpoints (`GET /deep-dive-report/{id}`,
    # `GET /explore/profile/{uid}`) already serve.
    return True


# --- adapter dispatch ---------------------------------------------------


def _build(db, report_type: str, owner_uid: str, report_id: str, viewer_uid: str | None = None):
    """``(report, created_at, updated_at)`` from the right adapter, or
    ``(None, None, None)`` when there's nothing yet. ``viewer_uid`` is
    threaded through for ``deep_dive`` only — it gates whether the pending
    reverse-image-search "Photos to confirm" section is included at all
    (owner-only; see ``report_adapters.deep_dive_blocks``). ``story_public``
    no longer depends on who's asking (§ founder 2026-09-21: its Attributes
    section — the one thing that varied by viewer — was removed; see
    ``report_adapters.story_public_blocks``)."""
    if report_type == "appearance":
        # `report_id` here is the URL's id, which for this type IS the
        # subject uid (see `resolve_owner`) — never a real appearance-report
        # doc id. The one persistent doc is always "current"; passing
        # `report_id` through used to make every real request 404 (it tried
        # to look up a legacy doc literally named after the uid).
        return report_adapters.appearance_blocks(db, owner_uid, "current")
    if report_type == "deep_dive":
        return report_adapters.deep_dive_blocks(db, owner_uid, report_id, viewer_uid=viewer_uid)
    if report_type == "story_private":
        return report_adapters.story_private_blocks(db, owner_uid)
    if report_type == "story_public":
        return report_adapters.story_public_blocks(db, owner_uid)
    if report_type == "story_ai_notes":
        return report_adapters.story_ai_notes_blocks(db, owner_uid)
    if report_type == "public_profile":
        # `owner_uid` IS the subject uid (see `resolve_owner`); the adapter
        # itself reads through `public_profile._public_pages`, the same
        # source of truth `GET /explore/profile` serves, so the two views
        # can't diverge on visibility/redaction.
        return report_adapters.public_profile_blocks(db, owner_uid)
    if report_type == "match":
        # `owner_uid` here IS the caller's own uid (see `resolve_owner`) —
        # `report_id` (the match's pair-key id) is what actually identifies
        # which doc and which "other" person.
        return report_adapters.match_blocks(db, owner_uid, report_id)
    raise ValueError(f"unknown report_type {report_type!r}")


def get_report(db, report_type: str, report_id: str, viewer_uid: str) -> dict:
    """``{title, sections, meta}`` for ``GET /report/{report_type}/{id}``.

    Raises ``ValueError`` for an unrecognised ``report_type``, ``KeyError``
    when there's nothing to report yet (-> 404), ``PermissionError`` when
    this report type is owner-only and ``viewer_uid`` isn't the owner
    (-> 403)."""
    if report_type not in REPORT_TYPES:
        raise ValueError(f"unknown report_type {report_type!r}")
    owner = resolve_owner(report_type, report_id, viewer_uid)
    if not owner:
        raise KeyError(report_id)
    if not _can_read(report_type, owner, viewer_uid):
        raise PermissionError("not allowed to view this report")
    report, created_at, updated_at = _build(db, report_type, owner, report_id, viewer_uid)
    if report is None:
        raise KeyError(report_id)
    return {
        "title": report["title"],
        "sections": report["sections"],
        "meta": {
            "owner_uid": owner,
            # `_READ_ONLY_TYPES` are force-False here regardless of who's
            # asking. `match`: a match score has no correction path at all
            # (§ module docstring), so the client's quick-action /
            # tap-to-correct affordances must never appear for it, even
            # though a participant technically "owns" (in the read sense)
            # their own view of it and would otherwise pass
            # `owner == viewer_uid`. `public_profile`: same force-False —
            # even the subject viewing their own public profile edits it
            # through Your Story (`story_public`), never through this
            # Explore-facing read.
            "viewer_can_edit": (
                owner == viewer_uid and report_type not in _READ_ONLY_TYPES
            ),
            "created_at": _iso(created_at),
            "updated_at": _iso(updated_at),
            # Appearance only: the analysed photos the owner has removed from
            # their shareable report card (by Storage path). Card-only — the
            # full report above still carries every photo. Empty / absent for
            # every other report type.
            "card_hidden_photos": report.get("card_hidden_photos") or [],
        },
    }


# --- teaser ---------------------------------------------------------------


def teaser(report_type: str, block_report: dict, *, digest: dict | None = None) -> str:
    """A short chat-ready pointer at a block report. Deep-dive keeps its own
    hand-written :func:`deep_dive.teaser` (the founder's report-completion
    chat-message fix from earlier today) when a ``digest`` is supplied;
    every other type — and deep-dive when no ``digest`` is on hand — falls
    back to the generic :func:`report_blocks.teaser_from_blocks`."""
    if report_type == "deep_dive" and digest is not None:
        return deep_dive.teaser(digest)
    return rb.teaser_from_blocks(block_report)


# --- block-id -> producer target -----------------------------------------


def _appearance_target(block_id: str) -> str | None:
    if block_id in ("face", "body"):
        return block_id
    if block_id.startswith("face:") or block_id.startswith("body:"):
        if block_id.endswith(":status"):
            return None
        return block_id.split(":", 1)[0]
    if block_id.startswith("attr:"):
        field = block_id[len("attr:"):]
        return field if field in physical_attributes.fields() else None
    return None


def _deep_dive_target(block_id: str) -> str | None:
    if block_id == "summary" or block_id.startswith("summary:sent:"):
        return "summary"
    if (
        block_id.startswith("fact:")
        or block_id.startswith("social:")
        or block_id.startswith("photo:")
        or block_id.startswith("candidate:")
    ):
        return block_id
    return None  # confidence / caveats / link:* / confirmed_photos: read-only


def _story_locator(block_id: str) -> tuple[str | None, int | None]:
    """``(page_id, sentence_index)`` for a Story block id, or
    ``(None, None)`` when it isn't a correctable block (a status
    placeholder like ``page:<id>:empty``, or anything not shaped like one
    of this adapter's own ids)."""
    if not block_id.startswith("page:"):
        return None, None
    rest = block_id[len("page:"):]
    if rest.endswith(":empty"):
        return None, None
    if ":sent:" in rest:
        page_id, _, idx_s = rest.rpartition(":sent:")
        if page_id and idx_s.isdigit():
            return page_id, int(idx_s)
    return None, None


# --- scope resolution ---------------------------------------------------


def _resolve_target_block_ids(
    report: dict, block_ids: list[str], scope: str
) -> list[str]:
    """The full set of block ids a correction should actually apply to,
    per ``scope``: ``"block"`` -> exactly ``block_ids``; ``"section"`` ->
    every block in whichever section(s) those blocks live in; ``"report"``
    -> every block in the report. Raises ``ValueError`` for a bad ``scope``
    or a ``block_ids`` that doesn't resolve to anything."""
    if scope not in ("block", "section", "report"):
        raise ValueError(f"unknown scope {scope!r}")
    valid_ids = set(rb.all_block_ids(report))
    given = [b for b in block_ids if b in valid_ids]
    if scope == "report":
        return list(valid_ids)
    if not given:
        raise ValueError("no such block on this report")
    if scope == "block":
        return given
    # scope == "section"
    headings = {
        sec["heading"]
        for sec in report.get("sections") or []
        if any(b["block_id"] in given for b in sec.get("blocks") or [])
    }
    return rb.block_ids_in_sections(report, headings)


# --- per-producer correction --------------------------------------------


async def _correct_appearance(db, owner: str, target: str, message: str,
                               is_quick: bool, quick: str) -> dict:
    """``target`` is already a resolved Appearance correction target — a
    ``physical_attributes`` field name, or ``"face"``/``"body"`` — NOT a raw
    block id (the caller, :func:`correct`, resolves and dedupes those via
    :func:`_appearance_target` before ever calling this).

    Make-public/make-private is always refused here: Appearance's own
    Attributes section has no visibility concept at all (it's always
    self-owned/private-to-the-owner already). It briefly did, for the
    ``story_public`` Living Report's own now-removed duplicate Attributes
    section (§ founder 2026-09-21) — ``physical_attributes.set_public`` is
    no longer called from anywhere in this module; the per-field visibility
    flag it writes is read by ``explore._passes_filters`` instead."""
    if is_quick and quick in (QUICK_MAKE_PUBLIC, QUICK_MAKE_PRIVATE):
        return {"ok": False, "reply": "Appearance findings don't have a public/private setting."}
    if is_quick and quick == QUICK_DELETE:
        if target in ("face", "body"):
            return {"ok": False, "reply": "the Face and Physique reports can't be deleted, only corrected — tell me what's wrong"}
        try:
            await appearance.clear_finding(db, owner, target)
        except KeyError:
            return {"ok": False, "reply": "that finding isn't on your report"}
        return {"ok": True, "reply": "cleared — it'll go back to whatever your photos show"}

    try:
        result = await appearance.correct_finding(db, owner, target, message)
    except KeyError:
        return {"ok": False, "reply": "that finding isn't on your report"}
    except ValueError:
        return {"ok": False, "reply": "tell me what's wrong with it"}
    except token_ledger.TokenCapExceeded:
        return {
            "ok": False,
            "reply": token_ledger.out_of_credits_message(token_ledger.CONTEXT_CORRECTION),
            "usage_capped": True,
        }
    if not result.get("ok", True):
        return {"ok": False, "reply": result.get("reply") or "that didn't look like a valid value"}
    return {"ok": True, "reply": result.get("reply") or "got it — updated"}


async def _correct_deep_dive(db, owner: str, report_id: str, target: str,
                              message: str, is_quick: bool, quick: str) -> dict:
    """``target`` is already a resolved deep-dive correction target
    (``"summary"``, ``"fact:<id>"``, ``"social:<url>"``, ``"photo:<url>"``,
    ``"candidate:<id>"``) — the caller, :func:`correct`, resolves and
    dedupes those via :func:`_deep_dive_target` before ever calling this."""
    if target.startswith("candidate:"):
        # A pending reverse-image-search candidate gets its OWN fixed pair
        # instead of the make-public/make-private/delete set (§ module
        # docstring) — no free-text correction path, since confirm/reject
        # is the whole decision. reverse_image_search.confirm_candidate /
        # .reject_candidate ARE the exact same functions
        # `POST /web-search/photos/candidates/{id}/confirm|reject` already
        # call — reused here, not duplicated.
        candidate_id = target[len("candidate:"):]
        if quick == QUICK_CONFIRM_ME:
            result = reverse_image_search.confirm_candidate(db, owner, candidate_id)
            if result is None:
                return {"ok": False, "reply": "couldn't find that photo — it might already be decided"}
            return {"ok": True, "reply": "got it — that's you, I've added it to your report"}
        if quick == QUICK_NOT_ME:
            result = reverse_image_search.reject_candidate(db, owner, candidate_id)
            if result is None:
                return {"ok": False, "reply": "couldn't find that photo — it might already be decided"}
            return {"ok": True, "reply": "got it — dismissed, I won't bring that one up again"}
        return {
            "ok": False,
            "reply": 'Tap "This is me" or "Not me" for this photo — that\'s the only call to make on it here.',
        }

    if is_quick and quick in (QUICK_MAKE_PUBLIC, QUICK_MAKE_PRIVATE):
        return {"ok": False, "reply": "Web-search findings don't have a public/private setting."}
    if is_quick and quick == QUICK_DELETE:
        if target == "summary":
            return {"ok": False, "reply": "the summary can't be deleted outright — tell me what's wrong and I'll revise it"}
        kind, _, ident = target.partition(":")
        try:
            if kind == "fact":
                result = deep_dive.dispute_fact(db, owner, report_id, ident)
            elif kind == "social":
                result = deep_dive.dispute_social_link(db, owner, report_id, ident)
            elif kind == "photo":
                result = deep_dive.dispute_web_image(db, owner, report_id, ident)
            else:
                return {"ok": False, "reply": "not sure what to remove"}
        except PermissionError:
            return {"ok": False, "reply": "removal is only available on your own report"}
        if result is None:
            return {"ok": False, "reply": "couldn't find that on the report — it might already be gone"}
        return {"ok": True, "reply": "done — it won't come back on a future search"}

    try:
        result = await deep_dive.correct_finding(
            db, owner, report_id, target=target, feedback=message
        )
    except PermissionError:
        return {"ok": False, "reply": "corrections are only available on your own report"}
    except token_ledger.TokenCapExceeded:
        return {
            "ok": False,
            "reply": token_ledger.out_of_credits_message(token_ledger.CONTEXT_CORRECTION),
            "usage_capped": True,
        }
    if result is None:
        return {"ok": False, "reply": "couldn't find that on the report — it might already be gone"}
    return {"ok": True, "reply": result.get("reply") or "got it — updated"}


async def _correct_story_page(db, owner: str, page_id: str, idx: int | None,
                               message: str, is_quick: bool, quick: str) -> dict:
    """One page's worth of a Story correction. ``idx`` is the single
    sentence index in play — set only when exactly one sentence-level block
    was tapped (``scope == "block"``); ``None`` means "the whole section is
    in play" (a section/report-scope bundle, or a section-header tap),
    mirrored as an empty ``passage`` the same way :mod:`skills.story_edit`'s
    bound tools treat "no highlighted passage" for a whole-section op."""
    try:
        _ref, data = story._require_page(db, owner, page_id)
    except KeyError:
        return {"ok": False, "reply": "that section is gone"}
    body = story._display_body(db, owner, page_id, data)
    # `story.sentence_spans`, not a bare `rb.split_sentences(body)` — it's
    # the same span-aware split `_story_section_blocks` used to build this
    # page's `page:<id>:sent:<n>` blocks in the first place, so `idx` here
    # names the same passage the client tapped (see `story.sentence_spans`'s
    # own docstring).
    spans = story.sentence_spans(body)
    passage = (
        spans[idx]["text"] if idx is not None and 0 <= idx < len(spans) else ""
    )

    if is_quick:
        if quick in (QUICK_MAKE_PUBLIC, QUICK_MAKE_PRIVATE):
            private = quick == QUICK_MAKE_PRIVATE
            action = "private" if private else "public"
            if passage:
                new_body = story.apply_span_action(body, passage, action)
                if new_body == body:
                    return {"ok": False, "reply": "couldn't find that passage in the section"}
                story.save_section(db, owner, page_id, new_body, allow_hidden_changes=True)
            else:
                story.set_visibility(db, owner, page_id, action)
            return {"ok": True, "reply": f"made that {action}"}
        if quick == QUICK_DELETE:
            if passage:
                new_body = story.apply_span_action(body, passage, "ai_only")
                if new_body == body:
                    return {"ok": False, "reply": "couldn't find that passage in the section"}
                story.save_section(db, owner, page_id, new_body)
            else:
                story.remove_section(db, owner, page_id)
            return {"ok": True, "reply": "took that off your profile — I'll still remember it in my notes"}

    try:
        result = await story.edit_section(
            db, owner, page_id, passage, [{"role": "user", "text": message}]
        )
    except KeyError:
        return {"ok": False, "reply": "that section is gone"}
    if result.get("usage_capped"):
        return {
            "ok": False,
            "reply": token_ledger.out_of_credits_message(token_ledger.CONTEXT_CORRECTION),
            "usage_capped": True,
        }

    action = result.get("action")
    reply = result.get("reply") or "got it"
    revised = result.get("revised_body")
    if action in ("span", "chat") and revised:
        story.save_section(db, owner, page_id, revised, allow_hidden_changes=True)
    elif action == "move" and result.get("target_visibility"):
        story.set_visibility(db, owner, page_id, result["target_visibility"])
    elif action == "remove":
        story.remove_section(db, owner, page_id)
    return {"ok": True, "reply": reply}


# Story types whose blocks are ONLY page/sentence blocks — every Story
# report type, now that "story_public" no longer also carries attribute
# blocks (§ founder 2026-09-21: its duplicate Attributes section, added
# 2026-09-20, was removed again).
_STORY_ONLY_TYPES = ("story_private", "story_public", "story_ai_notes")


async def _dispatch_appearance(
    db, owner: str, report_id: str, targets: list[str], message: str,
    is_quick: bool, quick: str,
) -> list[dict]:
    """Every ``attr:``/``face:``/``body:`` block in ``targets``, deduped
    to its underlying Appearance target and corrected once each. The only
    caller is ``report_type == "appearance"`` — ``story_public`` no longer
    carries any ``attr:``/``face:``/``body:`` blocks to dispatch (§ founder
    2026-09-21: its duplicate Attributes section was removed), so this is
    never reached from there any more."""
    keys = sorted({k for k in (_appearance_target(b) for b in targets) if k})
    out: list[dict] = []
    for key in keys:
        try:
            r = await _correct_appearance(db, owner, key, message, is_quick, quick)
        except Exception:  # noqa: BLE001 - one target's failure must not sink the rest
            logger.exception(
                "report_hub: correction failed for appearance/%s/%s", report_id, key
            )
            r = {"ok": False, "reply": "something went wrong correcting that"}
        out.append({"block_id": key, **r})
    return out


async def _dispatch_deep_dive(
    db, owner: str, report_id: str, targets: list[str], message: str,
    is_quick: bool, quick: str,
) -> list[dict]:
    keys = sorted({k for k in (_deep_dive_target(b) for b in targets) if k})
    out: list[dict] = []
    for key in keys:
        try:
            r = await _correct_deep_dive(
                db, owner, report_id, key, message, is_quick, quick
            )
        except Exception:  # noqa: BLE001
            logger.exception(
                "report_hub: correction failed for deep_dive/%s/%s", report_id, key
            )
            r = {"ok": False, "reply": "something went wrong correcting that"}
        out.append({"block_id": key, **r})
    return out


async def _dispatch_story_pages(
    db, owner: str, targets: list[str], scope: str, message: str,
    is_quick: bool, quick: str,
) -> list[dict]:
    by_page: dict[str, list[int]] = {}
    for b in targets:
        page_id, idx = _story_locator(b)
        if page_id is None:
            continue
        idxs = by_page.setdefault(page_id, [])
        if idx is not None:
            idxs.append(idx)
    out: list[dict] = []
    for page_id, idxs in by_page.items():
        single_idx = idxs[0] if (scope == "block" and len(idxs) == 1) else None
        try:
            r = await _correct_story_page(
                db, owner, page_id, single_idx, message, is_quick, quick
            )
        except Exception:  # noqa: BLE001
            logger.exception("report_hub: correction failed for story/%s", page_id)
            r = {"ok": False, "reply": "something went wrong correcting that"}
        out.append({"block_id": f"page:{page_id}", **r})
    return out


async def correct(
    db,
    report_type: str,
    report_id: str,
    uid: str,
    *,
    block_ids: list[str],
    scope: str,
    message: str,
) -> dict:
    """Route a tap-to-correct turn to the right producer. Raises
    ``ValueError`` for an unrecognised ``report_type``/``scope`` or an empty
    ``block_ids``/``message``, ``KeyError`` when the report doesn't exist
    (-> 404), ``PermissionError`` when ``uid`` isn't the report's owner
    (-> 403 — enforced HERE, before any producer call, regardless of
    whether that producer would also have caught it).

    Returns ``{ok, results: [{block_id, ok, reply, usage_capped?}, ...]}``
    — ``ok`` true overall iff every resolved block's correction succeeded.
    """
    if report_type not in REPORT_TYPES:
        raise ValueError(f"unknown report_type {report_type!r}")
    block_ids = [b for b in (block_ids or []) if b]
    message = (message or "").strip()
    if not block_ids:
        raise ValueError("block_ids is required")
    if not message:
        raise ValueError("message is required")

    owner = resolve_owner(report_type, report_id, uid)
    if not owner:
        raise KeyError(report_id)
    if owner != uid:
        raise PermissionError("only the report's owner can correct it")

    # owner == uid is already enforced above, so the pending-candidates
    # section (deep_dive only, owner-gated) is always in scope here.
    report, _created, _updated = _build(db, report_type, owner, report_id, owner)
    if report is None:
        raise KeyError(report_id)

    targets = _resolve_target_block_ids(report, block_ids, scope)

    quick = message.strip().lower()
    is_quick = quick in _QUICK_ACTIONS

    # Dedupe by the underlying PRODUCER TARGET, not by raw block id, before
    # calling anything — a section/report-scope bundle can resolve to many
    # leaf blocks that all belong to the same finding (Appearance's "face"
    # axis, a Story page's several sentences, ...); correcting each of those
    # separately would mean one redundant Gemini call per leaf block instead
    # of one real correction for the whole bundle.
    results: list[dict] = []
    if report_type == "appearance":
        results = await _dispatch_appearance(
            db, owner, report_id, targets, message, is_quick, quick
        )
    elif report_type == "deep_dive":
        results = await _dispatch_deep_dive(
            db, owner, report_id, targets, message, is_quick, quick
        )
    elif report_type in _STORY_ONLY_TYPES:
        results = await _dispatch_story_pages(
            db, owner, targets, scope, message, is_quick, quick
        )
    elif report_type == "match":
        # No correction path exists for this type at all (§ module
        # docstring) — a match score is algorithmically computed, not
        # user-authored content. The client never offers a quick-action or
        # tap-to-correct affordance for it (`get_report` force-clears
        # `viewer_can_edit` above), but a stray direct POST here — or a
        # future client bug — still gets a clear, deliberate answer instead
        # of silently no-op'ing or falling into the generic "unsupported
        # report type" branch below, which is reserved for an actually
        # unrecognised type (never reachable for `match`, since it's in
        # `REPORT_TYPES`).
        results = [
            {
                "block_id": b,
                "ok": False,
                "reply": (
                    "Match scores are worked out automatically from both "
                    "of your profiles — there's nothing here to correct "
                    "directly. Ask me about it instead, or update your own "
                    "profile and recalculate."
                ),
            }
            for b in targets
        ]
    elif report_type == "public_profile":
        # Read-only, like `match` (§ `_READ_ONLY_TYPES`): only the subject
        # themself can even reach this branch (`owner != uid` already 403'd
        # above), and their real editing surface is Your Story — answer a
        # stray write deterministically instead of routing anywhere.
        results = [
            {
                "block_id": b,
                "ok": False,
                "reply": (
                    "This is the read-only public view of a profile — "
                    "there's nothing to correct here. Edit your own "
                    "profile from Your Story instead."
                ),
            }
            for b in targets
        ]
    else:  # pragma: no cover - report_type validated above
        results = [{"block_id": b, "ok": False, "reply": "unsupported report type"} for b in targets]

    if not results:
        results = [
            {
                "block_id": targets[0] if targets else "",
                "ok": False,
                "reply": "this isn't something I can correct directly",
            }
        ]
    return {"ok": all(r.get("ok") for r in results), "results": results}
