"""Read-only adapters: each existing report producer's REAL current Firestore
shape -> the generic block model (``report_blocks.py``). § generic reports.

Nothing here changes any producer's storage schema — every adapter just reads
through the producer's own existing read function (``appearance.get_report``,
``deep_dive.read_dive``, ``story.get_story`` / ``get_ai_notes``) and reshapes
the result. The public-story adapter filters ``story.get_story``'s own
sections down to ``visibility == "public"`` and strips private spans via
``story.strip_private_spans`` — the same rule ``public_profile._public_pages``
applies, kept in step with it rather than re-deriving from Firestore directly,
while still keeping each section's real ``page_id`` (needed for the owner's
own tap-to-correct on their public preview).

Every ``block_id`` is chosen so ``report_hub.py`` can parse it straight back
into whatever the owning producer's correction/dispute function needs, with
NO extra id-lookup table required:

* Appearance  — ``attr:<physical_attributes field>``, or ``face`` / ``body``
  (and ``face:<sub-item>`` / ``body:<sub-item>`` for the score/strengths/
  improvements/recommendations/quick-facts that fold into that one axis —
  see :mod:`appearance`'s own docstring: there's no per-sub-item correction
  slot, only the whole axis).
* Deep-dive   — ``summary`` (and ``summary:sent:<n>`` per sentence),
  ``fact:<fact_id>``, ``social:<url>``, ``photo:<url>`` — exactly
  :mod:`skills.deep_dive_edit`'s own ``target`` scheme.
* Story       — ``page:<page_id>`` (the section as a whole) and
  ``page:<page_id>:sent:<n>`` (one sentence within it) — resolved back to a
  passage string by re-splitting that page's current body the same way
  (:func:`report_blocks.split_sentences`), so it stays a faithful substring
  for :func:`story.apply_span_action` / ``edit_passage``-style replacement.

Each adapter returns ``(report, created_at, updated_at)`` — ``report`` is a
``report_blocks.make_report(...)`` dict; ``created_at``/``updated_at`` are
ISO strings or ``None``, for the generic endpoint's ``meta``. Returns
``(None, None, None)`` when there's nothing to report yet (caller 404s).
"""

from __future__ import annotations

import appearance
import deep_dive
import physical_attributes
import report_blocks as rb
import story


# --- Appearance --------------------------------------------------------


def _known(value) -> bool:
    if value is None:
        return False
    if isinstance(value, str) and value.strip().lower() in ("", "unknown"):
        return False
    return True


_AXIS_NOT_USABLE_TEXT = {
    # Byte-identical to face_report.teaser / body_report.teaser's own
    # "usable: False" copy — not that this branch of `scored_result_blocks`
    # is actually reachable from here today (`appearance.run_appearance`
    # only ever assigns a `usable: False` result into `NEEDS_FACE`/
    # `NEEDS_BODY` instead, so a persisted axis is always either the
    # "status" placeholder below or a real usable result) — kept in step
    # anyway so this stays correct if that ever changes.
    "face": (
        "I can't get a clean read on that photo — send a clearer, "
        "front-facing shot with your whole face in frame and I'll take "
        "a proper look."
    ),
    "body": (
        "I can't get a clean read on that photo — send a clearer shot "
        "with your upper body or more visible, in fitted clothing, and "
        "I'll take a proper look."
    ),
}


def _axis_blocks(prefix: str, axis: dict) -> list[dict]:
    """Every block for one of Appearance's ``face``/``body`` axes — all of
    them route back to the single correction target ``prefix`` (``"face"``
    or ``"body"``) in ``report_hub._appearance_target``; there is no finer
    grained correction slot on the producer side (see module docstring).

    ``axis`` is either the "never run yet" placeholder
    (``appearance.NEEDS_FACE``/``NEEDS_BODY`` — ``{"status": ...}``, unique
    to the persisted Appearance report) or the exact
    ``face_report.run()``/``body_report.run()`` result shape, handed to
    :func:`report_blocks.scored_result_blocks` — the one shared builder for
    that shape, also used directly by ``face_report.teaser`` /
    ``body_report.teaser`` on a freshly computed result."""
    if not isinstance(axis, dict) or axis.get("status"):
        note = (
            "Add a face photo to get a Face report."
            if prefix == "face"
            else "Add a body photo to get a Physique report."
        )
        return [rb.section_head_block(f"{prefix}:status", note)]
    return rb.scored_result_blocks(
        axis, id_prefix=prefix, not_usable_text=_AXIS_NOT_USABLE_TEXT[prefix]
    )


def _attribute_blocks(record: dict | None) -> list[dict]:
    """``attr:<field>`` attribute blocks for every KNOWN field in a
    ``physical_attributes``-shaped ``record`` (``{field: {value, source,
    confidence}}``) — shared by :func:`appearance_blocks` and
    :func:`story_public_blocks` (the converged Living Report's Attributes
    section folds in the former "My public profile" self-view's structured
    fields — § founder direction — reading the exact same record either
    way, so both adapters build the exact same block shape from it)."""
    blocks: list[dict] = []
    if isinstance(record, dict):
        for field, rec in record.items():
            if not isinstance(rec, dict) or not _known(rec.get("value")):
                continue
            blocks.append(
                rb.attribute_block(
                    f"attr:{field}",
                    field.replace("_", " ").capitalize(),
                    rec.get("value"),
                    source=str(rec.get("source") or ""),
                    confidence=str(rec.get("confidence") or ""),
                )
            )
    return blocks


def appearance_blocks(db, uid: str, report_id: str = "current"):
    """Adapter for the caller's own persistent Appearance report
    (``appearance.get_report``). Always self-owned."""
    data = appearance.get_report(db, uid, report_id)
    if data is None:
        return None, None, None

    attrs = data.get("attributes") or {}
    record = attrs.get("record") if isinstance(attrs, dict) else None
    attr_blocks = _attribute_blocks(record) or [
        rb.section_head_block("attr:status", "Add a photo to get your attributes read.")
    ]

    sections = [
        rb.make_section("Attributes", attr_blocks),
        rb.make_section("Face", _axis_blocks("face", data.get("face") or {})),
        rb.make_section("Body", _axis_blocks("body", data.get("body") or {})),
    ]
    report = rb.make_report("Appearance", sections)
    created = data.get("created_at")
    return report, created, created


# --- Deep-dive / web-search --------------------------------------------


def deep_dive_blocks(db, owner_uid: str, report_id: str):
    """Adapter for a stored deep-dive doc (``deep_dive.read_dive``) — works
    identically for a self dive and a dive on someone else; the caller
    resolves ``owner_uid`` first (``deep_dive.report_owner``)."""
    data = deep_dive.read_dive(db, owner_uid, report_id)
    if data is None:
        return None, None, None
    digest = data.get("digest") or {}
    name = str(data.get("name") or digest.get("name") or "Unknown")

    # "Is there anything to show yet" — the exact same predicate
    # deep_dive.teaser() uses for its own not-found chat message, so the two
    # never silently disagree about a thin/not-found result (previously this
    # adapter only checked for empty summary text, a narrower and
    # independently-drifting condition — see report_blocks.digest_is_empty).
    summary_blocks: list[dict] = []
    summary_text = str(digest.get("summary") or "").strip()
    if rb.digest_is_empty(digest):
        summary_blocks.append(
            rb.section_head_block("summary:status", "Nothing found yet.")
        )
    else:
        summary_blocks = [
            rb.text_block(f"summary:sent:{i}", sent)
            for i, sent in enumerate(rb.split_sentences(summary_text))
        ] or [rb.section_head_block("summary:status", "Nothing found yet.")]
    conf = str(digest.get("confidence") or "")
    if conf:
        summary_blocks.append(
            rb.stat_block("confidence", "Confidence", conf, editable=False)
        )
    caveats = str(digest.get("caveats") or "").strip()
    if caveats:
        summary_blocks.append(rb.text_block("caveats", caveats, editable=False))

    fact_blocks = [
        rb.fact_block(
            f"fact:{str(f.get('id') or deep_dive.fact_id(f))}",
            str(f.get("claim") or ""),
            tag=str(f.get("category") or ""),
            confidence=str(f.get("confidence") or ""),
        )
        for f in (digest.get("facts") or [])
        if isinstance(f, dict) and str(f.get("claim") or "").strip()
    ]

    link_blocks = [
        rb.link_block(
            f"link:{i}", str(ln.get("url") or ""),
            label=str(ln.get("title") or ln.get("url") or ""),
            tag=str(ln.get("is_them") or ""), editable=False,
        )
        for i, ln in enumerate(digest.get("links") or [])
        if isinstance(ln, dict) and ln.get("url")
    ]

    social_blocks = [
        rb.link_block(
            f"social:{s.get('url')}", str(s.get("url") or ""),
            label=(
                f"@{s['handle']}" if s.get("handle")
                else str(s.get("display_name") or s.get("platform") or "")
            ),
            tag=str(s.get("platform") or ""),
        )
        for s in (digest.get("social_handles") or [])
        if isinstance(s, dict) and s.get("url")
    ]

    photo_blocks = [
        rb.photo_block(
            f"photo:{im.get('url')}", str(im.get("url") or ""),
            caption=str(im.get("source_page") or ""),
            verified=bool(im.get("verified")),
        )
        for im in (digest.get("web_images") or [])
        if isinstance(im, dict) and im.get("url")
    ]

    confirmed = digest.get("confirmed_photos") or []
    confirmed_blocks = (
        [
            rb.photo_grid_block(
                "confirmed_photos",
                [
                    {"url": c.get("image_url"), "caption": c.get("source_title", "")}
                    for c in confirmed if isinstance(c, dict) and c.get("image_url")
                ],
            )
        ]
        if confirmed else []
    )

    sections = [rb.make_section("Summary", summary_blocks)]
    if fact_blocks:
        sections.append(rb.make_section("Facts", fact_blocks))
    if link_blocks:
        sections.append(rb.make_section("Links", link_blocks))
    if social_blocks:
        sections.append(rb.make_section("Social profiles", social_blocks))
    if photo_blocks:
        sections.append(rb.make_section("Photos found online", photo_blocks))
    if confirmed_blocks:
        sections.append(rb.make_section("Confirmed photos", confirmed_blocks))

    report = rb.make_report(f"Web search: {name}", sections)
    created = data.get("created_at")
    updated = data.get("updated_at") or created
    iso = lambda v: v.isoformat() if hasattr(v, "isoformat") else None  # noqa: E731
    return report, iso(created), iso(updated)


# --- Story ---------------------------------------------------------------


def _story_section_blocks(page_id: str, body: str) -> list[dict]:
    sentences = rb.split_sentences(body)
    if not sentences:
        return [rb.section_head_block(f"page:{page_id}:empty", "(empty)")]
    return [
        rb.text_block(f"page:{page_id}:sent:{i}", s) for i, s in enumerate(sentences)
    ]


def story_private_blocks(db, uid: str):
    """The owner's private editor view — every section they can see (not
    ``ai_only``, not ``user_hidden``), private spans included. Mirrors
    ``story.get_story``."""
    data = story.get_story(db, uid)
    sections = [
        rb.make_section(
            sec.get("title") or sec.get("page_id"),
            _story_section_blocks(sec["page_id"], sec.get("body") or ""),
        )
        for sec in data.get("sections") or []
    ]
    return rb.make_report("Your Story", sections), None, None


def story_public_blocks(db, uid: str):
    """The converged public-profile Living Report: what a non-owner sees on
    this person's public profile, AND — for the owner's own "My public
    profile" self-view — the same structured physical-attribute fields that
    screen used to source from a second, parallel read
    (``public_profile._physical_attributes``) rather than this adapter (§
    founder direction 2026-09-20: converge the two into one document).

    An "Attributes" section (built the exact same way as
    :func:`appearance_blocks`'s, from the same ``physical_attributes``
    record via ``physical_attributes.current`` — never re-derived) comes
    first, then Story's own public narrative sections: the same ones
    ``public_profile._public_pages`` shows (``visibility == "public"``,
    private spans stripped via ``story.strip_private_spans``), built from
    ``story.get_story`` instead so each keeps its real ``page_id`` — needed
    so the owner's own tap-to-correct on their public preview resolves to
    the real page (a non-owner's correction attempt 403s regardless,
    before any of this matters — see ``report_hub.py``).

    The physical-attribute fields carry no privacy concept of their own
    (unlike a Story passage) — they're either on the public Living Report
    or they're not filled in; there's nothing to filter by visibility
    here, matching how ``public_profile.build`` always showed all of them
    to the owner."""
    pa_doc = physical_attributes.current(db, uid) or {}
    attr_blocks = _attribute_blocks(pa_doc.get("fields"))
    sections = (
        [rb.make_section("Attributes", attr_blocks)] if attr_blocks else []
    )

    data = story.get_story(db, uid)
    for sec in data.get("sections") or []:
        if sec.get("visibility") != story.VIS_PUBLIC:
            continue
        body = story.strip_private_spans(sec.get("body") or "")
        if not body:
            continue
        sections.append(
            rb.make_section(sec.get("title") or sec.get("page_id"),
                             _story_section_blocks(sec["page_id"], body))
        )
    return rb.make_report("Story", sections), None, None


def story_ai_notes_blocks(db, uid: str):
    """"Ayma's notes" — every wiki page regardless of visibility, including
    ``ai_only`` material, colour-coded by real visibility. Mirrors
    ``story.get_ai_notes`` — confirmed to be a view mode of Story, not a
    separate feature/storage schema."""
    data = story.get_ai_notes(db, uid)
    sections = [
        rb.make_section(
            sec.get("title") or sec.get("page_id"),
            _story_section_blocks(sec["page_id"], sec.get("body") or ""),
        )
        for sec in data.get("sections") or []
    ]
    return rb.make_report("Ayma's Notes", sections), None, None
