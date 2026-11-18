"""Read-only adapters: each existing report producer's REAL current Firestore
shape -> the generic block model (``report_blocks.py``). § generic reports.

Nothing here changes any producer's storage schema — every adapter just reads
through the producer's own existing read function (``appearance.get_report``,
``deep_dive.read_dive``, ``story.get_story`` / ``get_ai_notes``) and reshapes
the result. The two public-profile adapters (``story_public_blocks``, the
owner's own self-view, and ``public_profile_blocks``, another member's) share
ONE builder, ``_public_bullet_sections``: the public-tagged BULLETS of each
story section (``public_profile.public_bullet_sections`` ->
``story_bullets.parse_bullets`` filtered to ``public``), in section order,
rendered as read-only ``fact`` blocks — never the legacy page-body prose
(founder bug, Nov 15). Private/ai_only bullets and sections with no public
bullet are dropped.

Every ``block_id`` is chosen so ``report_hub.py`` can parse it straight back
into whatever the owning producer's correction/dispute function needs, with
NO extra id-lookup table required:

* Appearance  — ``attr:<physical_attributes field>``, or ``face`` / ``body``
  (and ``face:<sub-item>`` / ``body:<sub-item>`` for the score/strengths/
  improvements/recommendations/quick-facts that fold into that one axis —
  see :mod:`appearance`'s own docstring: there's no per-sub-item correction
  slot, only the whole axis). Each section's own source photo(s) —
  ``attr:photo``/``attr:photos``, ``face:photo``, ``body:photo`` (see
  :func:`_source_photo_blocks`) — are never a correction target: they're
  always built ``editable=False``, and ``attr:photo``/``attr:photos`` don't
  even parse as a real ``physical_attributes`` field name.
* Deep-dive   — ``summary`` (and ``summary:sent:<n>`` per sentence),
  ``fact:<fact_id>``, ``social:<url>``, ``photo:<url>`` — exactly
  :mod:`skills.deep_dive_edit`'s own ``target`` scheme — plus
  ``candidate:<candidate_id>`` for a pending reverse-image-search candidate
  (owner-only, § founder: replaces the standalone Photo candidates screen),
  resolved straight to :mod:`reverse_image_search`'s own
  ``confirm_candidate``/``reject_candidate``.
* Story       — the owner's editable views (``story_private`` /
  ``story_ai_notes``) use ``page:<page_id>`` (the section as a whole) and
  ``page:<page_id>:sent:<n>`` (one sentence within it) — resolved back to a
  passage string by re-splitting that page's current body the same way
  (:func:`report_blocks.split_sentences`), so it stays a faithful substring
  for :func:`story.apply_span_action` / ``edit_passage``-style replacement.
  The read-only public views (``story_public`` / ``public_profile``) emit
  ``page:<page_id>:bullet:<n>`` ``fact`` blocks that are ``editable=False``
  and never a correction target (the owner edits via the bullet editor).
* Match        — block ids (``score``, ``explanation:sent:<n>``,
  ``dealbreaker:<n>``, ``dim:<key>``/``dim:<key>:rationale``/
  ``dim:<key>:evidence:<n>``, ``shared:<n>``/``tension:<n>``/``missing:<n>``)
  are report-local only — NONE of them are ever resolved back to a producer
  target, because there is no correction path for this type at all (§
  ``match_blocks``'s own docstring, and ``report_hub.py``'s ``correct()``:
  a match score is algorithmically computed, not user-authored content, so
  every block here is built ``editable=False``).

Each adapter returns ``(report, created_at, updated_at)`` — ``report`` is a
``report_blocks.make_report(...)`` dict; ``created_at``/``updated_at`` are
ISO strings or ``None``, for the generic endpoint's ``meta``. Returns
``(None, None, None)`` when there's nothing to report yet (caller 404s).
"""

from __future__ import annotations

import appearance
import deep_dive
import deep_dive_links
import match_deterministic
import matching_skill
import pair_key
import public_profile
import report_blocks as rb
import reverse_image_search
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


def _axis_status_note(prefix: str, category_status: str) -> str:
    """The add-photo prompt shown in place of a face/body section that didn't
    produce a read — worded by why (§ founder: a skipped or no-eligible axis
    offers "add a photo to unlock" instead of a broken 0-score section)."""
    label = "Face" if prefix == "face" else "Physique"
    if category_status == appearance.CAT_SKIPPED:
        return f"Skipped. Add a photo to unlock your {label} report."
    # no_eligible_photo (or a legacy report with no status map)
    if prefix == "face":
        return "Add a photo that clearly shows your face to get a Face report."
    return "Add a full-body photo to get a Physique report."


def _axis_blocks(prefix: str, axis: dict, category_status: str = "") -> list[dict]:
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
    ``body_report.teaser`` on a freshly computed result. ``category_status``
    (``appearance.CAT_*``) only steers the add-photo prompt's wording when the
    axis has no read."""
    if not isinstance(axis, dict) or axis.get("status"):
        return [
            rb.section_head_block(
                f"{prefix}:status", _axis_status_note(prefix, category_status)
            )
        ]
    return rb.scored_result_blocks(
        axis, id_prefix=prefix, not_usable_text=_AXIS_NOT_USABLE_TEXT[prefix]
    )


def _source_photo_blocks(id_prefix: str, paths) -> list[dict]:
    """The photo(s) that actually fed ``id_prefix``'s read — a
    ``physical_attributes`` field's ``photo_ids``, a Face read's, or a Body
    read's own ``source_photos`` (see this module's and :mod:`appearance`'s
    docstrings) — as ONE :func:`report_blocks.photo_block` when there's
    exactly one path (Face/Body: each is read off a single best photo — see
    :func:`face_report.run`/:func:`body_report.run`), or a single
    :func:`report_blocks.photo_grid_block` carrying every one of them when
    there's more than one (Attributes: the aggregate read can draw on the
    whole grid — § founder: "Include ALL pictures used for the aggregate").

    Each raw Storage path is resolved to a real, directly-loadable download
    URL via :func:`public_profile._photo_url` — the exact same token-download
    scheme the rest of the app already serves photos with (``public_profile.
    _photos``, ``main.py``'s ``admin_media_url``), since a bare Storage path
    is not itself a URL a client's ``Image.network`` can load. A path that
    fails to resolve (deleted photo, missing blob) is silently dropped, never
    shown as a broken thumbnail. Always ``editable=False`` (both block
    helpers' default) — a photo isn't something "corrected" via chat text.

    Each block/grid entry also carries the Storage path as a stable
    ``photo_id`` — the id the shareable report card hides photos by (the
    download ``url`` carries a rotatable token, so it isn't a durable key)."""
    pairs = [
        (str(p), public_profile._photo_url(str(p)))
        for p in (paths or []) if p
    ]
    pairs = [(path, url) for path, url in pairs if url]
    if not pairs:
        return []
    if len(pairs) == 1:
        path, url = pairs[0]
        return [rb.photo_block(f"{id_prefix}:photo", url, photo_id=path)]
    return [
        rb.photo_grid_block(
            f"{id_prefix}:photos",
            [{"url": url, "photo_id": path} for path, url in pairs],
        )
    ]


def _card_photo_pool(data) -> list[str]:
    """The shareable card's photo pool: the Face and Body reads' selected
    ``source_photos`` ONLY, deduped and order-preserved — NEVER the Attributes
    read's whole-grid pool. Mirrors :meth:`AppearanceCardData.fromReport`'s
    face→body card pool so the card-hidden ids a run persists are scoped to
    exactly the photos the card can show. The Attributes read always analyses
    the whole grid (§ founder: "Include ALL pictures used for the aggregate"),
    so :func:`appearance_reads.analysed_photo_ids` includes photos the user
    never selected for any axis; letting those feed the card showed the founder
    photos he never picked (Nov 16 2026; photo-selection class, ref Nov 2 #27).
    The full Attributes photo grid still renders in its own report section — it
    just no longer feeds the card."""
    out: list[str] = []
    for key in ("face", "body"):
        rec = data.get(key) if isinstance(data, dict) else None
        paths = rec.get("source_photos") if isinstance(rec, dict) else None
        for p in paths or []:
            s = str(p or "").strip()
            if s and s not in out:
                out.append(s)
    return out


def _attribute_blocks(record: dict | None) -> list[dict]:
    """``attr:<field>`` attribute blocks for every KNOWN field in a
    ``physical_attributes``-shaped ``record`` (``{field: {value, source,
    confidence}}``) — used by :func:`appearance_blocks`, the only report
    type with an Attributes section (§ founder 2026-09-21: "the attributes
    section should be part of the report that shows face and physique
    analysis. Don't have to duplicate anywhere else" — the converged
    Story-public Living Report's own copy of this section, added earlier
    the same day, was removed again; see :func:`story_public_blocks`)."""
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


def _attribute_field_keys(record: dict | None) -> set[str]:
    """The ``physical_attributes`` field names that actually produced an
    ``attr:<field>`` block (known, non-"unknown" value) — the exact set
    :func:`_attribute_blocks` emits. Used to keep a stat that lives in the
    Attributes section from being re-printed as a Face/Body quick fact."""
    if not isinstance(record, dict):
        return set()
    return {
        field
        for field, rec in record.items()
        if isinstance(rec, dict) and _known(rec.get("value"))
    }


def _drop_colliding_quick_facts(
    axis_blocks: list[dict], attr_field_keys: set[str]
) -> list[dict]:
    """Drop a Face/Body axis's ``<prefix>:quick:<key>`` block whose ``<key>``
    is ALSO a ``physical_attributes`` field already shown in the Attributes
    section, so a stat with one name/value appears ONCE — in Attributes, its
    structured home — not again as a quick fact (Scout NOTE 255 Leg 43:
    ``build`` showed in BOTH Attributes and Body, because the same stat is
    emitted as two separate nodes with different ids — ``attr:build`` and
    ``body:quick:build`` — which the assembler's node-ID dedupe can't catch).
    The Attributes section renders first, so it is the kept home. A non-quick
    block (score, note, finding, photo) is never touched."""
    if not attr_field_keys:
        return axis_blocks
    marker = ":quick:"
    out: list[dict] = []
    for b in axis_blocks:
        bid = str(b.get("block_id") or "")
        if marker in bid and bid.split(marker, 1)[1] in attr_field_keys:
            continue
        out.append(b)
    return out


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
    attr_blocks = attr_blocks + _source_photo_blocks(
        "attr", attrs.get("source_photos") if isinstance(attrs, dict) else None
    )
    # A stat shown in Attributes (e.g. "Build") must not reappear as a Face/Body
    # quick fact — pick one home and show it once (Scout NOTE 255 Leg 43).
    attr_field_keys = _attribute_field_keys(record)

    face = data.get("face") or {}
    body = data.get("body") or {}
    cat = data.get("category_status") or {}
    face_blocks = _drop_colliding_quick_facts(
        _axis_blocks("face", face, str(cat.get("face") or "")), attr_field_keys
    ) + _source_photo_blocks(
        "face", face.get("source_photos") if isinstance(face, dict) else None
    )
    body_blocks = _drop_colliding_quick_facts(
        _axis_blocks("body", body, str(cat.get("body") or "")), attr_field_keys
    ) + _source_photo_blocks(
        "body", body.get("source_photos") if isinstance(body, dict) else None
    )

    sections = [
        rb.make_section("Attributes", attr_blocks),
        rb.make_section("Face", face_blocks),
        rb.make_section("Body", body_blocks),
    ]
    report = rb.make_report("Appearance", sections)
    # The caller's own choice of which analysed photos to keep off the
    # shareable report card (card-only — never touches the full report above,
    # which still shows every photo). Stale ids (a photo since deleted or
    # re-analysed out of the pool) self-heal by intersecting with the live
    # pool. Surfaced in the report meta (`report_hub.get_report`) so the card
    # builder and the exported share image both honour it.
    #
    # The pool here is the CARD pool — the Face+Body selected photos only, the
    # same set `AppearanceCardData.fromReport` draws from — NOT the whole
    # analysed set (`analysed_photo_ids` folds in the Attributes whole-grid
    # photos). Scoping the hidden ids to the card pool keeps the meta aligned
    # with what the card can actually show (founder defect Nov 16 2026).
    pool = _card_photo_pool(data)
    # ``read_card_hidden`` is version-scoped (see ``appearance_reads``): it
    # only returns a list curated against THIS report version, so a stale
    # list from an older run can no longer suppress the current run's
    # photos here. Within the current version the user's curation is
    # honoured exactly — including an explicit removal of the first pool
    # photo; un-hiding it anyway (the 2026-11-02 pool[0] workaround, removed
    # with this fix) resurrected a removed old photo as the card hero on
    # every re-run while the rest of the stale list kept hiding the new
    # photos, which is the 2026-11-08 stale-card bug.
    hidden = [pid for pid in appearance.read_card_hidden(db, uid) if pid in pool]
    report["card_hidden_photos"] = hidden
    created = data.get("created_at")
    return report, created, created


# --- Deep-dive / web-search --------------------------------------------


# A deep-dive digest carries a raw confidence ENUM, never a display string:
# the research-level band (``high``/``medium``/``low``, or ``not_found`` when a
# dive pinned nothing to one person) and the fact-level provenance words
# (``confirmed``/``reported``/``unconfirmed``). The "Confidence" stat must show
# a human label, not the raw token (a report was leaking e.g. "not_found" /
# "medium" verbatim as the stat value). ``not_found`` maps to no label at all —
# the summary already renders "Nothing found yet.", so a "Confidence: Not found"
# stat beside it is noise; it's omitted entirely (see caller).
_CONFIDENCE_LABELS = {
    "high": "High",
    "medium": "Medium",
    "low": "Low",
    "confirmed": "Confirmed",
    "reported": "Reported",
    "unconfirmed": "Unconfirmed",
    "not_found": "",
}


def _confidence_label(raw: str) -> str:
    """Human label for a deep-dive confidence enum. An unmapped value falls
    back to a title-cased version of the token (``some_state`` -> "Some State")
    rather than leaking the raw enum; ``not_found`` (and empty) -> ``""``."""
    key = (raw or "").strip().lower()
    if key in _CONFIDENCE_LABELS:
        return _CONFIDENCE_LABELS[key]
    return key.replace("_", " ").replace("-", " ").title()


def deep_dive_blocks(db, owner_uid: str, report_id: str, *, viewer_uid: str | None = None):
    """Adapter for a stored deep-dive doc (``deep_dive.read_dive``) — works
    identically for a self dive and a dive on someone else; the caller
    resolves ``owner_uid`` first (``deep_dive.report_owner``).

    ``viewer_uid`` — who's actually asking — gates the "Photos to confirm"
    section (§ founder: the standalone Photo candidates screen is being
    deleted; its pending reverse-image-search candidates now live inline
    here instead): pending candidates are the report owner's own
    unconfirmed business, never shown when a non-owner is the one reading
    (``viewer_uid`` not given, or not equal to ``owner_uid``, both omit it
    — the same result a non-owner gets, so a caller that forgets to pass it
    fails closed rather than open)."""
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
    elif summary_text:
        summary_blocks = [
            rb.text_block(f"summary:sent:{i}", sent)
            for i, sent in enumerate(rb.split_sentences(summary_text))
        ]
    conf = _confidence_label(str(digest.get("confidence") or ""))
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

    # Block id is keyed by url (not list index) — same stable-id convention
    # `social_blocks` below already uses — so `deep_dive_edit.remove_deep_dive_
    # item`'s `target.partition(":")` can recover the exact url to dispute
    # (`deep_dive.dispute_link`) without depending on list order surviving a
    # re-fetch. `editable` is left at its default (True): a plain web link is
    # just as correctable/disputable as a social-profile link — both are
    # `digest`-owned deep-dive findings — now that `dispute_link` exists to
    # back it (previously `editable=False` here since removal had no case for
    # "link" at all; that was the real bug, not a reason to leave it inert).
    clean_links, clean_socials = deep_dive_links.clean_links_and_socials(
        digest.get("links"), digest.get("social_handles")
    )
    deep_dive_links.revalidate_in_background(db, owner_uid, report_id, digest)
    link_blocks = [
        rb.link_block(
            f"link:{ln.get('url')}", str(ln.get("url") or ""),
            label=str(ln.get("title") or ln.get("url") or ""),
            tag=str(ln.get("is_them") or ""),
        )
        for ln in clean_links
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
        for s in clean_socials
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

    sections = [rb.make_section("Summary", summary_blocks)] if summary_blocks else []
    if fact_blocks:
        sections.append(rb.make_section("Facts", fact_blocks))
    if social_blocks:
        sections.append(rb.make_section("Social profiles", social_blocks))
    if link_blocks:
        sections.append(rb.make_section("Links", link_blocks))
    if photo_blocks:
        sections.append(rb.make_section("Photos found online", photo_blocks))
    if confirmed_blocks:
        sections.append(rb.make_section("Confirmed photos", confirmed_blocks))

    if viewer_uid is not None and viewer_uid == owner_uid:
        candidate_blocks = [
            rb.photo_block(
                f"candidate:{c['candidate_id']}",
                str(c.get("image_url") or ""),
                caption=str(c.get("source_title") or c.get("source_domain") or ""),
                status="pending",
                editable=True,
            )
            for c in reverse_image_search.list_candidates(db, owner_uid)
            if c.get("candidate_id") and c.get("image_url")
        ]
        if candidate_blocks:
            sections.append(rb.make_section("Photos to confirm", candidate_blocks))

    report = rb.make_report(f"Web search: {name}", sections)
    created = data.get("created_at")
    updated = data.get("updated_at") or created
    iso = lambda v: v.isoformat() if hasattr(v, "isoformat") else None  # noqa: E731
    return report, iso(created), iso(updated)


# --- Story ---------------------------------------------------------------


def _story_section_blocks(page_id: str, body: str) -> list[dict]:
    """Sentence-level ``text`` blocks for one Story section body.

    Goes through ``story.sentence_spans`` rather than ``rb.split_sentences``
    directly — the raw body can carry inline ``{{private}}``/``{{ai_only}}``
    spans (Ayma's Notes always; the owner's own "Story" view for
    ``{{private}}``, since only ``ai_only`` spans are stripped before this is
    called — see ``story._section_dict``), and a Living Report block must
    never show a viewer the literal ``{{...}}`` delimiters. Each piece's
    ``kind`` becomes the block's ``tone`` so the client can style it (gray
    for ``private``, red for ``ai_only``) instead of leaving the raw markup
    in the sentence text (§ founder screenshot, Ayma's notes tab)."""
    spans = story.sentence_spans(body)
    if not spans:
        return [rb.section_head_block(f"page:{page_id}:empty", "(empty)")]
    return [
        rb.text_block(
            f"page:{page_id}:sent:{i}",
            seg["text"],
            tone=seg["kind"] if seg["kind"] != story.VIS_PUBLIC else None,
        )
        for i, seg in enumerate(spans)
    ]


def _narrative_pages(data: dict):
    """``data["sections"]`` minus ``story.REPORT_LINKED_PAGE_IDS`` (the four
    pages — ``face-analysis``/``body-analysis``/``physical-profile``/
    ``web-findings`` — that already have their own dedicated report type,
    ``appearance`` or ``deep_dive``). ``story.py``'s own docstring is explicit
    that these are meant to be shown as "a compact summary card + link"
    instead of their full body, "to avoid showing the same report twice" —
    something no current block type represents, so the Living Report's
    Flutter side keeps its existing bespoke merged-Appearance-card /
    web-findings-interlude widgets for them (fed by the existing
    ``story.get_story``/``get_ai_notes`` reads, not this adapter) rather than
    also emitting them here as plain sentence blocks, which would just
    duplicate that same content in a plainer, report-link-less form."""
    return [
        sec
        for sec in data.get("sections") or []
        if sec.get("page_id") not in story.REPORT_LINKED_PAGE_IDS
    ]


def story_private_blocks(db, uid: str):
    """The owner's private editor view — every section they can see (not
    ``ai_only``, not ``user_hidden``), private spans included, MINUS the
    report-linked pages (see :func:`_narrative_pages`). Mirrors
    ``story.get_story``."""
    data = story.get_story(db, uid)
    sections = [
        rb.make_section(
            sec.get("title") or sec.get("page_id"),
            _story_section_blocks(sec["page_id"], sec.get("body") or ""),
        )
        for sec in _narrative_pages(data)
    ]
    return rb.make_report("Your Story", sections), None, None


def _public_bullet_sections(db, uid: str) -> list[dict]:
    """The public-profile Living Report sections — one ``fact`` (bullet) block
    per public bullet, in canonical section order, sections with no public
    bullet dropped. The ONE shared builder for both public views
    (:func:`story_public_blocks`, the owner's self-view, and
    :func:`public_profile_blocks`, another member's), so they can never
    disagree on what a public profile shows. Every block is ``editable=False``:
    this is a read view of the public profile — the owner edits their story
    through the bullet editor (``/profile/bullets``), never by tapping a
    bullet here.

    Public bullets come from :func:`public_profile.public_bullet_sections`
    (``story_bullets.parse_bullets`` filtered to ``public``), NOT the page
    body split into prose sentences — so no private/ai_only content and no
    legacy paragraph prose ever appears."""
    return [
        rb.make_section(
            sec["title"],
            [
                rb.fact_block(
                    f"page:{sec['page_id']}:bullet:{i}", text, editable=False
                )
                for i, text in enumerate(sec["bullets"])
            ],
        )
        for sec in public_profile.public_bullet_sections(db, uid)
    ]


def story_public_blocks(db, uid: str):
    """The public-profile Living Report: what a non-owner sees on this
    person's public profile, and — for the owner's own "My public profile"
    self-view — the exact same content. No ``viewer_uid`` parameter: this
    adapter's output doesn't depend on who's asking.

    Story's own public content, rendered as BULLETS (not the legacy page-body
    prose, founder bug Nov 15): exactly the ``public``-tagged bullets from each
    section, in section order, sections with no public bullet hidden — see
    :func:`_public_bullet_sections` /
    :func:`public_profile.public_bullet_sections`.

    No Attributes section here (§ founder 2026-09-21, reversing part of a
    2026-09-20 change: "The attributes section should be part of the report
    that shows face and physique analysis. Don't have to duplicate anywhere
    else."). Physical attributes live ONLY in :func:`appearance_blocks` now.
    The per-field ``physical_attributes.public_fields()``/``is_public()``
    visibility flag introduced alongside the old duplicate section is NOT
    removed — it's repurposed: ``explore._passes_filters`` now consults it
    so a private attribute can't be used to search for/filter someone (§
    founder: "Use it for the heuristic search tho")."""
    return rb.make_report("Story", _public_bullet_sections(db, uid)), None, None


def story_ai_notes_blocks(db, uid: str):
    """"Ayma's notes" — every wiki page regardless of visibility, including
    ``ai_only`` material, colour-coded by real visibility, MINUS the
    report-linked pages (see :func:`_narrative_pages`). Mirrors
    ``story.get_ai_notes`` — confirmed to be a view mode of Story, not a
    separate feature/storage schema."""
    data = story.get_ai_notes(db, uid)
    sections = [
        rb.make_section(
            sec.get("title") or sec.get("page_id"),
            _story_section_blocks(sec["page_id"], sec.get("body") or ""),
        )
        for sec in _narrative_pages(data)
    ]
    return rb.make_report("Ayma's Notes", sections), None, None


# --- Public profile (another member's — the Explore tap-through) -----------


def public_profile_blocks(db, owner_uid: str):
    """Adapter for ANOTHER member's public profile (`report_type ==
    "public_profile"`, id = the subject's uid) — what a viewer coming from
    an Explore card sees as the profile's narrative content.

    **Redaction parity is the whole point of this adapter.** The content comes
    from :func:`public_profile.public_bullet_sections` — the public bullets
    of each story section (``visibility == "public"`` after clamping, private
    and ai_only bullets dropped, empty sections dropped), the SAME builder the
    owner's own self-view (:func:`story_public_blocks`) uses, so a viewer and
    the owner can never disagree about what the public profile shows. The
    other gates mirror :func:`public_profile.build` the same way:

    * a deleted user (``deleted_users/{uid}`` tombstone) reads as an EMPTY
      report, matching ``build``'s ``"pages": []`` placeholder — the screen
      still gets its "Deleted user" header from ``/explore/profile``;
    * a nameless/missing profile (``build`` returns ``None`` -> that
      endpoint 404s) returns ``(None, None, None)`` -> the same 404 here;
    * a blocked pair is NOT treated specially — ``/explore/profile`` serves
      ``pages`` regardless of a block either way (the client shows its own
      "You've blocked this person." note in the header), so this does too.

    Every block is ``editable=False`` and ``report_hub.get_report``
    force-clears ``viewer_can_edit`` for this type regardless of who's
    asking (like ``match``): a viewer never corrects someone ELSE's
    profile, and the owner edits their own through the bullet editor
    (``/profile/bullets``), never by tapping a bullet on any public view."""
    owner_uid = (owner_uid or "").strip()
    if not owner_uid:
        return None, None, None
    if db.collection("deleted_users").document(owner_uid).get().exists:
        return rb.make_report("Profile", []), None, None
    prof = (
        db.collection("users")
        .document(owner_uid)
        .collection("profile")
        .document("main")
        .get()
        .to_dict()
    ) or {}
    name = str(prof.get("name") or "").strip()
    if not name:
        return None, None, None
    return rb.make_report(name, _public_bullet_sections(db, owner_uid)), None, None


# --- Match -----------------------------------------------------------------


def _confidence_band(score_confidence) -> str:
    """``"High"``/``"Medium"``/``"Low"`` from a 0..1 ``score_confidence`` —
    the exact thresholds ``MatchReport.confidenceBand`` uses client-side
    (``ayma_flutter/lib/services/api_client.dart``), kept in step even
    though that client-side field is no longer rendered anywhere itself.
    This band feeds ONLY the top-line "Match score" ``stat`` block's
    ``basis`` text (e.g. "Low confidence") below — the single place a match's
    score and confidence band are shown at all, after a duplication bug was
    fixed where `match_report_screen.dart` ALSO rendered a separate bespoke
    confidence chip. See the GUARDRAIL in `living_report_view.dart`'s file
    doc and that screen's own doc comment before adding a second render of
    this anywhere."""
    if score_confidence is None:
        return ""
    try:
        c = float(score_confidence)
    except (TypeError, ValueError):
        return ""
    if c >= 0.66:
        return "High"
    if c >= 0.4:
        return "Medium"
    return "Low"


def match_blocks(db, viewer_uid: str, match_id: str):
    """Adapter for one scored ``matches/{match_id}`` doc (§ generic reports
    — Match). ``matching_skill.read_match`` is the one place this reads the
    persisted doc's raw shape; this function only reshapes it into blocks.

    **Read/write model — a deliberate departure from every other report
    type here.** Every other adapter has one clear owner (a single subject
    uid) who may both read AND correct their own report. A match is
    inherently about TWO people, and a match score is ALGORITHMICALLY
    COMPUTED by ``matching_skill.score_pair`` — it is not user-authored
    content the way a Story passage or an Appearance finding is, so there is
    nothing meaningful to "correct" via a stated-value override the way
    ``appearance.correct_finding``/``deep_dive.correct_finding`` work. So:
    BOTH participants may read (enforced in ``report_hub.resolve_owner`` —
    ``viewer_uid`` must already be one of the two uids encoded in
    ``match_id`` by the time this is ever called, or a caller isn't allowed
    to have gotten this far at all), and NEITHER may "correct" it —
    ``report_hub.get_report`` never sets ``viewer_can_edit`` for this report
    type regardless of participancy, and ``report_hub.correct`` answers any
    direct write attempt with an explicit "nothing to correct here" reply
    rather than routing to a real mutation. Every block below is therefore
    built ``editable=False`` — consistent with that, not merely decorative.
    A future "this doesn't sound right" dispute-style feedback loop into
    re-scoring would be a reasonable thing to add later; this adapter
    intentionally does not build one now (§ founder scope: display only).

    Returns ``(None, None, None)`` when ``match_id`` isn't a valid pair key,
    or the pair has never been scored — both 404 via ``report_hub``."""
    try:
        a, b = pair_key.uids_from_pair_key(match_id)
    except ValueError:
        return None, None, None
    other = b if viewer_uid == a else a

    data = matching_skill.read_match(db, match_id)
    if data is None:
        return None, None, None

    other_name = deep_dive.profile_full_name(db, other) or "them"

    top_blocks: list[dict] = []
    score = data.get("score")
    if score is not None:
        band = _confidence_band(data.get("score_confidence"))
        top_blocks.append(
            rb.stat_block(
                "score", "Match score", f"{round(float(score) * 100)}%",
                basis=f"{band} confidence" if band else "",
                editable=False,
            )
        )
    explanation = str(
        (data.get("user_explanation") or {}).get(viewer_uid, "")
    ).strip()
    top_blocks.extend(
        rb.text_block(f"explanation:sent:{i}", sent, editable=False)
        for i, sent in enumerate(rb.split_sentences(explanation))
    )
    if not top_blocks:
        top_blocks.append(
            rb.section_head_block(
                "score:status",
                "This match hasn't been scored yet.",
            )
        )
    sections = [rb.make_section("Match", top_blocks)]

    gate_failures = [
        g for g in (data.get("gate_failures") or [])
        if isinstance(g, dict) and str(g.get("reason") or "").strip()
    ]
    if gate_failures:
        # A HARD dealbreaker (gender/orientation, partner age, location) forces
        # the score to exactly 0% (§5.4). When that's why, title the section
        # "Why this is 0%" and open with a plain sentence so the zero never
        # reads as an unexplained glitch, then list each specific reason.
        # Soft gate failures (which only cap the score, not zero it) keep the
        # plain "Dealbreakers" heading.
        hard = match_deterministic.is_hard_dealbreaker(gate_failures)
        gate_blocks: list[dict] = []
        if hard:
            lead = (
                "This is a 0% match because of a hard dealbreaker:"
                if len(gate_failures) == 1
                else "This is a 0% match because of hard dealbreakers:"
            )
            gate_blocks.append(
                rb.text_block("dealbreaker:lead", lead, editable=False)
            )
        gate_blocks.extend(
            rb.fact_block(
                f"dealbreaker:{i}", str(g.get("reason") or ""),
                tag=str(g.get("label") or ""), editable=False,
            )
            for i, g in enumerate(gate_failures)
        )
        sections.append(
            rb.make_section(
                "Why this is 0%" if hard else "Dealbreakers", gate_blocks
            )
        )

    method = str(data.get("method") or "").strip()
    if method:
        sections.append(
            rb.make_section(
                "How this score is built",
                [rb.text_block("method", method, editable=False)],
            )
        )

    for dim in data.get("dimensions") or []:
        # A dimension `matching_skill._merge_dimensions` couldn't ground in
        # real evidence from both people is simply never IN this list (it's
        # named in `omitted_dimensions` instead, folded into `missing`
        # below) — today's fabrication fix (§ ARCHITECTURE.md, "match report
        # fabricating claims on thin profiles"). Nothing extra needed here to
        # honour that: not iterating a dimension that was never handed to us
        # IS "producing no blocks for it".
        if not isinstance(dim, dict):
            continue
        key = str(dim.get("key") or "")
        label = str(dim.get("label") or "").strip()
        if not key or not label:
            continue
        dim_blocks: list[dict] = []
        weight = dim.get("weight")
        try:
            weight_pct = round(float(weight) * 100) if weight is not None else None
        except (TypeError, ValueError):
            weight_pct = None
        measured = "measured" if str(dim.get("source") or "") == "structured" else "estimated"
        basis = " · ".join(
            p for p in (
                f"{weight_pct}% weight" if weight_pct is not None else "", measured,
            ) if p
        )
        dim_blocks.append(
            rb.stat_block(f"dim:{key}", label, dim.get("score"), basis=basis, editable=False)
        )
        rationale = str(dim.get("rationale") or "").strip()
        if rationale:
            dim_blocks.append(
                rb.fact_block(
                    f"dim:{key}:rationale", rationale, tag="rationale",
                    confidence=str(dim.get("confidence") or ""), editable=False,
                )
            )
        for i, ev in enumerate(dim.get("evidence") or []):
            ev = str(ev).strip()
            if ev:
                dim_blocks.append(
                    rb.fact_block(f"dim:{key}:evidence:{i}", ev, tag="evidence", editable=False)
                )
        sections.append(rb.make_section(label, dim_blocks))

    def _list_section(heading: str, values, id_prefix: str) -> None:
        blocks = [
            rb.fact_block(f"{id_prefix}:{i}", str(v).strip(), editable=False)
            for i, v in enumerate(values or [])
            if str(v).strip()
        ]
        if blocks:
            sections.append(rb.make_section(heading, blocks))

    _list_section("What lines up", data.get("shared"), "shared")
    _list_section("Where you differ", data.get("tensions"), "tension")
    _list_section("What'd sharpen this score", data.get("missing"), "missing")

    report = rb.make_report(f"Match with {other_name}", sections)
    updated = data.get("updated_at")
    iso = lambda v: v.isoformat() if hasattr(v, "isoformat") else None  # noqa: E731
    return report, iso(updated), iso(updated)
