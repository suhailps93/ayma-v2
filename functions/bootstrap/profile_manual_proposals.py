"""Ayma's updates to public text: propose, then apply or dismiss.

Tier-2 sweep monolith split #12: the ``--- Ayma's updates: propose, then
apply or dismiss ---`` section of the former ``profile_manual.py`` monolith,
moved verbatim — no behavior change.
"""

from __future__ import annotations

import difflib
import hashlib
import logging
from datetime import datetime, timezone

from timefmt import utcnow
import report_blocks as rb
import story
from profile_manual_common import (
    F_PINNED,
    F_PROPOSAL,
    _mark_avatar_stale,
    _norm,
    _PIN_SIMILAR,
    _SUPPRESS_WINDOW,
)
from profile_manual_diff import diff_segments
from profile_manual_save import _build_body

logger = logging.getLogger("ayma.profile_manual")


def _similar(a: str, b: str) -> bool:
    """Whether two normalized sentences are close enough to be the same fact
    reworded (see :data:`_PIN_SIMILAR`)."""
    return difflib.SequenceMatcher(None, a, b, autojunk=False).ratio() >= _PIN_SIMILAR


def _pins_to_append(pinned: list[str], public_text: str) -> list[str]:
    """The pinned sentences that must be re-attached to ``public_text`` because
    they are genuinely absent — deduplicated and never a reworded restatement of
    something already shown.

    A pinned sentence is already present (so it is skipped, never appended as a
    duplicate) when its normalized text is a substring of the public text, or
    when some sentence already in the public text — or a pin we already accepted
    this pass — is a near-duplicate of it (:func:`_similar`). Without this, a
    pinned fact the user reworded no longer matches verbatim and gets appended
    again, piling up garbled duplicate half-sentences (founder bug 2026-10-28).
    Accepted pins join the running set so two near-duplicate pins can't both be
    added. Returned in input order."""
    public_norm = _norm(public_text)
    present = [_norm(s) for s in rb.split_sentences(public_text) if _norm(s)]
    out: list[str] = []
    for sentence in pinned:
        n = _norm(sentence)
        if not n or n in public_norm:
            continue
        if any(e in n or _similar(n, e) for e in present):
            continue
        present.append(n)
        out.append(sentence.strip())
    return out


def _prune_pins(pinned: list[str], public_text: str) -> list[str]:
    """The stored pinned list reduced to the sentences actually carried on the
    public text now — dropping ones the user (or an applied rewrite) has since
    reworded or removed, and collapsing exact duplicates. Keeps pinned honest so
    a superseded entry can never be re-appended on a later rebuild. Mirrors the
    substring filter :func:`_write_section` already applies on a manual save."""
    public_norm = _norm(public_text)
    out: list[str] = []
    seen: set[str] = set()
    for p in pinned:
        n = _norm(p)
        if not n or n not in public_norm or n in seen:
            continue
        seen.add(n)
        out.append(p)
    return out


def preserve(new_body: str, current_body: str, pinned: list[str]) -> str:
    """``new_body`` with every ``ai_only`` span of ``current_body`` kept, and
    every pinned sentence that is genuinely missing re-attached. A pinned
    sentence already represented on the public text — verbatim or reworded — is
    never re-appended (:func:`_pins_to_append`), so a rewrite can't resurrect a
    fact the user edited away or duplicate one they rephrased."""
    segments = story.parse_spans(new_body)
    have_ai = _norm(" ".join(s["text"] for s in segments if s["kind"] == "ai_only"))
    public_now = story.strip_private_spans(new_body)
    for seg in story.parse_spans(current_body):
        if seg["kind"] == "ai_only" and _norm(seg["text"]) not in have_ai:
            segments.append({"text": "\n", "kind": "public"})
            segments.append({"text": seg["text"].strip(), "kind": "ai_only"})
    for sentence in _pins_to_append(pinned, public_now):
        segments.append({"text": "\n\n" + sentence, "kind": "public"})
    return story._serialize_spans(segments).strip()


def _edited_within_window(ts) -> bool:
    """Whether a user edit stamped ``user_updated_at`` (``ts``) landed within
    :data:`_SUPPRESS_WINDOW` of now. Best-effort — anything that is not a usable
    timestamp reads as 'not recent', never raising into an ingest write."""
    if not isinstance(ts, datetime):
        return False
    try:
        edited = ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)
        return utcnow() - edited <= _SUPPRESS_WINDOW
    except Exception:  # noqa: BLE001
        return False


def route_ai_update(page_id: str, cur: dict, payload: dict) -> dict:
    """Extra fields for ``wiki_ingest._write_page`` when Ayma rewrites a page
    that already shows public text. The new ``ai_body`` itself is always kept
    (it is Ayma's memory), but the text visitors see only changes when the
    user approves: the current public text is frozen as ``user_edits`` and the
    rewrite becomes a ``pending_proposal``. A new proposal always REPLACES the
    page's previous one, so a section is never carrying two cards at once —
    only the latest rewrite is ever pending. Pages with nothing public yet
    (first write, private, hidden) are written straight through.

    The propose/Apply-Dismiss flow is only for Ayma's OWN discovered edits.
    When the user themselves just edited this section in place
    (``story.save_section``/``remove_section`` stamped the
    ``suppress_next_proposal`` guard and ``user_updated_at`` and already cleared
    the live card), a rewrite that would differ from their text is swallowed
    instead of re-surfaced as a pending card — so a lagging re-ingest can never
    revert the user's own change, and a user-requested edit never produces a
    proposal (founder bug 2026-10-28).

    Suppression fires on either signal: the explicit one-shot flag, OR the page
    having been user-edited within :data:`_SUPPRESS_WINDOW`. The one-shot flag
    alone caught only the FIRST diverging pass, but more than one stale ingest
    can be in flight after an edit; the time window keeps swallowing every
    lagging pass until it lapses, so the edit reliably stays applied in place
    across the whole re-ingest window. The explicit flag is spent only on a
    swallowed divergence; the window needs no spending (it lapses on its own),
    and writes with nothing to propose (private/hidden page, first public write,
    or a rewrite already matching the live text) keep the flag. After the window
    lapses a genuinely new Ayma discovery surfaces as a proposal as before."""
    suppress_flag = bool(cur.get(story.F_SUPPRESS_PROPOSAL))
    suppress = suppress_flag or _edited_within_window(
        cur.get(story.F_USER_UPDATED_AT)
    )
    has_proposal = bool(cur.get(F_PROPOSAL))

    def _settle(spend: bool) -> dict:
        """A write with nothing to propose: clear any stale card, and consume
        the explicit one-shot flag only when ``spend`` (i.e. we actually
        swallowed a diverging rewrite). The time window is never spent here."""
        out: dict = {}
        if has_proposal:
            out[F_PROPOSAL] = None
        if suppress_flag and spend:
            out[story.F_SUPPRESS_PROPOSAL] = False
        return out

    if (
        payload.get("visibility") != story.VIS_PUBLIC
        or cur.get("visibility") != story.VIS_PUBLIC
        or page_id in story.REPORT_LINKED_PAGE_IDS
        or page_id in story.SKILL_PAGE_IDS
    ):
        return _settle(spend=False)
    current = story._effective_body(cur)
    current_public = _norm(story.strip_private_spans(current))
    if not current_public:
        return _settle(spend=False)
    after = preserve(payload["ai_body"], current, list(cur.get(F_PINNED) or []))
    if _norm(story.strip_private_spans(after)) == current_public:
        return _settle(spend=False)
    # Ayma's rewrite diverges from the live public text.
    if suppress:
        # The user edited this section directly (one-shot flag set, or within
        # the window): swallow this diverging rewrite — never re-propose or
        # revert their change — and spend the explicit flag if it was set.
        return _settle(spend=True)
    out: dict = {F_PROPOSAL: {"before": current, "after": after, "created_at": utcnow()}}
    if not (cur.get(story.F_USER_EDITS) or "").strip():
        out[story.F_USER_EDITS] = current
    return out


def _title(page_id: str, data: dict) -> str:
    return story._section_title(
        page_id,
        str(data.get(story.F_PAGE_TYPE) or "misc"),
        data.get(story.F_TITLE) or "",
    )


def _iter_changes(before_public: str, after_public: str):
    """Yield ``(segment, change_id)`` over the sentence diff. ``change_id`` is
    ``None`` for unchanged sentences and ``c0``, ``c1`` … for each added or
    removed sentence, in diff order. Both ``before`` and ``after`` are frozen
    on the proposal, so these ids are stable — a single change can be applied
    or dismissed on its own and the rest re-render correctly."""
    k = 0
    for seg in diff_segments(before_public, after_public):
        if seg["op"] == "same":
            yield seg, None
        else:
            yield seg, f"c{k}"
            k += 1


def _change_items(before_public: str, after_public: str) -> list[dict]:
    """The reviewable changes: one ``{id, op, text}`` per added/removed
    sentence. Ids stay aligned with :func:`_iter_changes` (and so with
    :func:`_rebuild_public`), so every position is decidable — display-time
    deduplication of identical rows is :func:`_dedupe_changes`'s job, not
    this one."""
    return [
        {"id": cid, "op": seg["op"], "text": seg["text"]}
        for seg, cid in _iter_changes(before_public, after_public)
        if cid is not None
    ]


def _dedupe_changes(changes: list[dict]) -> list[dict]:
    """Collapse rows with the same op and normalized text to the first, for
    display. A messy frozen base can repeat a sentence; the review card must
    never show the same change twice (founder bug 2026-10-28). The dropped
    row keeps its own id and stays decidable — resolving the shown row and
    re-reading simply drops the duplicate from the next render."""
    out: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for ch in changes:
        key = (ch["op"], _norm(ch["text"]))
        if key in seen:
            continue
        seen.add(key)
        out.append(ch)
    return out


def _decided_map(prop: dict) -> dict[str, str]:
    dec = prop.get("decided")
    return dict(dec) if isinstance(dec, dict) else {}


def _rebuild_public(
    before_public: str, after_public: str, decided: dict[str, str]
) -> tuple[str, list[str]]:
    """The public text to show given the decisions so far, plus the sentences
    to keep privately (so nothing is discarded):

    * unchanged sentence -> stays public;
    * added sentence -> public once *applied*; a *dismissed* one is kept
      privately (never shown publicly);
    * removed sentence -> stays public until the removal is *applied*, then it
      is kept privately rather than dropped.

    An undecided change leaves the public text exactly as it was.
    """
    public: list[str] = []
    private: list[str] = []
    for seg, cid in _iter_changes(before_public, after_public):
        if cid is None:
            public.append(seg["text"])
            continue
        verdict = decided.get(cid)
        if seg["op"] == "add":
            if verdict == "applied":
                public.append(seg["text"])
            elif verdict == "dismissed":
                private.append(seg["text"])
        else:  # remove
            if verdict == "applied":
                private.append(seg["text"])
            else:
                public.append(seg["text"])
    return _norm(" ".join(public)), private


def _compose_body(
    current_body: str, new_public: str, private: list[str], pinned: list[str]
) -> str:
    """Rebuild the stored body: ``new_public`` as the public text, every
    existing private / ``ai_only`` span kept, each ``private`` sentence added
    as an ``ai_only`` note (Ayma still has it and it shows in Ayma's Notes, but
    never on the public profile), and every pinned sentence kept public."""
    body = _build_body(current_body, new_public, private)
    segments = story.parse_spans(body)
    for sentence in _pins_to_append(pinned, story.strip_private_spans(body)):
        segments.append({"text": "\n\n" + sentence, "kind": "public"})
    return story._serialize_spans(segments).strip()


def _write_decided(
    db,
    uid: str,
    page_id: str,
    ref,
    data: dict,
    prop: dict,
    before_public: str,
    after_public: str,
    items: list[dict],
    decided: dict[str, str],
) -> dict:
    """Write the public text, private notes and ``ai_body`` implied by
    ``decided``, keep the proposal with its decisions until every change is
    resolved (then clear it), and commit a version. Dismissed additions and
    applied removals are appended to ``ai_body`` so Ayma's matching/chat still
    know them."""
    new_public, private = _rebuild_public(before_public, after_public, decided)
    pinned = list(data.get(F_PINNED) or [])
    body = _compose_body(story._effective_body(data), new_public, private, pinned)
    # Keep the stored pinned list honest: drop entries the applied text has
    # reworded or dropped so a superseded pin can never be re-appended later
    # (founder bug 2026-10-28). Mirrors the filter _write_section applies.
    pruned_pins = _prune_pins(pinned, story.strip_private_spans(body))
    ai_body = (data.get(story.F_AI_BODY) or "").strip()
    fresh = [p for p in private if _norm(p) not in _norm(ai_body)]
    if fresh:
        ai_body = (ai_body + "\n\n" if ai_body else "") + " ".join(fresh)
    remaining = [it for it in items if it["id"] not in decided]
    ref.set(
        {
            story.F_USER_EDITS: body,
            story.F_USER_UPDATED_AT: story._server_ts(),
            story.F_AI_BODY: ai_body,
            F_PINNED: pruned_pins,
            F_PROPOSAL: None if not remaining else {**prop, "decided": decided},
        },
        merge=True,
    )
    version_id = story._snapshot_section(
        db, uid, page_id, story.AUTHOR_AYMA, "update reviewed by you"
    )
    _mark_avatar_stale(db, uid)
    return {"ok": True, "remaining": len(remaining), "head_version_id": version_id}


def _live_matches_decisions(
    data: dict, before_public: str, after_public: str, decided: dict[str, str]
) -> bool:
    """Whether the live public text is still exactly what the proposal's
    decisions so far imply (``_rebuild_public``). It is, in the normal flow:
    an undecided proposal leaves the live text as the frozen ``before``, and
    each per-change apply writes exactly the rebuilt text. It is NOT when the
    user edited the section directly in the meantime (``save_section`` already
    clears the card, but a pre-fix card may linger) or a newer rewrite moved
    the base: the proposal is then built on text that no longer exists, so
    applying it would overwrite the user's current wording. Such a proposal is
    stale — dropped on read and refused on apply, never regressed onto."""
    live = _norm(story.strip_private_spans(story._effective_body(data)))
    expected, _private = _rebuild_public(before_public, after_public, decided)
    return live == expected


def list_proposals(db, uid: str) -> list[dict]:
    """Every pending public-profile change, grouped by section, each change a
    ``{id, op, text}`` row with its own stable id. The profile banner counts
    the changes across this list. A proposal that is not a dict, whose changes
    have all been decided, or that is stale — its frozen base no longer matches
    the live public text, because the user edited the line directly or a newer
    rewrite superseded it (:func:`_live_matches_decisions`) — has nothing left
    to review: it is cleared here and logged, so the banner never counts a
    change that cannot render and a lingering stale card self-heals on read."""
    out = []
    for snap in story._pages_col(db, uid).stream():
        data = snap.to_dict() or {}
        prop = data.get(F_PROPOSAL)
        if not prop or data.get(story.F_USER_HIDDEN) is True:
            continue
        if not isinstance(prop, dict):
            snap.reference.set({F_PROPOSAL: None}, merge=True)
            logger.info(
                "profile proposal cleared as malformed uid=%s page=%s", uid, snap.id
            )
            continue
        before_public = story.strip_private_spans(prop.get("before") or "")
        after_public = story.strip_private_spans(prop.get("after") or "")
        decided = _decided_map(prop)
        pending = [
            it for it in _change_items(before_public, after_public)
            if it["id"] not in decided
        ]
        if not pending or not _live_matches_decisions(
            data, before_public, after_public, decided
        ):
            snap.reference.set({F_PROPOSAL: None}, merge=True)
            logger.info(
                "profile proposal cleared as stale uid=%s page=%s", uid, snap.id
            )
            continue
        out.append(
            {
                "page_id": snap.id,
                "title": _title(snap.id, data),
                "changes": _dedupe_changes(pending),
            }
        )
    out.sort(key=lambda p: p["title"].lower())
    return out


# The set of pending-change keys the user was last notified about — a
# top-level field on ``users/{uid}`` so the suggestion push is deduped.
F_SUGGEST_NOTIFIED = "profile_suggestions_notified"


def pending_change_keys(db, uid: str) -> set[str]:
    """A content-stable key per undecided public-profile change
    (``page_id:sha1(op+text)``), across all sections. Stable across re-renders
    and re-ingests: a re-proposed section with different wording yields
    different keys, so a genuinely new change is detected even when its
    positional id (``c0`` …) is reused."""
    keys: set[str] = set()
    for sec in list_proposals(db, uid):
        for change in sec["changes"]:
            digest = hashlib.sha1(
                f"{change['op']}:{_norm(change['text'])}".encode("utf-8")
            ).hexdigest()[:12]
            keys.add(f"{sec['page_id']}:{digest}")
    return keys


def consume_new_suggestions(db, uid: str) -> int:
    """Compare the current pending public-profile changes to the set the user
    was last notified about, updating the stored set.

    Returns the number of currently-pending changes **when there is at least
    one that is genuinely new** (the pending count went from 0 to >0, or new
    items were added) — the caller then sends one notification. Returns 0 when
    nothing is new (so the nightly run doesn't re-ping for an unchanged set),
    and resets the stored set when there is nothing pending (so a future 0->>0
    fires again)."""
    keys = pending_change_keys(db, uid)
    user_ref = db.collection("users").document(uid)
    stored = (user_ref.get().to_dict() or {}).get(F_SUGGEST_NOTIFIED)
    prev = set(stored) if isinstance(stored, list) else set()
    if not keys:
        if prev:
            user_ref.set({F_SUGGEST_NOTIFIED: []}, merge=True)
        return 0
    has_new = bool(keys - prev)
    if keys != prev:
        user_ref.set({F_SUGGEST_NOTIFIED: sorted(keys)}, merge=True)
    return len(keys) if has_new else 0


def _load_proposal(db, uid: str, page_id: str) -> tuple:
    """``(ref, data, prop, before_public, after_public, items)`` for a page
    with a dict proposal. ``KeyError`` when there is none, or when the proposal
    is stale — its frozen base no longer matches the live public text
    (:func:`_live_matches_decisions`), so applying it would overwrite the
    user's current wording. A stale proposal is cleared here before raising, so
    an Apply/Apply-all can never regress a line to an older proposed value; the
    client's refetch then shows the card gone."""
    ref, data = story._require_page(db, uid, page_id)
    prop = data.get(F_PROPOSAL)
    if not isinstance(prop, dict):
        raise KeyError(page_id)
    before_public = story.strip_private_spans(prop.get("before") or "")
    after_public = story.strip_private_spans(prop.get("after") or "")
    if not _live_matches_decisions(
        data, before_public, after_public, _decided_map(prop)
    ):
        ref.set({F_PROPOSAL: None}, merge=True)
        logger.info(
            "profile proposal cleared as stale on decide uid=%s page=%s",
            uid,
            page_id,
        )
        raise KeyError(page_id)
    items = _change_items(before_public, after_public)
    return ref, data, prop, before_public, after_public, items


def _decide_one(db, uid: str, page_id: str, change_id: str, verdict: str) -> dict:
    ref, data, prop, before_public, after_public, items = _load_proposal(
        db, uid, page_id
    )
    decided = _decided_map(prop)
    if change_id not in {it["id"] for it in items} or change_id in decided:
        raise KeyError(change_id)
    decided[change_id] = verdict
    return _write_decided(
        db, uid, page_id, ref, data, prop, before_public, after_public, items, decided
    )


def apply_change(db, uid: str, page_id: str, change_id: str) -> dict:
    """Show one added sentence on the public profile (or carry out one
    removal). ``KeyError`` when the change is unknown or already decided."""
    return _decide_one(db, uid, page_id, change_id, "applied")


def dismiss_change(db, uid: str, page_id: str, change_id: str) -> dict:
    """Keep one change off the public profile. It is not discarded: it stays
    in the private profile and Ayma's notes. ``KeyError`` when the change is
    unknown or already decided."""
    return _decide_one(db, uid, page_id, change_id, "dismissed")


def _decide_all(db, uid: str, page_id: str, verdict: str) -> dict:
    ref, data, prop, before_public, after_public, items = _load_proposal(
        db, uid, page_id
    )
    decided = _decided_map(prop)
    for it in items:
        decided.setdefault(it["id"], verdict)
    return _write_decided(
        db, uid, page_id, ref, data, prop, before_public, after_public, items, decided
    )


def apply_proposal(db, uid: str, page_id: str) -> dict:
    """Apply every remaining change in one section (Apply all). ``KeyError``
    when there is no pending update."""
    return _decide_all(db, uid, page_id, "applied")


def dismiss_proposal(db, uid: str, page_id: str) -> dict:
    """Dismiss every remaining change in one section (Dismiss all) — each is
    kept in the private profile and Ayma's notes. ``KeyError`` when there is no
    pending update."""
    return _decide_all(db, uid, page_id, "dismissed")
