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
* Story       — ``page:<page_id>`` (the section as a whole) and
  ``page:<page_id>:sent:<n>`` (one sentence within it) — resolved back to a
  passage string by re-splitting that page's current body the same way
  (:func:`report_blocks.split_sentences`), so it stays a faithful substring
  for :func:`story.apply_span_action` / ``edit_passage``-style replacement.
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
import matching_skill
import pair_key
import physical_attributes
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
    helpers' default) — a photo isn't something "corrected" via chat text."""
    urls = [
        u for u in (
            public_profile._photo_url(str(p)) for p in (paths or []) if p
        )
        if u
    ]
    if not urls:
        return []
    if len(urls) == 1:
        return [rb.photo_block(f"{id_prefix}:photo", urls[0])]
    return [
        rb.photo_grid_block(f"{id_prefix}:photos", [{"url": u} for u in urls])
    ]


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
    attr_blocks = attr_blocks + _source_photo_blocks(
        "attr", attrs.get("source_photos") if isinstance(attrs, dict) else None
    )

    face = data.get("face") or {}
    body = data.get("body") or {}
    face_blocks = _axis_blocks("face", face) + _source_photo_blocks(
        "face", face.get("source_photos") if isinstance(face, dict) else None
    )
    body_blocks = _axis_blocks("body", body) + _source_photo_blocks(
        "body", body.get("source_photos") if isinstance(body, dict) else None
    )

    sections = [
        rb.make_section("Attributes", attr_blocks),
        rb.make_section("Face", face_blocks),
        rb.make_section("Body", body_blocks),
    ]
    report = rb.make_report("Appearance", sections)
    created = data.get("created_at")
    return report, created, created


# --- Deep-dive / web-search --------------------------------------------


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

    # Block id is keyed by url (not list index) — same stable-id convention
    # `social_blocks` below already uses — so `deep_dive_edit.remove_deep_dive_
    # item`'s `target.partition(":")` can recover the exact url to dispute
    # (`deep_dive.dispute_link`) without depending on list order surviving a
    # re-fetch. `editable` is left at its default (True): a plain web link is
    # just as correctable/disputable as a social-profile link — both are
    # `digest`-owned deep-dive findings — now that `dispute_link` exists to
    # back it (previously `editable=False` here since removal had no case for
    # "link" at all; that was the real bug, not a reason to leave it inert).
    link_blocks = [
        rb.link_block(
            f"link:{ln.get('url')}", str(ln.get("url") or ""),
            label=str(ln.get("title") or ln.get("url") or ""),
            tag=str(ln.get("is_them") or ""),
        )
        for ln in (digest.get("links") or [])
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
    sentences = rb.split_sentences(body)
    if not sentences:
        return [rb.section_head_block(f"page:{page_id}:empty", "(empty)")]
    return [
        rb.text_block(f"page:{page_id}:sent:{i}", s) for i, s in enumerate(sentences)
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
    for sec in _narrative_pages(data):
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


# --- Match -----------------------------------------------------------------


def _confidence_band(score_confidence) -> str:
    """``"High"``/``"Medium"``/``"Low"`` from a 0..1 ``score_confidence`` —
    the exact thresholds ``MatchReport.confidenceBand`` uses client-side
    (``ayma_flutter/lib/services/api_client.dart``), kept in step so the
    label shown here never disagrees with the bespoke confidence chip the
    match screen still renders itself (§ ``match_report_screen.dart``: the
    two-person header and Confidence badge stay screen chrome, not blocks —
    see that screen's own doc comment)."""
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
            rb.section_head_block("score:status", "This match hasn't been scored yet.")
        )
    sections = [rb.make_section("Match", top_blocks)]

    gate_failures = [
        g for g in (data.get("gate_failures") or [])
        if isinstance(g, dict) and str(g.get("reason") or "").strip()
    ]
    if gate_failures:
        sections.append(
            rb.make_section(
                "Dealbreakers",
                [
                    rb.fact_block(
                        f"dealbreaker:{i}", str(g.get("reason") or ""),
                        tag=str(g.get("label") or ""), editable=False,
                    )
                    for i, g in enumerate(gate_failures)
                ],
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
