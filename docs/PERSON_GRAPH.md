# The Person Graph — implementation status

One graph per user is the single source of truth for who a person is. Story,
public profile, reports, matching, sims and completeness all become **renders
of the graph** rather than separately-maintained stores. Design (settled with
the founder, Nov 15 2026): `~/workspace/ayma-inbox/person-graph-design-plan-2026-11-15.md`;
100-question level mapping: `…/node-level-mapping-2026-11-15.md`.

Built on branch `feature/person-graph` (off staging), in phases. Each phase
that switches a consumer deletes the path it replaces in the same change.

## Phase 1 — schema + seed v7 ✅ (this commit)

- **`question_tree.json` → v7 (the seed).** `level` (1/2/3) added to every node;
  `tier` retained for back-compat until completeness/matching switch to levels.
  - Level 1 = the 9 pre-boarding form items. Levels 2+ are learned by Ayma in
    conversation (no forms). Original-100 level split: L1=9, L2=41, L3=50.
  - Four Values promotions L3→L2 (`religiosity_importance`,
    `partner_religion_requirement`, `political_orientation`,
    `politics_partner_alignment`).
  - Section moves: `education_level` → Career; `financial_comingling` → Finances.
  - **Private Context removed** (15 sections); its 2 nodes (`intimacy_pace`,
    `physical_preferences_narrative`) remap to Relationships as `ayma_only`.
  - Four Nov-15 About-Me additions at level 2 (`marital_status`,
    `languages_spoken`, `height`, `weight`) — conversational, so legacy `tier`
    is `deep` to avoid blocking the old form-based core gate.
  - Per-section `default_visibility` (Finances, Relationships → private;
    others → public); per-node common-sense visibility where a node is
    sensitive (bodies never default public).
- **`person_graph.py` — schema + merge.** Pydantic models (`SeedNode`,
  `OverlayNode`, `GraphNode`, `Link`, `HistoryEntry`, `ChildBullet`) and the
  enums (`Visibility`, `NodeState`, `Provenance`, `StrictLinkType`). The
  effective graph a reader sees is `seed ⊕ overlay`:
  - `seed()` builds the shared template from the v7 tree (cached).
  - `effective_graph(overlay, intent=…)` merges per-user divergences over the
    seed, restricted to the user's branch; emergent (overlay-only) nodes
    included, off-branch nodes excluded.
  - `validate_overlay()` validates at the write boundary (the store/tools in
    Phase 2 call it) so a malformed node can never be stored.
- **Tests:** `tests/test_person_graph.py` (17) + the touched tree/completeness
  assertions. No user-facing change; no Firestore I/O yet.

## Phase 2 — graph store + the 5 tools + registry ✅

- **`person_graph_store.py`.** Owns the per-user overlay document
  `users/{uid}/graph/main` (only divergences from the seed) and the five write
  tools (design §8.2), each validated through `person_graph.validate_overlay`
  at the boundary:
  - `set_answer` — records an answer, sets state/provenance; a changed answer
    retires the old one to an Ayma-only **history** record on the same node (§2.5).
  - `set_weight` — personal weight (relative normalization stays a score-time
    concern).
  - `set_visibility` — public / private / ayma_only.
  - `add_node` — emergent node under a parent (level = parent + 1, homed in the
    parent's section, private by default); nests under emergent parents too.
  - `query_nodes` — pulls a subgraph by section / level / state / min_weight /
    emergent, in section-then-level order, instead of loading the whole person.
  - `effective(db, uid)` = `seed ⊕ overlay` for the user's stored branch.
- **Relationship-type registry** (global, `graph_registry/relationship_types`):
  the five strict types always present; `register_link_type` mints a free-form
  type once and reuses it (synonym-drift guard, §2.4); strict names can't be
  redefined.
- **Tests:** `tests/test_person_graph_store.py` (14) green. Not yet wired into
  the live LLM tool dispatch — these are the validated primitives the
  consumer-switch phase binds as tools. No user-facing change.

## Phase 3 — renders ✅

- **`person_graph_render.py`.** Story, public profile and persona prose become
  renders of the graph (design §1, §8.1), emitting the same shapes today's
  wiki-backed renders produce so consumers can switch without changing their own
  output contract:
  - `story_sections(graph)` → Your Story (public + private; Ayma-only never
    shown) — same shape as `profile_bullets.get_bullets`.
  - `public_sections(graph)` → public bullets only, empty sections dropped —
    same shape as `public_profile.public_bullet_sections`.
  - `persona_prose(graph, …)` → prose for persona / sims / match report; owner
    (public + private), viewer (`public_only`), or Ayma-grounding
    (`include_ayma_only`).
  - Narrative answers render verbatim; structured answers are prompt-labelled;
    children render as their own bullets with independent visibility. The
    graph's `ayma_only` maps to the story model's `ai_only` at this boundary.
  - **A narrative node stores its statement ONCE** (founder build 2493): an
    emergent narrative/loose fact has no question distinct from its statement, so
    the write paths keep its `prompt` (header/label) EMPTY — the statement lives
    in `answer` only — rather than duplicating it into both fields (which made a
    node context card print the sentence twice). `person_graph_store.
    _prompt_without_restatement` blanks a `prompt` that normalize-equals the
    `answer` (reuses `person_graph_index.normalize_text`) for every emergent
    narrative writer (`add_node`, `add_loose_node`, `upsert_fact_node`,
    `replace_section_bullets`); a genuinely distinct label (a standard field's
    "Age", an assessment group's "Ayma's assessment — …") is preserved.
    `merge_node` preserves an explicit empty prompt while still synthesizing one
    for a prompt that is wholly missing (`None`, the legacy partial-write guard).
    Any surface that renders a node's header PLUS its body (the Ask Ayma context
    card, the graph inspector detail, the visualiser node card) additionally
    collapses to showing it once when the two normalize-equal, so pre-existing
    duplicated nodes also render clean without a backfill (`story_node.
    headerRestatesBody`).
- **Tests:** `tests/test_person_graph_render.py` (7) green. Byte-level parity
  with the live wiki is pinned per account in Phase 4. Additive — old render
  paths stay live until the consumer-switch phase.

## Phase 4 — migration ✅

- **`person_graph_migrate.py`.** One-time ingest of what a user already has into
  the overlay (design §9), idempotent (emergent ids derived from their source,
  so re-running overwrites rather than duplicating) and non-destructive (no
  source store is deleted — that is the cutover phase):
  - `migrate_questionnaire` → answers onto matching seed nodes (stated/inferred
    provenance, confidence from the doc).
  - `migrate_profile` → the 5 derivable level-1 nodes, `imported`; wins over a
    questionnaire doc for the same node (completeness precedence).
  - `migrate_wiki` → each public/private story bullet becomes an emergent node
    homed in its section, visibility kept, `imported`; unplaceable → Little Extras.
  - `migrate_assessment` → Ayma-only passages become `ayma_only` emergent nodes,
    `inferred`.
  - `migrate_user(db, uid, write=…)` composes and (optionally) persists via the
    store, validated at the boundary.
- **Tests:** `tests/test_person_graph_migrate.py` (6) green, incl. end-to-end
  migrate→write→render and idempotency. Real-account byte-parity against the
  live wiki is Astro's post-merge verification.

## Phase 6a — completeness tiers ✅ (additive)

- **`person_graph_completeness.py`.** Completeness becomes a game-like tier over
  the graph (design §6): **Surface → Core → Deep → Uncharted**.
  `compute_tier(graph)` returns the tier, `matchable` (≥ Core — nobody matches
  below Core), per-level answered/total/pct against the **fixed seed only**
  (emergent nodes never enter a denominator, killing the live 81↔86% wobble),
  and the Uncharted axes (emergent depth + breadth). Additive read; not yet
  wired into the live completeness endpoint (that is the consumer-switch phase).
- **Tests:** `tests/test_person_graph_completeness.py` (6) green.

## Pre-switch fixes — Scout batch-2449 verification blockers

The merged foundation verified faithful (202 nodes, idempotent, non-destructive,
0 bullets missing) but surfaced structured questionnaire answers as bullets for
the first time, which the live profile/story did not show. Fixed before any
consumer switch:

1. **Public expansion (blocker 1).** Structured personal facts default
   **private** (owner sees them in Your Story, never public) unless on the
   **founder-approved public allow-list** (`_PUBLIC_ALLOWLIST`, Nov 15 2026):
   **age** (DOB rendered as age only — the raw birthdate never renders),
   **gender**, **location**, **interested-in**, **relationship intent**. (The
   open "What I'm Looking For" description node joins the allow-list when the
   looking-for level-2 flow adds it in 6b.) Everything else private; wiki/story
   prose keeps its own page visibility (parity preserved).
2. **Rendering (blocker 2).** Dates render as a date (not a raw timestamp),
   booleans as Yes/No.
3. **Meta-answers (blocker 3).** `skipped` / `addressed` / `n/a` placeholders are
   filtered at migration and render — never a bullet.
4. **Health page (blocker 4).** `migrate_wiki` skips non-canonical page_types,
   matching the live story (which excludes the health/sensitive page); no story
   behaviour change for the owner.
5. **Dedupe (blocker 5).** Done — duplicate-page bullets collapse to one node,
   more-private tag wins.

Bullet ORDER parity (graph sorts section/level/id vs wiki authoring order) is
cosmetic per the founder; deferred.

**Re-verification owed on the founder account before the switch.**

## Phases 5 / 6b — in progress (verification GREEN, Nov 15 2026)

Founder re-verified migration against real accounts (demo-test1 re-migrated
with `--replace`: 170 nodes, 6 duplicates collapsed, 0 public-render
violations; founder account 194 nodes / 37 public bullets, all allow-list or
already-public; DOB as age only; the private health page has zero copies in the
graph and zero in the public render; old stores untouched by hash). On that
green, Phases 5/6b proceed. **Phase 7 deletion stays gated on the founder's
post-switch re-verification.**

The switch is a **flag-gated read boundary**: graph-backed reads/renders feed
the existing scorer, sims and report with identical math and output; flags
default **off**, so staging behaviour is unchanged until the founder flips and
verifies each step. Nothing irreversible (no deletes) in Phases 5/6b.

- **5a — graph tools wired into live LLM dispatch. DONE.** The five tools
  (`pg_set_answer`, `pg_set_weight`, `pg_set_visibility`, `pg_add_node`,
  `pg_query_nodes` — `skills/person_graph_tools.py`, design §8.2) are registered
  in `skills/__init__` for both text and voice, gated behind
  `PERSON_GRAPH_TOOLS` (`config.py`, default off). They write the per-user graph
  overlay, which nothing reads in production until the reads flag flips, so
  enabling them alone is additive/safe. Validation at the store boundary; weight
  top-band promotion is never silent (description tells Ayma to confirm out loud
  per §4.4/§11 Q3).
- **5b — graph-backed reads (scorer / sims / match report), behind
  `PERSON_GRAPH_READS` (`config.py`, default off).**
  - *Scorer — DONE.* `matching_skill._load_user` reads a graph-derived
    questionnaire store (`person_graph_source.load_user`) instead of the
    `questionnaire` subcollection: `qstore = {node_id: {"value": answer}}` from
    the graph's answered seed nodes, and the profile keeps its gate/identity
    fields but drops the stale `qz_*` mirrors so the graph is authoritative. The
    scorer's `_typed_value` reads the same shape, so the math is unchanged — a
    full-node parity test proves old-read == graph-read on a migrated account.
    Seed weights unchanged (per-user weights are 5c).
  - *Match-report narrative — DONE.* `matching_skill.score_pair` feeds each
    user's `person_graph_source.persona(db, uid)` (public + private story prose,
    Ayma-only excluded) in place of `read_wiki_context`; Ayma's assessment stays
    fed separately via its digest, exactly as before. Visibility-boundary test:
    the report input excludes Ayma-only nodes; `include_ayma_only` folds them in
    only for Ayma's own grounding.
  - *Sims persona — DONE.* `practice_core` builds `PersonaContext.pages` from
    the graph (`person_graph_source.persona_pages` → `render.persona_sections`):
    the MATCH persona uses the target's PUBLIC nodes only (and
    `public_profile.build` still enforces the viewer→target permission boundary
    — block / deleted / self / AI-avatar opt-out — so the switch only swaps page
    *content*), the SELF persona folds in every visibility including Ayma-only
    (the documented own-agent asymmetry; the disclosure filter still guards the
    chat). Style exemplars unchanged. Visibility test: public persona excludes
    private + Ayma-only; self persona includes both. Sims suites green (98).

  - *Your Story read — DONE (NOTE 230).* `profile_bullets.get_bullets` (the
    `/profile/bullets` editor read, and `profile_graph.get_graph`/`public_graph`
    through it) reads the graph via `person_graph_source.story_bullets` →
    `render.story_sections` when `PERSON_GRAPH_READS` is on, instead of the
    frozen `wiki_pages` store. This was the missing read: with the flag on, wiki
    ingest is gated (NOTE 227), so a volunteered fact lands only in the graph as
    a loose emergent node in `misc` / Little Extras (NOTE 228) — the wiki read
    could never surface it; the graph render does. Same output shape, so the
    editor is unchanged; `None` on a failed graph read falls back to the wiki
    (never a blank story). **Still the frozen-wiki path (Phase-6b story
    write-back, not done):** editing/creating a bullet (`save_bullets` /
    `create_bullet_section`) still writes `wiki_pages`, so an edit won't
    round-trip into this graph-backed read until the write half lands.

  All four 5b read switches share `PERSON_GRAPH_READS` — flip it only after the
  graph is migrated for the account under test; flag-off is today's reads
  exactly across scorer, report, sims and Your Story.

  **Every process that reads or writes must carry the flags (NOTE 230).** The
  flags are env-only and set per service, so they must be set identically on
  **both** `ayma-api-staging` (chat + HTTP) **and** the hosted LiveKit voice
  worker `ayma-lk-stg` (`agent.py`; its session-end `post_turn.persist_and_ingest
  → wiki_ingest.ingest` and its `remember` tool run the same gate). If the worker
  lacks `PERSON_GRAPH_READS`, its §9.5 gate can't fire and a voice session
  dual-writes the frozen wiki — the split-brain, reappearing on the lagging
  surface. `scripts/deploy-agent-livekit.sh` now sets both for staging; keep the
  two services in lock-step.
- **5c — per-user emergent gates (§4.3). DONE.** The gate set becomes the fixed
  gates **plus** any node a user raised to the top of their weight budget
  (`weight ≥ _TOP_BAND_WEIGHT = 4.5` on the 0–5 tool scale, read from the
  OVERLAY so only user-set weights count — `person_graph_source.personal_gate_ids`).
  `score_structured` takes `personal_gates_a/b`; each fires a gate failure when
  the pair clashes on that node (`_node_subscore < 0.5`) with data on both
  sides — missing data never fails, exactly like the fixed gates — and caps the
  score like any soft gate (not a score→0 dealbreaker). Deduped against the
  fixed gates and each other. **Scope:** deterministic personal gates apply to
  **seed** nodes only (both users share the id, so the clash is comparable); a
  gate on a purely emergent node is a semantic match handled by the LLM report
  layer. `matching_skill.score_pair` passes the gates only when
  `PERSON_GRAPH_READS` is on; off → empty → today's fixed-gate behaviour exactly
  (parity test). The top-band threshold and "a confirmed `pg_set_weight` to the
  top band = a personal gate" semantic are the founder-verifiable knobs.
  - *Confirmation (§4.4/§11 Q3):* the gate derives from a top-band weight, which
    `pg_set_weight`'s contract only writes after Ayma confirms out loud — so no
    gate is minted from an unconfirmed spike.
  - *Like-for-like levels (§5.4):* partially satisfied today (a gate/dimension
    scores only when both users answered the node); fuller level-banding of
    graded dimensions is deferred.
- **6b — guided flow by level; the open "What I'm Looking For" node; reports-as-views
  + image nodes.**
  - *Open "What I'm looking for" node — DONE.* Seed bumped to **v8**: a level-2
    narrative node `looking_for_description` in the `looking_for` section
    (`question_tree.json`), the open template field §5.2 item 5 names. Added to
    `_PUBLIC_ALLOWLIST` (`person_graph.py`) so it defaults **public** — a
    standard user-authored dating-profile field, founder-approved alongside the
    identity set; the user can still make it private per node. Renders in the
    public profile when answered; migration carries it like any seed node.
  - *Guided flow by level — DONE.* When `PERSON_GRAPH_READS` is on, Ayma's
    guided order (`completeness._next` / `_node_unlocked`) becomes breadth-first
    by `level` (§5.2): `_guided_level_ceiling` is the shallowest still-open
    level, and she works that level across ALL sections (ranked by weight within
    the level) before any deeper one — replacing the depth-first section-core
    walk. The routing node still leads; the **user-facing** flow is untouched
    (`_node_open_to_user` is never level-gated — §5.3, no locks for the user).
    Flag off = today's section walk exactly.
  - *Image nodes (foundation) — DONE.* "Images are nodes" (design §6): an
    `answer_type == "image"` emergent node holds the Firebase Storage link
    (`answer`) plus Ayma's read of the image (`image_read`, new field on
    Overlay/GraphNode), its own visibility, and typed links to the fact nodes it
    belongs to (§2.4). `person_graph_store.add_image_node` is the validated
    primitive; renders show the **read**, never the raw URL (public render drops
    an Ayma-only image; Ayma's grounding sees it). Tests cover create / render /
    visibility / links / bad input.
    - *Image delete = retention, not erase (founder rule Nov 18 2026).* Deleting
      an IMAGE node no longer hard-deletes it. Both delete paths — the Your Story
      Photos sheet (`POST /story/photo/delete`) and the node-chat / visualiser
      Delete (`POST /profile/graph/node/{id}/delete`) — route through
      `person_graph_store.retire_image_or_delete`, which **moves an image node to
      `ayma_only`** (node + `image_read` + provenance kept) instead of deleting
      it; every OTHER node kind still hard-deletes with its subtree
      (`delete_node_with_descendants`), unchanged. The retained image leaves the
      story / profile / public surfaces but stays findable in the owner's
      **Ayma-only Photos view** (the dev-flag-gated "Ayma's Notes" screen, under
      an `AYMA-ONLY` group). The retained image is kept off every body surface at
      TWO layers: the owner Photos **strip** drops `ayma_only` (client
      `_livePhotos`), AND `person_graph_tree.node_tree` drops an `ayma_only`
      IMAGE node from the **story / public body render** even when the dev flag
      keeps `ayma_only` TEXT inferences visible there (`hide_ayma_only_images`,
      Scout NOTE 256) — a photo_carousel image node otherwise leaked into the
      Your Story body because the dev flag (`graph_show_ai_only`, kept ON) put
      every `ayma_only` node, images included, on the owner story surface.
      (Privacy P0: `ayma_only` is never on the story body, public or a shared
      surface.) **Owner-visibility split (Scout NOTE 256, build 2509):** the two
      facets are independent — hidden from the body, but the OWNER must still
      find a retained image. The owner Photos path (`/story/photos` →
      `image_nodes_for_view`) already returns `ayma_only` (only `public_only`
      drops it); the `node_tree` body filter is a separate path and does not
      touch it. The Story **Photos section** shows the labelled `AYMA-ONLY`
      group only when the Developer panel is unlocked
      (`DevPanelSession.unlocked`, `story_editor_screen.dart`) — sourced from the
      full photo list, not `_livePhotos`; Ayma's Notes always surfaces it. A
      locked/normal user never sees the group. *Before the retention change the delete was a hard erase —
      `delete_nodes` removed the overlay node with no copy, and nothing in the
      graph, subcollections or any history/audit store kept the bytes or storage
      ref, so a deleted Ayma-only image was unrecoverable.* **Follow-up (not done):** the live wiring —
    binding a sent image's uploaded URL and Ayma minting the node mid-chat — and
    migrating existing chat images; this lands the primitive the way the 5 write
    tools landed before their consumer wiring.
  - *Reports-as-views.* NEXT — appearance + web-search findings become graph
    nodes; report screens render from them (design §6, reports settled Nov 15).
    Two halves: (a) a findings→nodes **migration** (additive, testable, like
    `migrate_wiki`/`migrate_assessment`); (b) a **render-from-nodes** switch of
    the live report screens (the riskier half — flag-gate it and the founder
    verifies the report screens before flipping). Build notes (data model as of
    Nov 15, mapped from the report subsystems):
    - *Web-search / deep-dive:* one persistent doc `users/{uid}/deep_dives/{report_id}`
      (`deep_dive.read_dive`, adapter `report_adapters.deep_dive_blocks`). Each
      **fact** = `{claim, category, source_url, source_index, confidence}`; its
      stable id is `deep_dive.fact_id()` = `sha1("<category>|<claim>")[:12]` —
      reuse as the node id (`emergent.webfind.<fact_id>`). Facts "carry their
      link" (`source_url`) → a node needs a source-url field (add one, like
      `image_read`). Also `links` / `social_handles` (`{platform,handle,url}`),
      `summary`, `caveats`, `confidence`. Web findings default **private**.
    - *Appearance:* `users/{uid}/appearance_reports/current` (face + body +
      attributes) + `users/{uid}/physical_attributes/current`
      (`record[field] = {value, source, confidence, note, photo_ids}`), per-field
      visibility in a sibling `physical_attributes/visibility` doc. Adapter
      `report_adapters.appearance_blocks`. Attribute node id `emergent.appearance.<field>`;
      provenance `inferred` (photo) / `stated`; appearance is sensitive →
      private/ayma_only. Face/body scored axes stay whole (no per-sub-item node).
    - *Bridge:* the four stub wiki pages `face-analysis`/`body-analysis`/
      `physical-profile`/`web-findings` (`story_common.REPORT_LINKED_PAGE_IDS`)
      carry a `report_id`; `migrate_wiki` already skips `REPORT_LINKED_PAGE_IDS`
      (so reports aren't double-homed). `ai_assessment` already migrates (its
      `ayma-assessment` page → ayma_only inferred nodes).
    - *Adapters* emit `{title, sections:[{heading, blocks}]}`; block types
      text/fact/attribute/photo/link/stat (`report_blocks.py`). Render-from-nodes
      must reproduce these block shapes from the migrated nodes.
  - *Render-from-nodes switch (2o P0–P3) — SHIPPED.* `report_tree.report_node_tree`
    (`GET /report/{type}/{id}/tree`) converts any report's blocks to a
    Node-Visualiser node tree (SCORE/STAT, CONFIDENCE, CANDIDATE, LINK, image,
    text), reusing `report_hub.get_report` so every type keeps its owner/
    permission checks (match stays owner-only + read-only; a non-participant's
    tree 404s, never the score). The report screens render that tree through the
    shared `GraphTreeView`: **appearance + deep-dive (P2)** and now **match
    (P3)** — `match_report_screen.dart`'s body is `GraphTreeView(reportType:
    'match')` and the old `LivingReportView` match body was deleted. The match
    top-line score is a percent STRING ("52%"); `report_tree._percent_value`
    parses it to a numeric 0..100 ScoreBar so the headline score gets the same
    banded graphic its sub-dimensions do. The two-person avatar row, Taste-match
    card, and Recalculate/Share chrome stay bespoke, fed by the separate
    `GET /match/{id}` fetch. **Public profile (P4) + story-public /
    shared-report (P5)** migrated the same way, and **P6 (SHIPPED)** migrated
    the final host — Ayma's Notes' `story_ai_notes` body — and **deleted
    `living_report_view.dart` outright**: there are now ZERO `LivingReportView`
    references anywhere in `lib/` (pinned by
    `test/living_report_view_removed_test.dart`). Every report-like surface now
    renders through the shared `GraphTreeView` Node-Visualiser.
  - *ONE unified visual report framework (founder Nov 17) — supersedes the
    bespoke appearance template.* Every report now renders through the SAME
    general assembler: `GraphTreeView(surface: report)` → `NodeVisualiserSection`
    → the palette, assembled purely from each node's own `visual`. There is no
    per-report layout code: scores → gauge/bar, findings → card, comparisons →
    `small_table`, lists → `chip_set`, dated items → `timeline_entry`, photos →
    one swipeable carousel, plain facts → gist row. Three changes generalized the
    designed look the appearance template used to own:
    - **Section cards.** On the report surface `NodeVisualiserSection` renders
      each section as a designed elevated card with a serif heading
      (`cardStyle`, passed by `GraphTreeView` when `surface == report`); Your
      Story / public profile / graph detail keep the plain rows. A section whose
      nodes all filter out (private on a shared surface, or empty) renders
      nothing — never an empty titled card.
    - **Photo carousel aggregation.** `_siblingWidgets` merges EVERY IMAGE leaf
      in a sibling list on the report surface into ONE `NodePhotoCarousel`
      (`lib/widgets/node_photo_carousel.dart`) — NOT only a consecutive run.
      Before (Scout NOTE 255), it grouped consecutive leaves only, so a report's
      photos split into a carousel of the adjacent ones plus the rest rendered as
      separate single "large embedded" images (e.g. the 3 appearance photos next
      to 4 web-research candidates). Now all of a section's image leaves
      aggregate into one carousel at the first image's slot; non-image nodes
      between them still render in place. The carousel is a horizontal,
      swipeable `ListView` STRIP of square `NodeImage` `fill` tiles with
      per-tile captions that SCROLLS through all images; tapping a tile opens
      the fullscreen DETAIL (`AymaImageViewer.gallery`), a `PageView` that
      ADVANCES ON SWIPE. The strip's height follows the viewer's text scale and
      captions cap at two ellipsised lines, so it never overflows. The list is
      already viewer-filtered, so a private / Ayma-only photo never reaches a
      surface it may not show. Your Story keeps inline thumbnails (not
      aggregated). A `candidate` node (is-me/not-me) is never swept in.
    - **Appearance migrated, bespoke layout deleted.** `appearance_report_screen`
      now embeds `GraphTreeView(reportType: 'appearance')`; the bespoke
      `appearance_templated_report.dart` (+ its test) were DELETED. The score
      gauges, photo carousel, attribute fields and finding cards all come from
      the appearance node tree's own palette visuals — same tree, same store.
      The shareable card + Re-run + Updating… banner chrome is unchanged.
    So a NEW report kind made of known node shapes renders correctly with ZERO
    new client code. Never-breaking is structural: a missing / partial /
    odd-shaped node degrades to a gist row or is omitted (never a crash,
    overflow, raw JSON or empty page); an empty tree shows an honest empty
    state. Because the report tree is already viewer-visibility-filtered by
    `report_tree.py`, a shared/public report's visuals, scores and counts are
    built ONLY from viewer-visible nodes (P0 privacy).
    - *Pre-open SUMMARY cards (no raw JSON anywhere).* Every surface that points
      AT a report before it opens — the chat report card, a graph node, a list
      row — shows a human summary distilled from the SAME tree
      (`ReportSummary.fromTree` → `ReportSummaryCard`,
      `lib/models/report_summary.dart` / `lib/widgets/report_summary_card.dart`):
      title, date, headline score and top finding. On a load failure it degrades
      to a plain labelled row, never an error dump or a map. The chat inline
      card (`chat_screen.dart` `_InlineReportCard`) uses it for appearance /
      deep_dive / match; a streaming Ayma turn now also strips the trailing
      `[appearance:<id>]` marker so the raw marker never leaks before the turn
      finalizes. `GraphTree` now carries the report `title` + `meta`
      (`created_at`/`viewer_can_edit`), previously dropped by `fromMap`.
    Regression: `test/unified_report_framework_test.dart` (assembly + malformed/
    partial degradation + privacy), `test/report_summary_test.dart`,
    `test/report_summary_card_test.dart`, golden
    `test/golden/unified_report_golden_test.dart`.
## Read/write switch FINISHED (Nov 16) — staging code no longer reads or writes wiki_pages (flag-on)

Branch `fleet/graph-read-write-switch`. With `PERSON_GRAPH_READS` on, every live
reader and content writer is graph-backed; the frozen `wiki_pages` store is no
longer touched by staging code (the prod→staging sync still restores it, handled
at deletion time — Phase 7). Flag off → today's wiki paths, unchanged.

- **Grounding read.** `wiki_query.read_wiki_context` and `recall_snippets` gate
  centrally to `person_graph_source.grounding_context` / `recall_context` →
  `person_graph_render.grounding_block`, migrating ALL callers at once (chat +
  voice context in `main.py`/`async_voice`, `ai_assessment`, `completeness`,
  `physical_attributes`, `reengagement`, `analysis_mode`, `taste_backfill`). The
  block renders graph nodes grouped by a wiki-style **page_type**
  (`render.node_page_type`: a node's question-tree section, or its id-prefix for
  live-written meta — `emergent.steering.*`, `emergent.skill.*`,
  `emergent.assessment.*` (live) / `emergent.assess.*` (migration-seeded)), so
  the context-diet include/exclude filters
  (`CORE_PAGE_TYPES`, `EXCLUDED_FROM_CHAT_CONTEXT`) keep working unchanged.
- **Story / public reads.** `story.get_story` + `get_ai_notes` render from the
  graph (`story_reads._graph_sections`); `public_profile.public_bullet_sections`
  + `_public_pages`, `deep_dive.wiki_dive_context`,
  `explore._fetch_candidates_wiki_text` all gate to the graph. Report-linked
  nodes (appearance / web-findings) are dropped from Story/public, kept in
  grounding/persona. Migration reads the SOURCE wiki via
  `story_reads.get_story_wiki` / `get_ai_notes_wiki`.
- **Content writers → graph nodes** (`person_graph_store.upsert_fact_node`,
  stable ids): skill reports (`emergent.skill.<page_type>`), interactions,
  steering (`emergent.steering.rules`, ayma_only), the Qloo taste page
  (`emergent.taste.qloo`, public in the `taste` section), and **Ayma's
  assessment** (`emergent.assessment.{red,green,neutral}`, ayma_only inferred,
  source `assessment`; founder Nov 17 part (a)). The assessment's refresh
  bookkeeping + digest + raw notes ride on a sibling non-rendering `report_doc`
  node `emergent.assessment.meta` (so nothing needs an off-wiki doc). The old
  `assessment/main` document and its read/write path are **deleted**; a one-time
  idempotent `ai_assessment.backfill_to_graph(db, uid)` migrates existing users'
  docs into the nodes. `node_page_type` maps the `emergent.assessment.` prefix to
  page_type `assessment`, so `EXCLUDED_FROM_CHAT_CONTEXT` still keeps the private
  judgment out of chat/voice grounding, and matching's `persona` (ayma_only
  excluded) still omits it from the generic dump while `ai_assessment.digest`
  feeds it as its own labeled block.
- **Your Story editor write-back** (closes the NOTE 230 Phase-6b gap):
  `profile_bullets.save_bullets`/`create_bullet_section` and the in-chat edit
  primitives (`story_writes.save_section`/`create_section`/`set_visibility`/
  `remove_section`, used by `report_hub`) write the graph via
  `store.replace_section_bullets` — the editor owns a section's public/private
  **emergent** nodes; seed answers and ayma_only/reserved nodes are never
  touched, so a delete takes and no structured/Ayma-only fact is lost.
- **Degraded under the graph (documented):** per-section wiki metadata badges
  (`user_edited`, `ai_updated_since_user`, `user_hidden`), the face/body report
  per-photo `reads` history, the `recall` `source_log` excerpts, wiki-page
  `frontmatter`, and story version history — none have a graph equivalent yet.
- **Still wiki (flagged, out of this chunk's scope):** `practice_seed` demo-
  persona seeding (demo tooling, not a live user write).
- **Tests:** `tests/test_graph_read_write_switch.py` (flag-on reads/writes +
  wiki-untouched assertions); the flag-off suites stay green.

- **7 — cutover + delete** (the wiki store itself + the prod→staging sync
  exclusion). GATED on founder post-switch re-verification; now unblocked by the
  read/write switch above.

## Phase 7 — delete the old wiki store ✅ (Nov 16, staging)

Scout NOTE 232 passed on build 2458 (all four graph legs; all 28 wiki md5s
unchanged), confirming staging runs flags ON and no live reader/writer needs
`wiki_pages`. Re-ran the reader grep against staging tip `d292ed99`: every
`collection("wiki_pages")` hit is gated flag-on → the graph, behind the central
ingest gate (`wiki_ingest.ingest`), disabled (`wiki_lint.lint_all`), reached
only from a flag-off branch, or a test-only demo seeder (`practice_seed.seed`,
no staging call site). Clean.

- **Deleted (staging only):** all 174 `wiki_pages` docs across 27 users (incl.
  `deleted_accounts/*/wiki_pages`) **recursively**, with their 178 `versions`
  docs — 0 of each remain. The graph is untouched (368 overlay nodes, unchanged).
  A full JSON archive (every page + its versions) was exported first.
- **Prod→staging sync exclusion:** `scripts/sync-prod-to-staging.sh` runs a
  **post-import purge** (`scripts/purge_staging_wiki_pages.py`) after each
  Firestore import, since the import re-copies prod's still-live `wiki_pages`
  (prod runs flags OFF) and managed import `--collection-ids` is include-only.
  The purge is recursive and **staging-only** (hard project guard; refuses
  `ayma-ai`). Prod is never touched; the import's contents are unchanged.
- **Prod wiki_pages is untouched** — prod still reads/writes it (flags OFF), so
  the flag-off wiki code paths stay. Phase 7 retired the *staging* data + the
  sync re-pollution only; nothing is code-dead until prod flips.

## Structured-writer swap ✅ (Nov 16, staging)

Branch `fleet/structured-writer-swap`. With `PERSON_GRAPH_READS` on, the three
model-called tools that previously wrote `profile/main` + `qstore`
(`users/{uid}/questionnaire`) and `wiki_pages/taste` are swapped to graph-only:
- `record_answer`: writes to `users/{uid}/graph/main` via `person_graph_store.set_answer`.
  Gender-identity inference refusal preserved. Taste node writes compose `emergent.taste.qloo`
  in the graph's `taste` section (`visibility: public`). `profile/main`, `qstore`, and
  `wiki_pages/taste` are left completely untouched.
- `set_relationship_intent`: writes `relationship_intent` to the graph overlay
  (`visibility: public`). `profile/main` and `qstore` are untouched.
- `set_profile_field`: writes structured identity fields (`name`/`first_name` → `legal_first_name`,
  `birthdate` → `date_of_birth`, `gender` → `gender_identity`, `interested_in` → `target_match_genders`,
  `location` → `primary_location`) to graph seed nodes, and emergent facts (`last_name`, `phone`)
  to `emergent.profile.*` nodes. 18+ adult birthdate safety check and normalization preserved.
  `profile/main` is untouched.
- Visibility: respects established allow-list defaults (private unless on public allow-list).
- Flag OFF: writes to `profile/main`, `qstore`, and `wiki_pages/taste` unchanged.
- Tests: `tests/test_structured_writer_swap.py` (9).

## Reports as nodes ✅ (Nov 16, staging)

Branch `fleet/reports-as-nodes` (board row 328). With `PERSON_GRAPH_READS` on,
the **appearance report** and the **web-search (deep-dive) report** render ONLY
from graph nodes — the `appearance_reports` and `deep_dives` collections are
deleted on staging (Astro, Nov 16; prod untouched). Founder design (Option A):
each report's full structured payload rides ONE Ayma-only emergent node that the
report screen rebuilds from byte-identically; the human findings keep feeding the
per-section grounding nodes (`emergent.skill.*`) that own public/match leakage.
Report nodes are `provenance: inferred` (unconfirmed until the user confirms in
conversation) and `answer_type: report_doc` — non-rendering scaffolding, never a
Your Story / public / grounding bullet.

- **Store primitive:** `person_graph_store.upsert_report_node` /
  `report_node_payload` (`answer` = the report payload dict; ayma_only).
- **Appearance** → `emergent.appearance.report`. `appearance_storage._persist_report`
  writes the node flag-on; `appearance_reads.get_report`/`history` and
  `_read_report_doc` rebuild from it. The share-card photo-curation list already
  lived on `profile/main` (unchanged). Per-photo reads + photo history are carried
  ON the report node (`finding_history` + per-section `source_photos`); the report
  screen renders photos from there via `report_adapters._source_photo_blocks`.
  Standalone `emergent.image.*` nodes remain the chat-photo path (pg-add-image).
- **Web-search** → `emergent.webfind.report.<cache_key>` in the SUBJECT's graph
  (`uid_<subject>` for a member, `name_<slug>` self/non-member under the searcher).
  `deep_dive._load_dive_doc`/`_store_dive_doc` route `store_dive`/`read_dive`/
  `cached_dive`/disputes/`correct_finding`/`merge_confirmed_photo` to the node;
  `_epoch` parses the node's ISO `created_at` so cache-age math holds.
- **Render surfaces unchanged:** `report_adapters.appearance_blocks` /
  `deep_dive_blocks` are byte-identical (they read through the producer's own
  `get_report`/`read_dive`, now node-backed), so the Flutter Living-Report
  screens need no change.
- **External readers migrated:** `skill_runs._artifact_seen` (web-dive node
  counts as a prior run), `fact_source._deep_dive_matches` (reads webfind node
  payloads) and `fact_source._appearance_matches` (reads via `get_report`).
- **Loud-fail:** `appearance_storage._report_ref` and `deep_dive._cache_ref`
  raise `RuntimeError` when `person_graph_reads` is on — any forgotten flag-on
  path that still touches a deleted collection fails visibly (the founder's
  stated purpose for the hard deletion), never a silent empty read.
- **No migration / backup** (founder override): the old data was already deleted;
  fresh reports generate from the nodes. Flag OFF is byte-identical (prod still
  runs the collections until its own cutover).
- Tests: `tests/test_reports_as_nodes.py` (11) + `tests/test_reports_as_nodes_web.py` (8).

## Reports as PER-ELEMENT nodes (founder Nov 18 2026)

Branch `fleet/reports-per-element-nodes`. Founder order (voice): a web-search and
an appearance report must be **ONE SOURCE-TAGGED NODE PER ELEMENT, not a single
lump** — so tapping a report element (a fact, a strength) opens THAT element only
in the partial chat, never the whole report. This supersedes the single
`emergent.skill.*` grounding lump each report used to write; the structured
`report_doc` METADATA node (above) stays as the report-level home for score /
photos / verdict / `finding_history`, which the templated report screen still
renders from. With `PERSON_GRAPH_READS` on:

- **Web search** → `skill_memory.save_web_findings` writes one node per DISTINCT
  finding — `emergent.webfind.summary.<n>` (one per summary sentence),
  `emergent.webfind.fact.<fact_id>`, `emergent.webfind.link.<hash>`,
  `emergent.webfind.social.<hash>` — each stamped `source_kind="web_search"` with
  the web link in `source_ref`. Stale findings from a prior dive are cleared
  (overwrite semantics); the legacy `emergent.skill.web_findings` lump is retired.
  Nodes map to the `web_findings` page_type (`node_page_type`), so grounding /
  persona group them exactly as the lump did, and they stay out of Your Story /
  public (report-linked). The structured digest still rides
  `emergent.webfind.report.*` for the report SCREEN (`deep_dive_blocks`).
- **Appearance** → `skill_memory.save_face_analysis` / `save_body_analysis` (and
  the auto-analysis `merge_*`) write one node per discrete finding — each
  strength / improvement / recommendation — at `emergent.skill.{face,body}_
  analysis.<kind>.<n>`, stamped `source_kind="appearance"` with the source photo
  in `source_ref`. The legacy `emergent.skill.{face,body}_analysis` lumps are
  retired. Report-level metadata (score / verdict / `category_status` /
  `finding_history` / photos) stays on the structured `emergent.appearance.report`
  node; `report_adapters.appearance_blocks` keeps rendering the templated page
  from it (the report screen already renders per-element via `report_tree`, so a
  tap already opens one block — no render rewrite, no render-correctness risk).
  `node_page_type` now maps a multi-segment skill suffix
  (`face_analysis.strength.0`) to its base page_type.
- **Dedupe / visibility unchanged:** stable ids make re-runs idempotent, batch
  dedupe drops identical findings, default visibility is `private` (a prior user
  promotion is kept); node controls apply like any other node.
- **Migration (lossless):** `skill_memory.migrate_web_findings` re-splits a user's
  existing web lump from the live `emergent.webfind.report.*` digest;
  `migrate_appearance_findings` re-splits the face/body lumps from the structured
  `emergent.appearance.report` axes. Both delete the lumps. Run on ayma-staging
  for the founder uid (+ demo-test1) by Astro/Scout (needs staging Firestore).
- **Flag OFF (prod) unchanged:** the wiki-page lumps are still written; the
  `appearance_reports` doc store (`_persist_report`/`_read_report_doc`/
  `_report_ref`) is KEPT for prod and is deleted only at the prod cutover — a
  staging-only change must not break prod (consistent with "reports as nodes").
- Tests: `tests/test_web_findings_nodes.py` (6) + `tests/test_appearance_finding_nodes.py`
  (5); updated the superseded lump assertions in `tests/test_gist_first_writing.py`.

## Node dedupe — index, cross-check, resolution (founder Nov 17 2026)

Founder's ask: "a way to index and cross check the nodes to find related nodes
that is not parent and child so that there is no duplicated content." Branch
`fleet/node-dedupe-index`. Additive and behind flags (`NODE_DEDUPE`,
`NODE_DEDUPE_PREVENTION`, `NODE_CONFLICT_RAISE`, all default off); flag-off is
byte-identical to today.

- **Index** — `person_graph_index.build_index(db, uid)` projects the whole
  effective graph (`seed ⊕ overlay`, every kind) to flat `NodeIndexEntry`s: id,
  parent/section path, visibility, kind (`seed`/`grounding`/`bullet`/`image`/
  `report_doc`), the node's content text, and a deterministic lexical signature
  (normalized text + content-token set). An IMAGE node indexes its `image_read`
  (Contract 1, not the storage URL); a `report_doc` node its flattened payload
  strings. Read-only, derived on demand — no parallel store, no second index DB.
- **Embedding facility:** there is NO LiveKit-routed TEXT-embedding endpoint
  (the only embedding model, `CONFIG.image_embedding_model`, is a Vertex
  multimodal photo call, and `AGENTS.md` forbids routing inference off LiveKit).
  So the "semantic embedding" is served in two layers that stay on existing
  backend patterns: a lexical signature in the index, plus a SEMANTIC judge over
  the bounded ambiguous candidate set run through the existing LiveKit gateway
  (`gemini.generate_json`) — not a stored vector.
- **Cross-check** — `person_graph_crosscheck.find_candidates(index)` compares
  every non-ancestor/descendant pair: exact (same normalized text) and
  near-duplicate (difflib ratio / token Jaccard) → duplicate pairs/groups;
  shared-entity mid-band overlap → related (Contract 4) candidates. `O(n²)` over
  a few-hundred-node graph is trivial. `classify_pairs(...)` optionally promotes
  the ambiguous set with the LiveKit semantic judge (`duplicate`/`related`/
  `unrelated`), bounded by a pair cap; best-effort (inference failure keeps the
  lexical result). Finds dups across sections/branches and between report
  grounding nodes and story bullets — career facts + photo-reads-vs-facts are
  the known hunting grounds.
- **Contract 4 (related links):** `links:[{target, type:"related", label?}]` —
  a new first-class `StrictLinkType.RELATED` (so deterministic code and Track C's
  graph highlight act on it); `label` is the short human reason. Same `Link`
  shape as every other typed link; a reference, never a copy. Registered in the
  relationship-type registry.
- **Resolution — NEVER silent.** Nothing is auto-merged/deleted. Ayma surfaces a
  candidate group in chat (`skills/node_dedupe.py`: `pg_find_duplicates` read-only,
  `pg_resolve_duplicate` applies the user's choice) behind `NODE_DEDUPE`:
  - **merge** → `store.merge_nodes(survivor, dup)`: fold the duplicate's answer
    to the survivor's Ayma-only history, rehome its children, carry its links,
    repoint every reference, delete it (seed nodes never deleted — merge toward);
  - **link** → `store.link_related(a, b, label)`: two-way `related` link;
  - **keep** → `store.dedupe_dismiss(a, b)`: stored on the graph doc so the pair
    is never re-raised.
- **Write-time prevention** — `NODE_DEDUPE_PREVENTION` on: the free-minting
  creation paths (`add_loose_node`, off-script `add_node`) first check the index
  and REUSE an existing node on an EXACT content match instead of duplicating
  (one localized `_dedupe_collapse_id` hook). Exact-only = high precision, no
  silent fuzzy merge; near/semantic dups still route to the user-confirmed flow.
  Stable-id upsert paths (`upsert_fact_node`/`upsert_report_node`) are untouched.
- **Write-time CONFLICT raising (part d)** — `NODE_CONFLICT_RAISE` on: when a new
  conversational fact CONTRADICTS a fact the graph already holds (same topic,
  materially different answer — *not* a duplicate: the two answers can't both be
  true), the free-minting write is **suppressed** and the conflict is **raised in
  chat** for the user to resolve, so two contradictory nodes are never written
  silently. Lives in the write path, before minting: the `remember` tool calls
  `store.find_write_conflict(db, uid, fact)` → `ConflictFinding | None`. Same-topic
  candidates come from the deterministic lexical pre-filter
  (`crosscheck.candidates_for_text`, the same "related, not identical" band,
  EXACT restatements excluded as duplicates); the CONTRADICTION verdict is the
  LiveKit judge (`crosscheck.classify_conflict`, prompt
  `prompts/node_conflict_judge.md`) — never rerouted off LiveKit, best-effort (a
  judge/quota failure returns no-conflict and the write proceeds, never blocks).
  On a conflict, `remember` returns a chat prompt that surfaces BOTH values (the
  owner's own notes, owner-only surface) and tells Ayma to ask which is right,
  then call `pg_resolve_conflict(node_id, keep='existing'|'incoming', new_value)`:
  `existing` discards the new fact; `incoming` overwrites the stored node's answer
  via `set_answer` (old value retired to Ayma-only history), so exactly **one**,
  resolved node remains. Distinct from the duplicate path above and from the
  read-time tidy flow (`pg_find_duplicates`). Fully-reworded conflicts that share
  no topic words fall to the embedding candidate path (`GRAPH_EMBEDDING_DEDUPE`),
  the same two-layer framing as dedupe above.
- **Staging runner** (read-only, never mutates the graph):
  `PYTHONPATH=. python3 tools/person_graph_dedupe_run.py <uid> --project=ayma-staging [--semantic] [--limit=N]`.
  Prints duplicate groups + related pairs with ids/kind/section/visibility/snippet.
- Tests: `tests/test_node_dedupe.py` (24 — incl. write-time conflict raising and
  the editor-import merge-not-mint guard).

### Zero-duplicates — standard-vs-emergent facts (founder build 2488, Nov 17 2026)

Founder's About Me showed facts TWICE: a STANDARD node (`ethnic_cultural_origin`
= South Asian, `date_of_birth` → Age, `target_match_genders` → Interested in)
AND an emergent node that only restated it (`emergent.editor.identity.11` =
"Ethnic and cultural origin: South Asian", `emergent.editor.identity.4` = "Age:
33", prose `emergent.story` bullets). The 2485 lexical dedupe missed these
because a "`<Label>: <value>`" bullet is *not* an exact-text match of the bare
standard value. Three layers, all surgical, closing the loop:

1. **Render guarantee (always on)** — `person_graph_tree.node_tree` / `_build_node`.
   A section never shows the same fact twice: when a STANDARD fact renders as its
   labelled row, any OTHER node in that section whose text restates it (the bare
   value, or the `<label> <value>` content tokens — so "Ethnic & cultural origin:
   South Asian" ≡ "Ethnic and cultural origin: South Asian" past the `&`/`and`
   gap) is suppressed; the standard row is the keeper. Exact-duplicate bullets
   (same normalized text) anywhere in the tree are suppressed too (first wins).
   **Surface-aware:** a standard fact only suppresses a restatement on a surface
   where that standard row itself renders (its visibility ∈ `keep`), so
   suppression can never drop the only copy of a fact nor pull a private value
   onto the public profile (and vice-versa). Suppressing a node blanks its own
   line only — distinct children still render.
   **Unmerged-graph restatements (NOTE 252 leg 28):** the layer-3 data merge ran
   only on the founder's uid, so other users still carry two *distinct* emergent
   restatements of one fact whose normalized text differs by a stopword /
   punctuation / word-order (so the exact-norm check above misses them). A
   SECTION-SCOPED **content-token-set** dedup (`index.token_set`, stopwords
   dropped, order-insensitive) collapses them to one — same precision bar as the
   `<label> <value>` token form, so genuinely distinct facts (different token set)
   and a fact legitimately shared across two sections are untouched. Render-only:
   no stored data is merged.
2. **Write-time prevention (merge-not-mint)** — the gap that let the editor
   import create the duplicates. The editor write-back
   (`person_graph_store.replace_section_bullets`) renders the standard facts into
   its bullet list; their ids are SEED ids, so they never matched an editor-owned
   node and a new `emergent.editor.*` node was minted. Now every creation path
   drops a bullet/fact that only restates a standard fact:
   `replace_section_bullets` (a matched legacy restatement is left unconsumed and
   so deleted on save), and the free-minting `add_loose_node` / off-script
   `add_node` (which reuse the standard node's id — `_standard_restatement_id`,
   always on, before the flag-gated exact `_dedupe_collapse_id`). The matcher is
   the one shared primitive `person_graph_render.standard_restatement_id` the
   render uses, so write-time and render can never disagree.
3. **Data merge (build + test only, NOT executed)** —
   `tools/merge_duplicate_fact_nodes.py`: for a uid, finds every emergent node
   that restates a standard fact and MERGES it into the standard node with the
   existing `store.merge_nodes` (= `pg_resolve_duplicate` 'merge': standard
   survives, duplicate's answer retired to the survivor's history, children
   rehomed, links carried, duplicate deleted). A visibility conflict keeps the
   STANDARD node's visibility and is recorded in the report. `--dry-run` (default)
   only reports pairs + counts. Project-pinned: ABORTS unless the active project
   is exactly `ayma-staging`. The main thread runs it (dry-run first) for the
   founder's uid only; other staging users are governed by the in-chat raise flow
   (layers 1+2 protect their renders). `--apply` applies.
- Tests: `tests/test_person_graph_tree.py` (render suppression + surface-aware
  privacy), `tests/test_node_dedupe.py` (editor merge-not-mint, loose-node reuse),
  `tests/test_merge_duplicate_fact_nodes.py` (dry-run report, apply merge, child
  preservation, visibility-conflict keep-standard, staging-project guard).

### Data-level dedupe sweep — merge duplicate nodes on the server (founder Nov 17 2026)

The founder's live graph showed TWO "Social Circle" nodes carrying the SAME fact
in different words (one private, one Ayma-only). The render-level zero-dup work
above only *hides* dupes on screen; this REMOVES them from the DATA. All
server-side, behind `GRAPH_DEDUPE_SWEEP` (default off; additive/reversible —
flag-off writes and stores exactly as before).

- **Layer 1 — write-time SEMANTIC fold** (`person_graph_store._dedupe_collapse_id`
  → `_semantic_fold_id` → `fold_into_node`). Extends the existing
  `NODE_DEDUPE_PREVENTION` hook (one call site per free-minting path): after the
  exact-match reuse, when `GRAPH_DEDUPE_SWEEP` **and** `GRAPH_EMBEDDING_DEDUPE`
  are on, a NEW fact that is near-identical (Gemini-embedding cosine ≥ **0.92**)
  to an existing EMERGENT node in the same section is FOLDED into it instead of
  minting a second: the surviving text is **enriched** if the new wording adds
  detail (old answer retired to history), the existing node **id** is kept, and
  **both sources** are kept. Lower-confidence near-dupes are not folded here —
  they fall to Layer 2's never-silent raise. Compares against the vectors the
  sweep/nightly refresh already stored; a not-yet-embedded node just isn't a fold
  candidate this pass. Best-effort — never blocks a write.
- **Layer 2 — post-processing sweep** (`person_graph_dedupe_sweep.sweep_user`).
  Runs when a conversation **session ends** (`post_turn.persist_and_ingest`, after
  ingest, concurrent + best-effort) and on a **nightly backstop**
  (`POST /cron/graph-dedupe` → `run_sweep`). Per section it finds near-dup pairs
  via `crosscheck.candidate_report`, has the **LiveKit judge**
  (`crosscheck.classify_pairs`) label every non-exact candidate, then:
  - **merges** the clear duplicates (exact text, or judge verdict "duplicate").
    Merge rules: the **FULLER text survives**; where one is a **STANDARD** node
    the standard node survives (build-2490 rule) — **BUT** a richer bullet (one
    with content tokens the short standard value lacks) is **never** folded into a
    standard field, because folding retires its answer to history and would DROP
    those extra facts (NOTE 255 add.3: "…and speaks Malayalam and English" lost
    into "San Jose, United States"); such a pair is **raised** instead. The
    survivor keeps **BOTH sources** (`merge_nodes` retires the dup's answer +
    source into history); **merged visibility = the MORE PRIVATE of the two** — a
    merge **NEVER** widens visibility (HARD rule: private > ayma_only > public;
    `apply_merge` only ever *tightens* the survivor's visibility).
  - **raises** every UNCERTAIN pair (lexically near but not judge-confirmed, merely
    related, or disagreeing) via `store.record_pending_dedupe` — the sweep never
    guesses and never merges an uncertain pair silently. A judged-duplicate pair
    that can't be auto-merged (**both** sides seed, so nothing is deletable; or
    the standard-field fact-loss guard above) is **raised**, never dropped.
  - **Eligibility** (`_eligible`): a pair needs at least one *mergeable* side — an
    emergent node **or a seed NARRATIVE** (freeform prose a user wrote into a seed
    slot, e.g. two career narratives both describing the same workday — the
    "coffee" pair). Only two **structured** seed fields (enum/select/number) are
    skipped — the fixed question tree is not a dup source. (Was `_has_emergent`,
    which dropped every seed-narrative pair before it was judged — NOTE 255 add.3.)
  Recorded raises surface in chat through `pg_find_duplicates` ("NEEDS YOUR CALL")
  and clear on any `pg_resolve_duplicate` (`clear_pending_dedupe`), reusing the
  settled conflicts-in-chat resolution — never a new popup.
- **Candidate generation** (`crosscheck.candidate_report`): the **lexical** pass
  (`find_candidates`) **always** runs; when `GRAPH_EMBEDDING_DEDUPE` is on,
  embedding nearest-neighbour (`find_candidates_semantic`) is **UNIONED in on top**
  (not in place of it). Lexical keeps the high-precision exact/near-dup/shared-
  entity classes (taste lists, seed-vs-seed restatements) that cosine can rank just
  under threshold; embeddings add the low-overlap paraphrases lexical misses (an
  `emergent.assess.*` vs an `emergent.story.*` of the same fact). The old code
  **replaced** lexical with embeddings, silently losing every lexical duplicate the
  moment the flag turned on (NOTE 255 add.3). Embedding vectors are populated by
  `graph_embeddings._embed_backend`, which embeds **one text per call** —
  `gemini-embedding-2` on Vertex returns a single vector regardless of how many
  contents are passed, so the previous batch call stored nothing and the finder was
  forever lexical-only.
- **Staging runner** (project-pinned `ayma-staging`, dry-run default, `--apply`):
  `GRAPH_DEDUPE_SWEEP=true GRAPH_EMBEDDING_DEDUPE=true PYTHONPATH=. python3 tools/dedupe_sweep_run.py <uid> --project=ayma-staging [--apply]`.
  Reports pairs FOUND / MERGED / RAISED.
- **Dry-run preview counts MERGES, not pairs (DEDUPEPREVIEW).** FOUND is the raw
  candidate-pair count, but WOULD-MERGE must equal what `--apply` will actually
  do: a k-node duplicate CLUSTER is C(k,2) candidate pairs yet only k-1 merges,
  because once a node is folded away every later pair that referenced it is a
  no-op. The dry branch of `sweep_user` simulates the apply's `removed`-set +
  survivor collapse WITHOUT writing (same `choose_survivor`; a pair whose
  duplicate is a seed node isn't counted, mirroring `apply_merge` returning
  `None`), so the preview no longer overshoots the apply (e.g. the founder graph's
  13-pair preview that applied as 3). Reporting-only — the merge decisions and the
  apply's writes are unchanged.
- Embeddings are the founder-approved **direct-Google** exception (embeddings
  only; the judge stays on **LiveKit** per `AGENTS.md`). Model string from
  `config.py` only.
- Tests: `tests/test_graph_dedupe_sweep.py` (paraphrase detection + merge, fuller
  survives, both sources kept, more-private-wins, standard survives, uncertain
  raises-not-merges, a parametrized privacy proof over every visibility pair, the
  Layer-1 write-time fold, **a richer bullet is not folded into a standard field**,
  **a seed-narrative duplicate is raised not dropped**, structured seed fields are
  not a dup pair); `tests/test_graph_embeddings.py` (**one-text-per-call batch
  embed**, **candidate_report unions lexical + semantic**).

## Live image-node ingestion on every source path (2l, Nov 17 2026)

"Images are nodes" now fires on **all four ingest paths**, not just chat — every
image Ayma sees becomes an `answer_type == "image"` node carrying the structured
`is_you` verdict and the SOURCE provenance (`source_kind` ∈
`chat|profile_grid|appearance_report|web`, `source_ref` the conversation /
media / report id or source page, `source_created_at` the first-ingest time).

- **One helper, one identity.** `person_graph_store.home_image(...)` is the
  single idempotent entry point (thin wrapper over `add_photo_fact`), and the
  node id is content-addressed: `image_node_id_for_bytes(bytes)` for any path
  that has the bytes (chat / grid / appearance) and `image_node_id_for_url(url)`
  for web (no bytes retained). The same photo shared in chat, added to the grid
  AND read in an appearance report therefore collapses onto **one** node — a
  later path just upserts a fresher read / verdict / source in place.
- **chat** — `main._enrich_turns_with_photo` (already live): bytes in hand,
  caption = read, `source_ref` = session id. Refactored onto `home_image`.
- **profile grid** — `photo_pipeline._enrich` when `source == "profile"`: the
  grid add has no "fact" said about it, so the caption is both read and fact;
  `source_ref` = media id.
- **appearance report** — `appearance_engine.run_appearance` homes the analysed
  face/body picks after persist (`_home_appearance_photos`), reusing the bytes
  already in hand (no re-fetch), `is_you="yes"` (own photos), read = the axis
  verdict note, `source_ref` = report id. User-initiated runs only (never the
  silent `auto` reconcile).
- **web** — `deep_dive._home_web_images` after `store_dive`: each verified
  web photo becomes a node on the subject's graph, `is_you` = yes/unknown from
  the face-verify, `source_ref` = source page — so web photos show in the graph
  instead of living only inside the webfind report digest.

All four are gated on `person_graph_reads` and best-effort (a graph-home failure
never undoes a stored photo / report / dive). Tests:
`tests/test_image_node_ingestion.py` (8).

## Report → Node-Visualiser tree (2o P0, Nov 17 2026)

The blocker for migrating the report screens off `LivingReportView`: a report
lived as ONE opaque `report_doc` node (scores/findings only the block renderer
could read). P0 makes a report a NODE TREE, and teaches the node model +
visualiser the report node kinds.

- **Node kinds** (`models/story_node.dart` + `widgets/node_visualiser.dart`):
  - **stat** (`answer_type == "stat"`): a numeric SCORE/STAT → label + value
    digit + banded `ScoreBar` (green/amber/red) + `stat_basis` line; a
    non-numeric value is a CONFIDENCE band → a coloured pill, no bar.
  - **link** (`answer_type == "link"`): `link_url` + `link_platform`; the row
    tap opens the URL.
  - **candidate** (`answer_type == "candidate"`): a pending reverse-image-search
    photo with "This is me" / "Not me" (shown only when the host wires
    `onCandidateVerdict`; the deep-dive report will, P2).
  - image / text / standard-field nodes are unchanged.
- **Backend adapter** (`report_tree.py`): `report_node_tree(db, type, id,
  viewer_uid)` reuses `report_hub.get_report` (the exact `{title, sections,
  meta}` block model the `/report/{type}/{id}` endpoint serves, owner/permission
  checks included) and converts each block to a node, so EVERY report type works
  — `match` included, which has no node in any person graph. Served at
  **`GET /report/{type}/{id}/tree`** (same 403/404 semantics as the block
  reader); client `ApiClient.reportTree(type, id)` → `GraphTree`.
- Report nodes are display-only: visibility is always `public`, `editable`
  carries the block's own flag. Tests: `tests/test_report_tree.py`,
  `test/node_visualiser_test.dart` (+3).
- **Shared-report snapshot tree (P5)** — a share link (`/s/{token}`) is a FROZEN,
  public, unauthenticated snapshot (`share.fetch_public`); it must NOT go
  through the owner-checked `report_node_tree`/`/report/.../tree` or a
  token-holder who isn't the owner would be denied the body. So
  `report_tree.snapshot_node_tree(snapshot)` converts the snapshot's already-
  authorized `{title, sections}` straight to a node tree (reusing the same
  `_sections_to_tree`/`_block_to_nodes` as the live path), forcing `meta =
  {owner_uid:"", viewer_can_edit:False}` — identical to `/s/{token}/data`.
  Served at **`GET /s/{token}/tree`** (the same public `_public_snapshot` path
  as `/s/{token}/data`, `/s/` public rate limit); client
  `ApiClient.sharedReportTree(token)` → `GraphTree`, no auth header.
  `SharedReportScreen` renders it through `GraphTreeView(loader: …,
  isOwner:false, surface:report)` — a new `loader` callback on `GraphTreeView`
  for the token path (it can't use `reportType`/`reportId`, which hit the
  owner-checked endpoint). The old `LivingReportView` body (and the now-orphaned
  `ApiClient.sharedReport`/`/data` client method) were deleted. Read-only:
  `isOwner:false` suppresses every node chat/edit/correct affordance. Tests:
  `tests/test_report_tree.py` snapshot cases, `tests/test_share.py`
  `test_tree_is_public_and_unknown_token_404s`, `test/share_report_test.dart`
  (renders through the tree unauthed; a revoked/unknown token shows no body).
- **True-parentage indent render rule (`fleet/story-section-indent-fix`, build
  2495; supersedes the `fleet/level-indentation` level-floor).** The
  `NodeVisualiser` indents each row **ONLY by its real depth under a TRUE PARENT**
  in the render recursion (one 18 dp step per real parent level, **capped at 5
  steps**, `EdgeInsetsDirectional.start` so it grows from the left in LTR / the
  right in RTL). A node's stored `StoryNode.level` **no longer drives
  indentation.** A section member — the Your Story editor and the live content
  writers mint `upsert_fact_node` facts at `level: 2` with **no parent**, so they
  are flat section roots — renders **FLUSH at the section base**; a node indents
  only when it genuinely renders under a parent. The earlier level-floor
  (`max(level − 1, depth)`) pushed those parentless level-2 facts one step in, so
  they read as children of the standard item above them ("Interested in") —
  founder build 2495, "this indentation does not make sense." **`level` still
  drives node SIZE in the person-graph view (`person_graph_layout.dart`) — a
  separate surface, unchanged.** The six fixed About Me standard items stay
  ordered first (backend `_order_key`) and all render flush. Regression:
  `test/node_visualiser_test.dart` "REGRESSION: parentless level-2 section
  members render FLUSH at base level…", "six fixed About Me standard items render
  flush, in fixed order", "nested tree indents children by TRUE parentage", and
  "deep nesting never overflows at 320px / text-scale 2.0".
- **P6 (SHIPPED) — the final `LivingReportView` removal.** The last real host,
  Ayma's Notes' `story_ai_notes` body in `story_editor_screen.dart`, now renders
  through `GraphTreeView(surface: report, reportType: 'story_ai_notes')` — the
  same owner-only `/report/{type}/{id}/tree` path as appearance/match. With no
  host left, `living_report_view.dart` was **deleted outright**, along with its
  now-dead tests (`living_report_view_test.dart`,
  `living_report_freshness_test.dart`, `report_cache_swr_test.dart`). Every
  stale `LivingReportView` doc-comment across `lib/` was removed too. There are
  now **ZERO** `LivingReportView` references anywhere in `lib/`, pinned by
  `test/living_report_view_removed_test.dart` (fails if the symbol or the file
  reappears). `models/living_report.dart` + `ApiClient.getReport` stay — the
  Appearance screen's shareable-card fetch still uses the block model.

## NOTE 250 visualiser follow-ups (Nov 17 2026)

Refinements on the adopted visualiser surfaces:
- **Visibility on structured level-1 nodes** — `set_visibility[_cascade]` already
  accepts a seed node with no overlay entry (it writes a sparse `{visibility}`
  overlay that merges over the seed), so the Make public/private bubble flips a
  structured field ("Gender identity") the same as any node. Pinned by
  `tests/test_note250_visualiser.py`.
- **Delete always confirms** — the Photos-strip `PhotoDetailSheet` Delete button
  now shows a confirmation dialog before removing the image node (the node chat's
  Delete bubble already did), so no photo/bullet is deleted by a single tap.
- **Career LinkedIn button** — `career_timeline.linkedin_link_node(db, uid)`
  returns a public `link` node (the P0 link kind) built from the profile doc's
  `linkedin_url`; `routes/profile._inject_linkedin_button` prepends it to the
  Career section of the story / public-profile tree (adding the section if the
  person has no other public career nodes). Renders as the LinkedIn button via
  the shared NodeVisualiser link row (work-outline glyph, taps open).
- **Photo view reads the node** — `PhotoDetailSheet`'s visibility label now reads
  the image node's own `visibility` (not the ingestion source / a stale
  snapshot) and updates in place on a flip; it offers Make private when the node
  is public; and the is-you verdict says "Ayma read this but couldn't confirm
  it's you" (never "hasn't checked yet") when the node is `is_you: unknown` but
  carries a real image read. The node chat's image context card (`_NodeImageAttach`)
  applies the same two rules.

## P4 carousel — one image-node renderer (Nov 17 2026)

The profile photo carousel (`ProfilePhotoHeader`, `public_profile_screen.dart`)
now renders **each page through the ONE shared Node-Visualiser image-node
renderer** instead of a bespoke raw `AymaPhoto`:

- **`NodeImage` (`widgets/node_visualiser.dart`)** is the single renderer for a
  person-graph image node's photo. The inline `NodeVisualiser` uses it bounded
  (a 240px square + Ayma's read caption, tap handled by the node row); the
  carousel uses it `fill: true` — a full-bleed cover page, no caption. The
  visualiser's `_imageContent` was refactored onto it, so there is exactly one
  image-node renderer and the carousel can never drift from the inline one. The
  old bespoke per-photo `AymaPhoto` call inside the carousel `PageView` is
  **deleted**.
- The carousel's photos stay the profile's **own curated set** (`photos`;
  public readers read `photos` only), wrapped as minimal `StoryNode.image`
  nodes (`models/story_node.dart`) carrying only the URL — no read / is-you /
  provenance, since a curated profile photo is not a graph image node. The pager
  swipe, the `InlinePhotoStrip`/`_Filmstrip` filmstrip, the
  **`PhotoCarouselRegistry`** hook (so "show the Nth picture" over voice and
  chat still lands on the right page), and the owner inline **set-primary /
  delete** controls are all unchanged.
- Tapping a carousel page still opens the carousel's **own** fullscreen viewer
  (`AymaImageViewer.openGallery`, pinch/double-tap zoom, founder Nov 8), per
  `NodeVisualiser.onImageTap`'s documented contract ("the carousel passes its
  own viewer") — the carousel is **not** switched to the inline node-chat tap.
- `LivingReportView` is **not** touched (its deletion is P6). Tests:
  `test/carousel_node_visualiser_test.dart` (carousel renders image nodes +
  "show the Nth picture" lands), plus the unchanged
  `test/photo_carousel_command_test.dart` and
  `test/profile_photo_fullscreen_test.dart`.
## Career is part of Your Story — no dedicated view (build 2491, Nov 17 2026)

Build 2488 shipped a standalone **Career view** (`CareerViewScreen`,
`/profile/career`) — a dedicated list/timeline over the graph Career section.
The founder rejected the separate surface ("why do we have a separate career and
education — this should be just part of the story"), so build 2491 **deleted the
screen, its route, its Profile-tab row, its feature-tour entry, and its
`app_registry.json` destination**. Career is now a **normal section inside Your
Story** (`GraphTreeView(surface: story)`), rendered by the shared
Node-Visualiser exactly like every other section — same bullets, same
tap-opens-the-node-chat, same actions.

- **No schema change, data untouched**: the Career section nodes are exactly as
  before — the career seed nodes (`career_role_narrative`,
  `career_integration_vector`, `career_trajectory_narrative`,
  `work_schedule_pattern`, `education_level`), the injected LinkedIn link node
  (`career.linkedin`), and any **emergent** `page_type: "career"` children. They
  already render in Your Story because Career is a graph section. The read-only
  `dated` on each tree node (`person_graph_tree._node_dated`, first `Link.dated`
  else `""`) is still surfaced for whatever consumes it; no date schema was ever
  added and the deleted wiki-timeline subsystem stays deleted.
- **Navigation**: "open my career" / "my work history" / "education" aliases now
  resolve to the **`story`** (My story) destination in `app_registry.json`; there
  is no `career` destination and no `/profile/career` route.
- Tests: `tests/test_person_graph_tree.py::
  test_node_dated_surfaced_from_link_dated_only_where_present` (backend, the
  `dated` surfacing is unchanged) and the Story-surface rendering of the Career
  section in `ayma_flutter/test/story_editor_screen_test.dart` ("Story: the
  narrative renders through the Node-Visualiser"); `app_registry_test.dart`
  asserts no standalone career route remains.

## Career renders the editable timeline view over dated nodes (build 2502, Nov 18 2026)

Founder (build 2502, Career screenshot): "why is Career just a LinkedIn link —
where is the timeline pulled from LinkedIn, and it should be editable by users."
Settled spec: the LinkedIn link stays the **source link**; the Career section
renders the career graph nodes **as a timeline** where they carry dates,
**editable** through the usual node path. The deleted wiki-backed timeline
subsystem stays deleted; no new schema.

- **The timeline view is the generic palette, not a parallel widget.** A career
  node that carries a date (the read-only `dated` = first `Link.dated`, surfaced
  by `person_graph_tree._node_dated`) already defaults to a `timeline_entry`
  visual (`_default_visual`), and the shared `NodeVisualiser` renders consecutive
  dated siblings as ONE timeline rail (`_timelineRowWidget` /
  `_siblingWidgets`), each row tapping into the same node chat with the owner
  controls (Make public/private, Edit manually, Delete). The injected
  `career.linkedin` `link` node is not aggregatable, so it renders as the source
  link on top; the dated entries form the timeline below it.
- **Date ordering (the one build-2502 change).** `person_graph_tree
  ._order_timeline_siblings` orders a sibling list's **dated** entries by date,
  **most recent first** (the CV / LinkedIn convention), leaving every non-dated
  sibling in place. Applied to each section's roots in `node_tree` and to a
  node's `children` in `_build_node`. With fewer than two dated siblings it is a
  **no-op**, so an undated graph renders exactly as before and the Career
  timeline orders itself the moment dated role/company nodes exist. No backfill,
  no schema change, no invented date.
- **What is MISSING / the import still needed.** No career node carries a date
  today, so no timeline renders yet — the Career section shows the `career.linkedin`
  source link + the existing prose facts as `gist_row` bullets. Confirmed against
  the founder's live `ayma-staging` graph (`graph/main`, uid
  `iWhWjiWhEpU7iyu9B9vy7GlT0PD2`): 5 career nodes, all `answer_type=narrative` /
  `gist_row` (BTech, prior products, earlier background, autonomous-systems role
  ×2), and **zero of the 221 nodes carry a `dated` link**. There is **no LinkedIn
  import path** that creates dated role/company/period nodes: the only LinkedIn
  mechanism is the user-given `PF_LINKEDIN_URL` (`career_timeline`) surfaced as
  the link node + handed to `deep_dive`'s Gemini `url_context` as a research
  **source** (which writes prose, not dated nodes). **RESOLVED (founder order Nov
  18) — now built:** the LinkedIn→dated-node import below populates the timeline
  via the user's own data export (never scraping).
- Tests: `tests/test_person_graph_tree.py::
  test_career_dated_entries_render_as_an_editable_timeline_date_ordered` and
  `::test_career_without_dates_renders_bullets_not_a_fabricated_timeline`
  (backend ordering + no-fabrication); `tests/test_graph_tree_route.py::
  test_career_section_renders_linkedin_source_link_plus_prose_no_timeline`
  (end-to-end LinkedIn source link + prose, no timeline); and
  `ayma_flutter/test/node_visualiser_test.dart` — "Career: dated children render
  as an editable timeline…" + "Career: with NO dated children renders the
  LinkedIn source link + prose bullets…".

## LinkedIn work-history import — populates the Career timeline (founder order, Nov 18 2026)

The dated career nodes the timeline needs come from the user's own **LinkedIn
data export**, parsed deterministically — the only route that actually delivers
dated positions.

- **Route verified = data export, NOT OAuth.** Official "Sign in with LinkedIn
  (OpenID Connect)" grants only `openid`/`profile`/`email`; its published
  `claims_supported` carries name/email/picture and **no positions** — work
  history is restricted to partner programs Ayma is not in (verified against the
  LinkedIn OIDC reference, Nov 2026). Ayma holds no LinkedIn OAuth app or secret.
  So the user downloads their archive (LinkedIn → Settings → "Get a copy of your
  data") and uploads its **`Positions.csv`** (Company Name, Title, Description,
  Location, Started On, Finished On). No credentials, no multipart, **no
  scraping.**
- **Parse → dated nodes.** `linkedin_import.py` (`parse_positions_csv` →
  `import_positions`): tolerant header + date parsing ("MMM YYYY", ISO,
  year-only; blank Finished On → current → "… – Present"). Each role becomes one
  emergent `career`-section node written via `person_graph_store.add_loose_node`
  with a node-level **`dated`** (the start date — the timeline sort key), a
  `timeline_entry` visual, gist "Title · Company", and the `linkedin_import`
  SOURCE (`source_kind`/`source_ref`, per the node-sources rule).
- **Node-level `dated`.** A new optional `dated` field on `OverlayNode` /
  `GraphNode` (founder's "set the node's `dated` field" order — additive, no
  migration); `person_graph_tree._node_dated` prefers it over `Link.dated`. This
  is what the build-2502 note meant by "no schema change" being superseded: a
  single additive field, nothing migrated.
- **Dedupe vs prose career notes (fold or link, never two).** Before minting, a
  role whose company tokens **and** title tokens are both contained in an
  existing career node folds into it (`fold_into_node` + `set_node_dated`): the
  prose note gains the dates and moves onto the timeline — one node, not two.
  Stable per-role id (`linkedin.<company>__<title>`) makes a re-import idempotent.
- **Entry + endpoint.** `POST /profile/career/linkedin-import` (`{csv}` body).
  App: **Import from LinkedIn** — the work-history icon in Your Story's app bar
  and a Settings tile → `LinkedInImportScreen` (`/settings/linkedin-import`).
  Registered (`app_registry.json` → `linkedin_import`) and toured
  (`linkedin_import`, anchor `story_linkedin_import`).
- Tests: `tests/test_linkedin_import.py` (parse, dated nodes + source, timeline
  order, prose-note fold, idempotent re-import); `ayma_flutter/test/
  linkedin_import_test.dart` (screen flow + tour anchor).

## Live graph layout + highlight fix (person-graph-sections, Nov 17 2026)

Two founder-reported defects on the `/profile/graph` live force-directed view
(`person_graph_screen.dart` + `person_graph_layout.dart`), fixed together.

- **Part A — the layout was a collision-packed blob, not an organic mesh.** With
  Sections on, the founder saw the graph "destroyed" (black screen, pink streaks
  flung off-screen); with Sections hidden, two tight blobs. Diagnosis (reproduced
  on ~230-node founder-shaped data via a golden capture, not guessed): the
  `GraphSim._seed` **golden-angle spiral** placed consecutive-index nodes as far
  apart as possible, so every section's facts were scattered across the whole
  disk. Because the spring + repulsion forces are alpha-scaled (→0 at settle) but
  the no-overlap collision pass is **not**, the settled frame was dominated by
  collision packing → one uniform hex-packed disk with no hub-and-spoke lobes.
  Fix: seed the BFS spanning tree as a **radial sunburst** (centre at origin;
  sections fanned in angular sectors sized by subtree weight with a flat floor so
  small meta-hubs aren't crushed; facts seeded inside their section's sector at a
  larger radius), and re-tune the forces so equilibrium spacing exceeds the
  collision minimum: `_repel` 42→220 (cap 4→30, cutoff 400→900px), `_gravity`
  0.015→0.0035, longer spring rest lengths, `_alphaDecay` 0.035→0.0225. The graph
  now settles into a lobed organic mesh that `fitToViewport` keeps fully
  on-screen (section hubs included).
- **Part B — the tap highlight "didn't dim the rest".** The highlight SET
  (`graphHighlightSet` = self + ancestors + descendants + related) and the painter
  dim/lit passes were already correct; the symptom was Part A — in the packed blob
  the 230 overlapping nodes buried the dimming. The painter now routes every node
  through the pure `graphNodeLit(selectedId, highlight, id)` and every edge
  through `graphEdgeLit(...)`, so a render test can assert the dimming. Once the
  mesh is spread, a tap visibly lights only the connected set and dims the rest.
- **Tests:** `test/person_graph_layout_test.dart` — a ~230-node section-ful graph
  settles **bounded** (|x|,|y| < 3000, no NaN) and `fitToViewport` puts every node
  on-screen; the radial seed lobes each section's facts nearer their own hub than
  a sibling's. `test/person_graph_screen_test.dart` — `graphNodeLit`/`graphEdgeLit`
  light the connected set (incl. descendants) and dim non-members. Golden
  evidence: `test/goldens/person_graph_all_chips.png`,
  `test/goldens/person_graph_tapped.png`. No backend/inference change (100%
  LiveKit unaffected).

## Live graph layout — outlier + Fit crush fix (person-graph-layout-fix, build 2491)

After the Part-A sections fix, the founder still saw (build 2490, screenshot) a
thin **pink streak of edges shooting to one distant point** with every cluster
**crushed into a corner blob** — "is this a distance issue, why so far."

- **Root cause (reproduced on ~195-node founder-shaped data, not guessed):** an
  **edgeless node** — a cross-surface emergent fact (story / publicProfile /
  report / graphDetail) that never linked to a section — has **no spring** pulling
  it toward the graph. Under only the weak `_gravity` (0.0035) against full
  cluster repulsion it drifts out to the gravity/repulsion **equilibrium ring
  (~680px** at founder scale) while the connected tree stays at ~350px. That lone
  far node dominates `graphBounds`, so `fitToViewport` zooms far out (scale
  ~0.28) and the dense, readable cluster is squeezed into a corner; during the
  open animation the per-tick fit even follows the orphan outward (scale
  0.53→0.28). The "pink streak" is the fit framing an orphan whose rim position
  has nothing pulling it back.
- **Fix (force cause, not a post-hoc clamp):** in `GraphSim` every degree-0 node
  (except the centre) is given a **bounded virtual anchor spring** to the centre
  (`_orphanAnchorRest` 170px, `_orphanAnchorK` 0.045) — a layout-only pull, never
  a drawn edge — so an orphan settles **inside** the cluster like a real leaf
  (measured 143–280px, well within the ~350px median) instead of on the far ring.
  Orphans also **seed** on a tight ring near that rest radius (not the wide
  golden-angle spiral) so the fit stays framed on the cluster from the first
  frame. Integration now resets any non-finite position to the origin so a single
  stray NaN can never poison `graphBounds` and blank the whole graph. With no
  outlier, `fitToViewport` of all nodes frames the true, tight, spread cluster.
- **Tests:** `test/person_graph_outlier_fit_test.dart` — on a founder-shaped
  fixture (12 weighted sections of cross-surface facts + 5 edgeless orphans) the
  settled layout has **max distance ≤ 2.2× median** and **every orphan ≤ 1.2×
  median** (fail-before: orphans sat at ~580 over median ~325; pass-after: inside
  the cluster), and `fitToViewport` puts every node on-screen **and** the cluster
  fills ≥60% of the viewport width centred (not crushed to a corner).
  `test/person_graph_fit_screenshot_test.dart` — pumps the real
  `PersonGraphScreen` on founder-shaped data in reduced motion and captures the
  fitted open frame to `pg_layout_fitted.png` (fitted, spread, readable; no far
  streak). No backend/inference change (100% LiveKit unaffected).
## Gist-first rendering — the `gist` field (less-text-heavy Part 1, Nov 17 2026)

Every node tree now carries a **`gist`** on every node: a short punchy one-line
headline the Flutter surfaces render BY DEFAULT in place of the full prose,
which shows only on tap-in. This removes the "walls of text" the founder flagged
without hiding anything — the full `text` stays on the node for the tap target.

- **Contract (shared with `fleet/gist-first-writing` Part 3 + `fleet/visual-node-renderers` Part 2):**
  the field name is exactly **`gist`**. Part 3's writer produces it going
  forward; Part 1 derives a fallback for every existing node.
- **One shared derivation** — `node_gist.derive_gist(text, stored=None)`
  (`functions/bootstrap/node_gist.py`), applied at tree-build time to every node,
  NO per-node code: a stored `gist` wins; else the **first complete sentence** of
  `text` (split on `.`/`!`/`?` + whitespace) returned **IN FULL** — no length cap,
  never chopped mid-word, never an ellipsis (founder Leg 41, "no text should cut
  off partially"); a single run-on line with no sentence boundary is returned
  whole. Trailing sentence/list punctuation is stripped; whitespace/newlines are
  collapsed; it returns `""` only when there is neither a stored gist nor any
  text (a pure image node — the renderer then falls back to the node's content).
- **Trailing bracket tag preserved (NOTE 279 Leg 3, Nov 20 2026):** a terse
  bracket tag run at the very end of the line (e.g. `[Scout279]`, a citation
  `[1]`, a status `[draft]`) is metadata the user appended, not a second
  sentence — so `derive_gist` KEEPS it on the headline rather than dropping it
  off the tail with the rest of the prose. Without this, a bullet ending
  "…introverted nature. [Scout279]" rendered on the public profile and Your
  Story (both the `gist`-default surfaces) WITHOUT its marker, while the edit
  field — which shows the full `text`, not the gist — still showed it. The node
  `text` always round-trips the marker; this was never a save/read strip, only a
  gist-truncation drop on the default render.
- **Surfaced by** `person_graph_tree._build_node` (node + child-bullet dicts) and
  `report_tree._sections_to_tree` (over `_block_to_nodes`, which also passes a
  block's own `gist` through when present). The full `text` is never dropped.
- **Client** — `StoryNode.gist` + `StoryNode.displayGist` (gist → text → label).
  `NodeVisualiser` renders `displayGist` IN FULL (uncapped, no `maxLines`, no
  ellipsis — it wraps to its full height); the render faithfully paints whatever
  gist the backend serves and applies no text transform of its own, so a trailing
  marker that survives `derive_gist` reaches the pixels. The tap target is
  unchanged (the partial node chat with the full prose and the owner controls).
  Image nodes stay photo-forward. `displayGist` is the universal fallback text
  Part 2's `visual` field layers kind-keyed renderers on top of.
- **Tests:** `tests/test_node_gist.py` (incl. the NOTE 279 Leg 3 trailing-marker
  cases + the `person_graph_tree` render-path assertion that both surfaces share),
  `ayma_flutter/test/node_gist_render_test.dart`,
  `ayma_flutter/test/node_visualiser_test.dart` (a served gist with a trailing
  marker renders intact).
## Gist-first writing — the `gist` field (less-text-heavy program, Part 3, Nov 17 2026)

Every node written **going forward** carries a short one-line **`gist`** headline
(aim ≤ ~80 chars) plus at most a brief detail. The longer text stays in the
node's existing `answer`/prose field but shortened — never a long third-person
essay paragraph. Readers (Part 1, `fleet/gist-first-rendering`) render `gist` by
default and derive a fallback for OLD, gist-less nodes; this part makes the
**writers** emit `gist`. No backfill of old nodes.

- **Field.** `gist: Optional[str]` on `OverlayNode` and `GraphNode`
  (`person_graph.py`), merged in `merge_node`. Stored as `e["gist"]` by the store
  mint paths **only when non-empty**, alongside (never replacing) the node's
  other fields — so a node's `visibility` (private / public / ayma_only) and
  everything else round-trips through the writer **unchanged** (founder P0). The
  optional-param → `if gist: e["gist"] = gist` shape is deliberately trivial to
  extend to a sibling field (e.g. a future `visual`).
- **Store writers** accept an optional `gist=` kwarg: `set_answer`, `add_node`,
  `add_loose_node`, `upsert_fact_node` (`person_graph_store.py`).
  `upsert_report_node` is the non-rendering `report_doc` scaffold — no gist.
- **Creation paths now gist-first:**
  - *Conversation extraction* — `pg_add_node` (new required `gist` arg +
    description) and `remember` (new `gist` arg; `highlight` stays the brief
    detail) emit the headline directly; the LLM writes it.
  - *Web research* — `deep_dive.py` digest emits a `gist` (schema +
    `prompts/deep_dive.md § digest_system`, `summary` shortened to 1–2
    sentences); `skill_memory.save_web_findings` stores it on
    `emergent.skill.web_findings` (deterministic fallback headline when absent).
  - *Reports* — face/body reports' short `verdict` + `verdict_note`
    (`prompts/face_report.md`, `body_report.md`, now explicitly gist-first) become
    the gist via `skill_memory.save_face_analysis` / `save_body_analysis`;
    `save_physical_profile` derives a headline from the rendering's first line.
  - *Ayma's assessment* — each polarity node's gist is its group title + top
    observation (`ai_assessment._write_graph`; `prompts/ai_assessment.md`
    observations held to one punchy line).
  - *Match report* — `matching_skill` emits a required `gist` headline (schema +
    `prompts/matching_skill.md`) on the `matches/{key}` report doc.
- **Deliberately unchanged:** `set_profile_field` and raw questionnaire answers
  write atomic one-liner values (name/phone/DOB/enums) and the taste/steering
  nodes are short structured bodies, not essays — already gist-compliant by
  construction; they rely on the reader's `answer` fallback rather than a
  redundant per-node gist (keeps the rule generalizable, no per-node special
  casing).
- **Inference stays 100% on LiveKit** (the json writers are
  `gemini.generate_json` / the vision provider served **through** LiveKit); model
  names come only from `config.py`; every prompt lives in a `prompts/*.md` file —
  no inline prompt was added, none needed moving (all writers already load from
  files).
- **Tests:** `tests/test_gist_first_writing.py` (mock inference only) covers a
  conversation-extracted node, a report node, and a web-research node, plus the
  visibility-round-trips invariant and the digest/match writer-contract schemas.

## Write-time visual pick — the `visual` field (less-text-heavy program, Part 2 contract, Nov 17 2026)

Sibling of `gist`: every node written going forward also carries a **`visual`**
descriptor telling Part 2's renderers HOW to draw it, instead of defaulting
everything to a text row. "The visual lives on the node", picked
**deterministically at write time** so a bad pick is rare. Picking a visual
**never changes visibility** and **never blocks a write** — where the params'
data isn't readily available, only `{type, v}` is stored and the renderer
derives/falls back.

- **Shape.** `visual = {"type": <palette type>, "params": {...}, "v": 1}` on
  `OverlayNode`/`GraphNode`, merged in `merge_node`; stored as `e["visual"]` by
  the store mint paths alongside `gist`. Built via `node_visual.py` (the single
  source of the palette + builders). Same optional-write shape as `gist`.
- **PALETTE v1** (fixed, versioned — exact `type` strings): `gist_row`
  (universal fallback, renders `node.gist`), `chip_set`, `timeline_entry`,
  `bar_meter`, `gauge`, `card`, `photo_carousel`, `small_table`. Unknown/absent
  `type` → the reader falls back to `gist_row`.
- **`params` contract** (minimal, forward-compatible — what Part 2 reads):
  - `gist_row`: `{}` (renders `node.gist`)
  - `chip_set`: `{items: [string]}`
  - `timeline_entry`: `{date: string|null, title: string}`
  - `bar_meter` / `gauge`: `{value: number, min: number, max: number, label: string}`
  - `card`: `{title: string, body: string}` (`body` = the brief detail)
  - `photo_carousel`: `{image_refs: [...]}` (reuse the node's image ref fields;
    may be `{}` — the renderer derives refs from the image node's own fields)
  - `small_table`: `{columns: [string], rows: [[string]]}`
- **Per-kind default** (`node_visual.default_for(section, answer_type)`), applied
  in the store when a writer didn't pick one, so **no minted node is ever
  visual-less**. A plain PROSE fact is a BULLET — structure is NEVER fabricated
  from one prose sentence (founder build 2495: "I would rather have bullet
  points"; a card/chip around a sentence is the text-heavy problem wearing a
  bubble):
  - image node (`answer_type == "image"`) → `photo_carousel`
  - **everything else (all prose, every section) → `gist_row`**
  - A real diagram comes ONLY from an explicit writer pick that carries the
    structure (discrete `items` → `chip_set`; a numeric value+scale → `bar_meter`
    / `gauge`; a title+body finding → `card`), or, at READ time only, a
    `timeline_entry` for a node that ALREADY carries a real date
    (`person_graph_tree._default_visual` — timeline only WITH a date). The old
    per-section `chip_set` / `timeline_entry` defaults for undated prose are
    removed.
- **Explicit writer picks (unambiguous kind, set deterministically):**
  - face/body report + physical profile → `card` (`title` = verdict, `body` =
    verdict_note) via `skill_memory`
  - deep-dive web findings → `card` (`title` = gist, `body` = summary)
  - Ayma's assessment polarity node → `card` (`title` = group, `body` = top note)
  - match report → `gauge` (`value` = score, `min` 0 / `max` 100) in the
    `matches/{key}` doc payload
  - `pg_add_node` may also let Ayma name a `visual` type (palette enum); an
    unknown/absent one falls back to the per-section default.
- **Forward note (founder):** the write path is the same optional-param shape as
  `gist`, so `visual` dropped in with no new write mechanics — and any further
  sibling field does too.
- **Tests:** `tests/test_gist_first_writing.py` asserts the defaulted and
  explicit `visual.type` + params per path (and visibility round-trips);
  `tests/test_matching_skill.py` asserts the match gauge.

  **Extension (build 2491, 18:20 report): degree-1 + global containment.** A
  second screenshot found the lone far node with the Skills filter ON was the
  Ayma-assessment root — a DEGREE-1 node (one edge to its `sec:assess` hub), so
  the degree-0 anchor didn't cover it. Verified against the backend topology
  (`profile_graph._augment_with_store_nodes`: every store node hangs under its
  own `sec:<page_type>` hub which links to "me") and reproduced in-tree: a
  degree-1 node connected to the pinned centre (directly or via a hub) does NOT
  drift — its spring holds it at ~80–140px even when flung to (4000,−3000) — so a
  degree-1 drift is not a sim instability; the spring reels it. What the sim
  could NOT previously bound is a **weakly-connected component with no tie to the
  centre** (its internal spring satisfied far out, gravity too weak to reel it
  within the settle): flung to 6000 it stays at ~4000 (ratio ~14). Fix: a **soft
  global containment** in `GraphSim.step` — a self-scaling bound `max(600, 2.2 ×
  mean non-centre radius)` beyond which any node of any degree gets a gentle,
  capped (`_boundForceCap` 0.15) linear pull back toward it. The bound sits
  beyond where a spring reels a node, so interior and normally-sprung nodes feel
  nothing (the organic spread and the degree-0 anchor are untouched); only a
  genuine runaway is caught. With it the flung component settles at ratio ~1.7.
  Regression (`person_graph_outlier_fit_test.dart`): the degree-1 assessment
  root settles ≤ 1.2× median AND a Skills-filtered fit (hub + assessment only)
  frames it on-screen; a far-flung weakly-connected pair settles ≤ 2.5× median
  (fail-before ~14×). The acceptance screenshot is re-rendered with the Skills
  filter ON, showing the assessment inside the fitted cluster (no off-screen
  edge).
## Filter bar — Show all / Hide all master controls ✅ (founder, Nov 17 2026)

- The always-visible filter bar (`_FilterBar` in `lib/screens/person_graph_screen.dart`)
  gains two master controls alongside **Fit** and the per-type/per-level chips:
  **Show all** turns every filter on, **Hide all** turns every filter off, each in
  one tap. They drive the same shared filter state as the chips — `_showAllFilters`
  clears `_hiddenKinds`/`_hiddenLevels`; `_hideAllFilters` fills them with every
  present kind/depth — so individual chips keep toggling exactly as before after
  either control. Fit and the settled graph controls are unchanged.
- **Empty state (all filters off)** renders clean: `_GraphPainter` already skips
  any node or edge failing `passes(...)` (and the selected ring is gated on
  `passes(sel.id)`), and `_fitToVisible` falls back to all sim nodes when none are
  visible — no crash, no stray edges without nodes.
- **Tests** (`test/person_graph_screen_test.dart`, group "master filter controls"):
  Show all selects every chip; Hide all clears every chip and the empty canvas
  paints without exception; an individual chip still toggles after a master
  control. No route added (graph screen already registered) → no app_registry/tour
  change. No backend/inference change (100% LiveKit unaffected).
## Visual-first palette RENDERERS — the render side (less-text-heavy program, Part 2, Nov 17 2026)

The thin render side of "the visual lives on the node": the UI draws every node
through a fixed palette of renderers, one per `visual.type`, driven ENTIRELY by
the node's surfaced `visual` field — NO per-kind or per-report presentation
branching beyond the single dispatch. A new node of a known shape renders
visually with **zero new client code**.

- **Server — surface + read-time default.** `person_graph_tree._build_node`
  (node + child-bullet dicts) and `report_tree` now surface each node's
  **`visual`** alongside `gist`. A node with a STORED `visual` (the Part-3 writer
  picked one) passes through untouched — an unknown/newer `type` included. A node
  with none (every existing node — **NO backfill**) gets a READ-TIME default from
  `person_graph_tree._default_visual`: an image node → `photo_carousel`; a node
  that ALREADY carries a real date (`Link.dated`) → a `timeline_entry` carrying
  its gist + that date; **everything else (all prose) → `gist_row` — a BULLET,
  never a chip/card fabricated from one sentence** (founder build 2495).
  `report_tree` maps a numeric STAT block to `bar_meter` and defaults the rest to
  `gist_row` (a non-numeric CONFIDENCE word stays `gist_row` → its band pill). No
  node is ever visual-less.
- **Client — the palette (`widgets/node_visualiser.dart`).** `StoryNode.visual`
  (`NodeVisual {type, params, v}`, `NodeVisualType` mirrors `node_visual.py`) is
  read by ONE dispatch in `NodeVisualiser._content` on `node.visualType`:
  - `gist_row` → the Part-1 `displayGist` row (universal fallback).
  - `chip_set` → tappable chips from `params.items`.
  - `timeline_entry` → a dated rail entry from `params.date` + `params.title`.
  - `bar_meter` / `gauge` → a labelled `ScoreBar` from `params.value,min,max,label`.
  - `card` → a finding card from `params.title` + `params.body`.
  - `photo_carousel` → the shared `NodeImage` (image stays photo-forward).
  - `small_table` → a compact table from `params.columns,rows`.
  - Unknown/absent `type` or insufficient params → `gist_row` (never raw JSON,
    never a crash, never an overflow). The pre-existing node KINDS (stat / link /
    candidate) live in the gist-row fallback, so nothing regressed.
- **Aggregates (shared sibling renderer).** `_siblingWidgets` groups consecutive
  **leaf** siblings of one aggregating type into ONE visual — a merged chip set, a
  timeline on a shared rail — used by BOTH `NodeVisualiser` (a node's children)
  and `NodeVisualiserSection` (a section's roots), so the report framework
  (`fleet/visual-report-framework`) can reuse the renderers outside the graph.
- **P0 privacy & controls (founder, non-negotiable).** Aggregates are built ONLY
  from the already visibility-filtered node list (`_hasVisibleContentFor` runs
  before grouping on every surface), so a shared/public surface NEVER aggregates a
  private or Ayma-only node into a visual, score or COUNT; a visual can't leak a
  node onto a forbidden surface. Every rendered node stays fully controllable —
  a tap on a chip / timeline entry / bar / card / table row opens the SAME partial
  node chat + owner controls (Make public/private, Edit, Chat to edit, Delete) as
  a bullet (`_openNodeChat`). A visual that can't honor these falls back to
  `gist_row`. Deleting a node drops it from every aggregate in the same pass
  (aggregates are a pure function of the filtered node list).
- **Tests:** server — `tests/test_person_graph_tree.py` (every node carries a
  visual; career→timeline, interest→chip, stored wins, plain→gist_row),
  `tests/test_report_tree.py`. Client —
  `ayma_flutter/test/node_visual_palette_test.dart` (per-type render; unknown /
  insufficient → gist_row; per-visual tap-to-controls; privacy — private/Ayma-only
  never on public nor in an aggregate; delete drops from the aggregate; the
  palette mix overflow-free through the full layout matrix). Screenshot evidence:
  `ayma_flutter/test/goldens/palette_mix.png` (regenerated by
  `ayma_flutter/test/palette_screenshot_test.dart`).

## Live graph layout — real-graph force explosion + Hide-all filter fix (person-graph-layout-realfix, build 2495)

Two founder-gate defects on `/profile/graph`, reproduced on the founder's REAL
graph (uid `iWhWjiWh…`, read-only ayma-staging dump kept at
`ayma_flutter/test/fixtures/founder_real_graph.dart`: 122 nodes / 121 edges,
dominated by ONE `sec:assessment` hub with **96 degree-1 children**). The prior
synthetic fixtures (12 clean sections) never had a high-degree hub, so they
passed CI while his graph failed.

- **Bug 1 — the graph rendered as a PINK STREAK / comet tail (build 2495).**
  Verified cause (not a guess): the force sim EXPLODES on a high-degree hub. A
  node with ~95 neighbours inside `_repelCutoff` accumulates up to ~95 ×
  `_repelCap` (~2850) of velocity in ONE step, which the alpha cooling and 0.80
  velocity decay cannot absorb — so `sec:assessment` flies to ~1.17 MILLION px
  (its 96 children to ~12 000), the bounds go to aspect ~4.6 and `fitToViewport`
  clamps to scale 0.02, crushing the whole graph into an off-screen knot with a
  long edge "comet tail". The soft global containment did NOT catch it because it
  self-scales to the mean, which the explosion itself inflates. **Fix: a per-step
  velocity clamp (`_maxSpeed` 40)** in `GraphSim.step` — a node (or a hub pulled
  by dozens of child springs) can't move more than 40px/tick, so the integration
  stays stable and the real graph settles into a fitted mesh (ratio 98→2.6,
  aspect 4.6→1.2, fit scale 0.02→0.50). No equilibrium change for normal graphs
  (it only caps transient runaway). BEFORE/AFTER captured by
  `test/person_graph_real_screenshot_test.dart`.
- **Bug 2 — "Hide all → tap chips → EMPTY canvas".** `_passesFilter` AND-gates
  two facets (`_hiddenKinds` AND `_hiddenLevels`); `_hideAllFilters` hid every
  kind AND every level, so un-hiding one KIND chip left every level hidden → the
  chip lit but nothing rendered. **Fix: `toggleKindFilter`/`toggleLevelFilter`
  (pure, tested) release the vestigial all-hidden OTHER facet** when un-hiding
  from the Hide-all state, so tapping a chip after Hide all shows exactly that
  type. The old screen test only asserted the chip LIT (not that the canvas
  rendered) — it enshrined the bug; it now counts lit canvas pixels.
- **Tests:** `test/person_graph_real_layout_test.dart` — the real 122-node fixture
  settles finite, max ≤ 5× median (fail-before ~98×), bounds aspect ≤ 2.5
  (fail-before ~4.6), and `fitToViewport` frames every node on both axes with
  scale > 0.1 (fail-before clamped to 0.02). `test/person_graph_filter_state_test.dart`
  — Hide all = empty; tap a kind → exactly that type; tap more → ADD; symmetric
  level release; Show all → everything. `test/person_graph_screen_test.dart` — the
  "individual chip after a master control" test now counts non-background canvas
  pixels (empty-before, rendered-after). No backend/inference change (100% LiveKit
  unaffected). Screenshots: `pg_real_before.png` (streak), `pg_real_after.png`
  (fitted mesh).

## Related links between nodes (founder Nov 18 2026)

Founder's ask: "the graph only shows parent→child; RELATED nodes aren't
connected — an assessment node and a story node about the same thing, or the same
entity across sections (the dog that came up talking about family should link to
the other dog notes elsewhere)."

A related link reuses the existing first-class `StrictLinkType.RELATED` link
(`links:[{target, type:"related", label}]`, §2.4 / Contract 4) — the `label` is
the SHORT reason the two are linked. It is a reference, never a copy, and NEVER
changes a node's visibility/text/level.

- **Mutual.** If A links B, B reads as linked to A. `store.link_related` writes
  the link on whichever side(s) are overlay nodes; `person_graph.mutual_related`
  DERIVES the missing direction so every surface (render + lookup) sees the pair
  both ways even when the target is a seed node that can't store links.
  Helpers: `pg.related_targets(node)`, `pg.mutual_related(graph)`.
- **Level rule** (founder Nov 18, revised to **level 2 and up**). A related link
  connects ONLY nodes level 2 or deeper — BOTH ends. Levels 0 and 1 (You, and the
  top structure layer) never carry a link, as source or target; You stays level 0.
  `pg.eligible_for_related_link(a, b)` + `RELATED_MIN_LEVEL=2`; enforced in the
  write-time proposer AND the backfill dry-run (`dropped_by_level`).
- **Write-time proposer** (`person_graph_related.sweep_user`, flag
  `NODE_RELATED_PROPOSE`, off by default). Runs at session end AFTER ingest,
  ALONGSIDE the dedupe sweep — it does NOT change dedupe. It reuses the dedupe
  cross-check's candidate finder, drops level-0/1/2 pairs, then the LiveKit judge
  (`prompts/related_link_judge.md`, never rerouted off LiveKit) labels each:
  a CONFIDENT `related` is linked with the node (`store.link_related`); a same-fact
  `duplicate` is left to the dedupe path (never linked here); an UNCERTAIN one (or
  any judge failure) is RAISED in chat via the settled `record_pending_dedupe`
  flow — surfaced by `pg_find_duplicates`, NEVER linked silently; `unrelated` is
  dropped. Already-linked / dismissed pairs are skipped.
- **Same-fact → `duplicate` (held-apply fix, Nov 18).** The judge prompt
  (`prompts/related_link_judge.md`) was tightened so a pair that restates the SAME
  underlying request/fact — even when one is phrased as a general capability and
  the other as a concrete feature/UI, or differs in wording or specificity —
  returns `duplicate` (→ dedupe path), reserving `related` for genuinely different
  facts that must BOTH survive. (Tripwire: "clear all notifications" ↔ "add a
  'Mark all as read' button to clear all notifications" is one request → DEDUPE,
  never a link.)
- **Batched judge — no truncation.** `person_graph_related._judge` judges pairs in
  bounded batches (`_JUDGE_BATCH=24`, per-batch `max_tokens = 256 + n*48`) instead
  of one hardcoded `max_tokens=1024` call that silently TRUNCATED the verdict JSON
  past ~40 pairs (the same bug class the dedupe judge fixed by batching). Each item
  keeps its GLOBAL `i`, so verdicts merge positionally across batches; a single
  failing batch skips only its own pairs.
- **Bare-numeric-seed drop.** A node whose entire value is a bare number (a slider
  seed, e.g. `social_energy`=4) carries no relational meaning; two such nodes
  "match" only on the digit (via embedding cosine between near-identical one-token
  texts). Those pairs (`_is_bare_numeric`) are dropped from the candidate set
  before the judge (`dropped_numeric`), so they are neither linked nor raised.
- **Dedupe-consumable reason data** (founder amendment 2). A confident link
  stores its reason as the link `label`; `crosscheck.related_link_pairs(graph)`
  yields `(a, b, reason)` candidate pairs from stored related links so the dedupe
  path can treat a linked pair as the FIRST place to look for a duplicate. This is
  DATA SHAPE ONLY — it triggers no merge and does not un-hold the dedupe branch.
- **Lookup** (`graph_lookup` / `connected_node_ids`) already surfaces a node's
  related nodes and one hop out (then that node's subtree) so Ayma sees a topic is
  already covered elsewhere and doesn't ask twice.

### Privacy (HARD rule)

A surface only ever TRAVERSES links between nodes the viewer MAY see. A public
node linking to a private/Ayma-only node must NOT leak it — not the target id,
not its reason label — on the public profile or any shared surface.

- **Render:** `profile_graph._filter_related_to_visible` drops any related link
  whose target is not in THIS payload's visible node set (resolving the `b:<id>`
  bullet form), applied to both `get_graph` (owner) and `public_graph` (public).
- **Lookup:** `connected_node_ids(..., allowed_vis=...)` only follows a related
  edge (and the ancestor/descendant walk) between nodes in the viewer's visibility
  set; `graph_lookup(public_only=True)` / `include_ayma_only=False` pass it.
- Tests: `tests/test_related_links_privacy.py` (render drops the cross-visibility
  link + reason; `graph_lookup(public_only)` never reaches a private related node).

### Render

- **Distinct line.** The person graph draws a related link as a DASHED accent line
  (`_GraphPainter._paintRelatedEdge`), visually distinct from the solid gradient
  parent→child tree edges; it dims/lights with the selection like a tree edge.
- **Tap highlight.** Tapping a node lights its ancestors + descendants + related
  nodes (`graphHighlightSet` already folds in `relatedAdj`); the rest dims.
- **Node visualiser.** The detail panel shows a tappable "Related" chips row
  (`_RelatedRow`, `relatedChipLabel`) — each related note opens in the panel. The
  chips come from the visibility-filtered flat payload, so a private note never
  shows on a shared graph.

## Root "You" is the biggest node (founder Nov 18 2026)

The centre "You" node is now rendered STRICTLY larger than every section hub and
every leaf, in EVERY state (full view, filtered views, tap/highlight). Render-only
— no data/level/visibility change. `person_graph_layout.rootNodeRadius` (34) is a
fixed radius strictly above `nodeRadiusForLevel` at every level; the root `SimNode`
is built with `isRoot: true` so the boost flows through layout, collision and
hit-testing. It is independent of level/filter/highlight scaling (highlight changes
colour/halo not radius; filters only hide other nodes). Only the actual root id is
boosted — a stray level-0 node is not. Tests: `test/person_graph_layout_test.dart`
("root is the biggest" group). Scout verifies on the founder graph on-device.

## Standard fields render ICON + value; min/max pair is ONE range row (build 2502 fix)

Two RENDER-ONLY rules in `node_visualiser.dart` (stored nodes/data unchanged —
inference untouched, still LiveKit):

- **Standard (predefined) field → ICON + value, NO word label.** A node whose id
  is in `person_graph.STANDARD_FIELDS` renders a fixed per-field `Icons.*` in
  place of its bullet, then the bare value — no "Name:"/"Location:" text. The
  icon is `node_field_icon_<id>`, coloured by the node's visibility
  (`nodeVisibilityColor(subtreeVisibility)` — green public / yellow private /
  violet Ayma-only), so privacy still reads at a glance. The icon map (keyed by
  field id, same icon on Your Story and the public profile):
  `legal_first_name → person_outline`, `date_of_birth → cake_outlined`,
  `gender_identity → wc_outlined`, `primary_location → location_on_outlined`,
  `target_match_genders → favorite_border`, `ethnic_cultural_origin →
  public_outlined`. A standard field with NO mapped icon keeps its visibility
  bullet and shows value-only (no confusing glyph). Prose/conversational nodes
  are unchanged — coloured bullet + gist. Fixed order, values and tap (opens the
  node in the partial chat) are unchanged. Extend the icon map alongside
  `STANDARD_FIELDS`.
- **What I'm Looking For standard fields → ICON + "label: value" (build 2507).**
  The three Looking-For fields keep their label in front of the value because the
  value alone is ambiguous — so they render icon + `<label>: <value>`, NOT the
  icon + bare value of About Me. They were added to `person_graph.STANDARD_FIELDS`
  (so they are standard, labelled and fixed-ordered for EVERY user graph) with a
  10+ `order` band that ranks them within the `looking_for` section only, and to
  `_standardFieldIcons` + `_labeledStandardFields` in `node_visualiser.dart`. The
  map: `relocation_radius → radar_outlined` ("Relocation / travel radius: Within
  about 50 km"), `geographic_flexibility → flight_takeoff_outlined` ("Geographic
  flexibility: …"). The partner-age COMBINED range row (below) also gets a fixed
  icon, keyed on the pair BASE in `_rangePairIcons` (`partner_age →
  groups_outlined`), rendered INSTEAD of its bullet in the same visibility colour,
  keeping "Partner age preference: 21–56". Fixed Looking-For order (backend-driven
  by `STANDARD_FIELDS` order): partner age preference → relocation / travel radius
  → geographic flexibility, then the conversational bullets (plain, unchanged).
  Visibility is unchanged — none of these are in `_PUBLIC_ALLOWLIST`, so they
  default private like any other structured fact (P0).
- **"Interested in" is a Looking-For field, and the public profile does not
  repeat its photo-header fields (build 2509, founder).** Two render-placement
  fixes, no value/visibility change:
  - `target_match_genders` ("Interested in") was in the `identity` (About Me)
    section; it is a What-I'm-Looking-For fact, so its seed `page_type`
    (`question_tree.json`) moved to `looking_for` and its `STANDARD_FIELDS`
    `order` to `9` — so it LEADS the Looking-For section (before partner age at
    10). A SECTION assignment, not a render tweak, so it moves on EVERY surface
    (public profile AND Your Story). It stays in `_PUBLIC_ALLOWLIST` (public).
  - On the **public profile** surface (`SURFACE_PUBLIC`), the photo header
    (`ProfilePhotoHeader`, from `GET /explore/profile/{uid}`) already shows
    name/age/location, so `person_graph_tree.node_tree` skips those standard rows
    (`_HEADER_FIELD_IDS = {legal_first_name, date_of_birth, primary_location}`)
    from About Me — each appears exactly once, in the header. They stay in
    `_standard_facts_by_section`, so a prose/editor bullet restating them is still
    suppressed (the single surviving copy is the header). **Your Story has no
    photo header** (just a `_StoryCover`), so these rows are NOT skipped there —
    the de-dup is public-surface only. Prose bullets (e.g. "His full name is …")
    are standard-field rows' neighbours, not standard rows, so they are untouched.
    Tests: `functions/bootstrap/tests/test_person_graph_tree.py`
    (`test_public_profile_omits_header_fields_from_about_me`,
    `test_story_keeps_header_fields_in_about_me`,
    `test_interested_in_renders_under_looking_for_not_about_me`).
  - **The header de-dup must be applied in TWO public render paths, not one
    (NOTE 261 follow-on, build 2513).** The 2509 fix above only touched
    `person_graph_tree.node_tree` — the Node-Visualiser *tree* surface
    (`GET /profile/graph/tree/{uid}`). But the public-profile SCREEN's main body
    is a **Living Report**: `public_profile_screen.dart` → `_api.publicProfile`
    → `report_hub` (`public_profile` / `story_public`) → `report_adapters.
    _public_bullet_sections` → `public_profile.public_bullet_sections` →
    `person_graph_render.public_sections(graph)`. That second path did NOT
    suppress the header rows, so About Me still repeated name/age/location on the
    screen Scout tests. The fix: `person_graph_render.public_sections` now passes
    `drop_header_fields=True` into `_sections_with_bullets`, skipping
    `person_graph.HEADER_FIELD_IDS` on the public render only (Your Story /
    persona / grounding keep the rows — no photo header). The set is defined once
    in `person_graph.HEADER_FIELD_IDS`. (At this point the tree path still kept its
    own `person_graph_tree._HEADER_FIELD_IDS` id-drop; NOTE 264 below replaced it
    with the shared `_public_fact_placement` predicate so the surfaces cannot
    drift.) The `target_match_genders` → `looking_for` section
    move (above) is honored by this path with no extra code, because the seed
    `section` is read from `question_tree.json`'s `page_type`. Tests:
    `functions/bootstrap/tests/test_person_graph_render.py`
    (`test_note261_your_story_keeps_header_rows_no_photo_header`).
  - **The id-based drop missed the real leak: editor-identity DUPLICATES
    (NOTE 263, build 2515 → fix).** The 2513 follow-on skipped only
    `n.id in HEADER_FIELD_IDS`. But the bullets that actually render in About Me
    on the live profile are not those canonical nodes — they are
    `emergent.editor.identity.*` DUPLICATES a header import left behind
    (`.0` = "Age: 29", `.1` = "Gender identity: Man", `.4` = "Interested in:
    Women"). Their ids are not in `HEADER_FIELD_IDS`, so the id drop never matched
    them, and because the global text-dedup saw the identity-section
    "Interested in: Women" duplicate FIRST, it suppressed the canonical
    `target_match_genders` bullet in `looking_for` — so that section vanished
    entirely. (The 2515 in-memory test used synthetic canonical-id nodes, so it
    passed while the real fixture shape slipped past — verified live against
    `users/demo-test1/graph/main` on ayma-staging.) The fix routes EVERY node on
    the public surface through one predicate,
    `person_graph_render._public_fact_placement(graph, node)`, which returns
    `drop` / `move`/`keep`:
      - a header fact (name/age/location) — the canonical seed node OR an
        editor-owned emergent duplicate of one (matched by the FACT it restates
        via `_editor_restated_standard` → the high-precision
        `text_restates_standard_fact`, not by id) — is **dropped** (the photo
        header shows it);
      - an editor-owned emergent duplicate of a NON-header standard fact in the
        wrong section (the `identity` "Interested in: …" duplicate of the
        `looking_for` `target_match_genders`) is **moved** to that fact's
        canonical section, so What I'm Looking For appears with it even when the
        section's own canonical bullets are private, and About Me loses it;
      - an editor-owned emergent duplicate of a same-section standard fact (a
        second "Gender identity: Man" beside the canonical Gender row) is
        **dropped** — the canonical standard node is the single source for that
        row. **Gender is NOT a header field** (the photo header shows only
        name/age/location, and the Flutter client never reads the top-level
        `gender` payload field), so Gender still renders in About Me exactly once,
        from the canonical node — removing it would erase gender from the public
        profile. Tests:
        `functions/bootstrap/tests/test_person_graph_render.py`
        (`test_note263_editor_identity_duplicates_drop_and_relocate_real_fixture`,
        `test_note263_interested_in_relocates_even_when_canonical_is_private`).
  - **The SAME fix had to reach the GRAPH-TREE path the app actually renders, and
    the duplicate drop had to become surface-aware (NOTE 264, build 2517 → fix).**
    The NOTE 263 fix landed in `person_graph_render.public_sections` (the Living
    Report path). But the app's public profile is drawn by **GraphTreeView** from
    `person_graph_tree.node_tree(surface="publicProfile")` — a THIRD path that was
    still doing the id-only `n.id in _HEADER_FIELD_IDS` drop, so on device About Me
    still leaked "Age: 29 / Austin / Interested in: Women" (the editor duplicates).
    The fix routes the tree's public walk through the SAME
    `render._public_fact_placement`, and the old `_HEADER_FIELD_IDS` alias/import in
    `person_graph_tree` is deleted (the one predicate in `person_graph_render` now
    owns the decision). Making the three surfaces share that one predicate exposed
    a latent bug it had to fix: the same-section/relocation drop was NOT surface-
    aware. The two public renderers format a standard row differently — the Living
    Report inlines `label: value` ("Interested in: Women"), the Node-Visualiser
    keeps label and value apart (bullet text just "Women") — so a moved editor
    duplicate collided textually (and deduped) in the report but rendered TWICE in
    the tree (canonical "Women" + moved "Interested in: Women"). `_public_fact_
    placement` is now surface-aware: an editor duplicate of a non-header standard
    fact is **dropped wherever it sits when the canonical row renders publicly**
    (the canonical is the single source — it shows the fact in its own section),
    and is **moved/kept only when the canonical is PRIVATE** (then the public editor
    bullet is the sole public copy and must survive, or the fact vanishes). Net:
    all three surfaces now agree on CONTENT — gender once in About Me, the
    Interested-in fact once under What I'm Looking For, nothing duplicated — while
    each keeps its own row formatting. Tests:
    `test_person_graph_tree.py`
    (`test_note264_graphtree_public_drops_editor_identity_header_duplicates`,
    `test_note264_graphtree_story_keeps_header_fields`,
    `test_public_surface_keeps_fact_when_standard_row_is_private`) and
    `test_person_graph_render.py`
    (`test_note264_public_restatement_of_private_standard_survives`).
  - **The SELF route has to be allowed to request the publicProfile surface
    (NOTE 265, build 2518 → fix).** The predicate above was correct, and the
    other-member route `GET /profile/graph/tree/{uid}` (which hard-codes
    `publicProfile`) was deduped — but the founder viewing his OWN profile hits the
    SELF route `GET /profile/graph/tree?surface=publicProfile` (uid = caller, no
    target), and that handler (`routes/profile.py`) coerced any surface outside
    `{story, report, graphDetail}` to `story`. So the self preview rendered the
    STORY owner set (private nodes + no public suppression) and still leaked
    `Age: 29` / `Austin` / `Interested in: Women` into About Me, while the
    other-member view was clean — the exact 2518 split. Fix: add `publicProfile`
    to the self route's surface allowlist (one line). It stays the caller's OWN
    graph, filtered to public nodes, so nothing private leaks; `_tree_payload`
    already handled `publicProfile` downstream (the LinkedIn button). Tests:
    `test_graph_tree_route.py`
    (`test_self_route_publicprofile_dedups_like_other_member_route` — the self and
    other-member public views are now identical, section-for-section;
    `test_self_route_publicprofile_not_coerced_to_story` — the self publicProfile
    surface excludes the private loose nodes the story coercion would have shown).
- **Hero photo: progressive thumb under the full-res fade — no flat-dark flash
  (NOTE 266 Obs 2, build 2519).** The carousel hero renders at `displayWidth: 900`
  (`NodeImage(fill)` → `AymaPhoto`), which decodes a large variant on the
  disk-resize path. On first entry that variant is fetched COLD (the Explore
  prefetch warms only the 260px thumb — a different `CachedNetworkImageProvider`
  key — and the founder's self-profile has no prior card to warm it at all), so
  the hero sat on `AymaPhoto`'s flat `surfaceContainerHighest` placeholder until
  the big image arrived — read on-device as "the hero is dark on first entry and
  settles after scroll" (the scroll is coincidental; the photo paints when the
  large variant finishes, not because of the scroll). Fix: `AymaPhoto` gained an
  opt-in `placeholderUrl` (a small low-res variant painted UNDER the fade, on the
  non-stalling plain path, falling back to the flat tile); `NodeImage` threads it
  through; the hero carousel passes the aligned `thumb_400` (`stripPhotos`, the
  same variant the filmstrip already loads — small, fast cold, usually already on
  disk). So a cold hero shows the thumb instantly and the full-res sharpens in
  over it. Every other `AymaPhoto` caller passes no `placeholderUrl` and keeps the
  flat placeholder unchanged. Tests: `ayma_photo_test.dart` (thumb painted under a
  hung full-res; null/equal-URL keep the flat tile, no self-wait),
  `carousel_node_visualiser_test.dart` (hero wires the aligned thumb; null without
  a distinct thumb list).
- **Two more hero surfaces the carousel fix didn't reach (NOTE 267, build 2520).**
  The NOTE 266 fix covered only the profile hero carousel. Two sibling surfaces
  still flashed flat-dark:
  - **(a) Other-member profile opens on a flat-dark "Loading this profile…"**
    (`PublicProfileScreen`, from Explore). The progressive thumb can't paint
    because the photo URLs arrive with the still-in-flight `GET /explore/profile/{uid}`.
    Fix: a generalizable seed handoff — `PublicProfileScreen` gained
    `seedPhotoUrl` + `seedName`; while the GET is in flight and a seed is present
    it renders a real header skeleton (`_LoadingHeader`: the square photo + bottom
    scrim + name + small spinner) that paints the seed photo, which the Explore
    card already prefetched (so it's instant). The router reads the seed from
    go_router `extra`; the Explore card passes `{photoUrl: card.gridPhotoUrl, name:
    card.name}` on push. No seed (chat, deep link) → the existing loader, unchanged.
    Not per-person special-casing — any caller may seed; it's the card's own photo.
  - **(b) Story cover hero** (`_StoryCover` in `story_editor_screen.dart`, the
    `displayWidth: 600` cover) got the NOTE 266 treatment directly: the screen
    captures `p.thumbPhotos.first` alongside `detailPhotos.first` and passes it as
    the cover `AymaPhoto`'s `placeholderUrl`, so the cover fades in over its thumb.
  - Tests: `public_profile_screen_test.dart` (seeded load shows the seed photo +
    name, not the "Loading this profile…" wall; no seed → the plain loader),
    `story_editor_screen_test.dart` (the cover hero carries its thumb variant as
    `placeholderUrl`).
- **Why the thumb fix had nothing to fade, and why grid tiles stuck on initials
  (NOTE 268, build 2521).** The 2521 retest found the cover hero *absent* (no
  node at all — the NOTE 267 thumb had nothing to fade) and Explore grid photos
  stuck on initials for 25+ min, while DM avatars loaded. Verified live on
  ayma-staging: the server returns valid photo URLs for both the self
  `GET /explore/profile/{uid}` (cover) and the `/explore` cards (demo-test1 +
  real accounts), identical to the `/profiles/mini` photo DM uses — so **neither
  was a server or client-parse defect.** Both were one-shot loads that never
  recover:
  - **(a) Cover hero absent** — `_loadMainPhoto` fetched the cover photo with a
    *separate*, **un-retried** `publicProfile` call (silent catch), unlike the
    story fetch in `_load` which rides `withColdStartRetry`. A single cold-start
    / stressed-start miss (the 2521 first-launch ANR window) blanked the hero
    permanently (no node) while the retried story photos still rendered — the
    sailboat tile with no hero above it. Fix: wrap it in `withColdStartRetry`
    (guard empty uid), so the hero self-heals like every other on-open load.
  - **(b) Grid tiles / cold hero stuck — the shared photo path.** `AymaPhoto`'s
    10s stall guard (PC8) was **terminal**: `if (_stalled) return error` dropped
    the tile to its fallback and cancelled the in-flight load, only resetting on
    a widget change (scroll / re-mount). So a grid of full-size originals that
    stalled under cold-start contention stuck on initials until scrolled away and
    back — and it's exactly why the NOTE 266/267 hero "settled only after a
    scroll". Fix: the stall is now **bounded self-healing** — on a stall it waits
    `_kStallRetryDelay` and re-attempts with a bumped attempt suffix (a fresh
    `CachedNetworkImage` key → new fetch), up to `_kMaxStallRetries`, then the
    terminal fallback. A tile recovers on its own once the backend warms; a
    genuinely-dead URL still gives up (bounded ~36s), never churning forever.
  - Tests: `ayma_photo_test.dart` (a stalled tile re-attempts — attempt suffix
    bumps `@0→@1→@2` — and only falls back once retries are spent),
    `story_editor_screen_test.dart` (a cold-start failure of the cover fetch
    retries and the hero renders, instead of staying absent).
  - Not a code defect: the 2521 DEBUG ANR cluster (6 in ~45 min) is the known
    debug-JIT / first-launch artifact family (AOT launched clean) — it is the
    *trigger* that made these one-shot-load gaps visible, not a bug itself.
- **Why the seeded header painted the NAME at 2s but not the PHOTO, and why the
  story hero area collapsed (NOTE 269, build 2522).** The 2522 retest found the
  NOTE 267 Explore seed half-working: on first entry the `_LoadingHeader` seeded
  the name instantly but the photo stayed flat-dark for ~12s, though the card
  photo was already on screen at tap; a cached re-entry was clean.
  - **(a) Seeded header photo decode mismatch — `public_profile_screen.dart`.**
    The Explore grid (`_Photo`) and `prefetchCardPhotos` decode the card photo at
    `displayWidth: 260`, but `_LoadingHeader` requested the *same URL* at
    `displayWidth: 400`. Flutter's `ImageCache` keys on the resize dimension
    (`memCacheWidth = displayWidth × dpr`), so 260 and 400 are **different cache
    entries**: the grid's live, already-decoded entry was never reused and the
    header forced a cold decode (the ~12s flat-dark under first-launch
    contention); re-entry was clean because the header's own 400-entry was then
    warm. Fix: `_LoadingHeader` decodes at `displayWidth: 260`, matching the grid,
    so the seed reuses the warm decode and paints at once — first entry now looks
    like a cached re-entry. Same pixels the user just tapped; the full-res hero
    replaces it when the GET lands.
  - **(b) Story cover hero area collapsed while the GET retried — `story_editor_
    screen.dart`.** The cover block was omitted entirely whenever `heroPhotoUrl`
    was null, which covers *both* "still loading" and "no photo". So during the
    cold-start-retried `_loadMainPhoto` (up to ~12s) the hero area was a
    photo-less gap that then popped the photo in — and the NOTE 267 thumb could
    never be observed because its URL arrives with the same GET as the full photo.
    The thumb URL is only known once that one GET lands, so there is nothing to
    paint before it. Fix: a `_mainPhotoLoading` flag distinguishes "loading" from
    "resolved, no photo"; while loading, the cover **reserves** the rounded 4/3
    frame with a calm surface (`Key('storyCoverLoadingHero')`) instead of
    collapsing, and the real hero fades into that same frame over its thumb when
    the GET resolves. A genuine no-photo state still omits the hero, unchanged.
  - Tests: `public_profile_screen_test.dart` (the seed photo is requested at the
    grid width 260, not 400), `story_editor_screen_test.dart` (while the gated
    cover GET is in flight the reserved hero frame is present and the hero photo
    is not, then the hero fades into it once the GET lands).
- **Why the story hero still showed only shimmer at 2s — two gaps the NOTE 269
  reservation could not reach (NOTE 272, build 2524).** The 2524 retest found the
  seeded Explore header PASS but the story hero thumb never visible at 2s — only
  the skeleton's shimmer bars — though the hero rendered by ~12s. Two causes, both
  in `story_editor_screen.dart`:
  - **(a) The hero load was sequenced behind the story fetch.** `_loadMainPhoto`
    was fired *after* `await storyGet()`, and `storyGet` is itself
    cold-start-retried — so on a cold open the hero GET did not even start until
    the story body returned (~12s), which is exactly why "the hero rendered by
    12s". Fix: fire it in parallel with the story fetch (`_seedAndLoadMainPhoto`),
    so it races instead of waiting.
  - **(b) At 2s the cover was not even on screen — the whole screen was the
    top-level `_StorySkeleton` (pure text-bar shimmer, no hero area) while
    `storyGet` was still in flight.** And the thumb URL only arrives with the
    (cold) `publicProfile` GET, so on a cold backend *no* request can deliver the
    thumb by 2s. Fix: a tiny per-user persistent cache of the **last-known thumb
    URL** (`MainPhotoCache`, `shared_preferences`) — the thumb's *bytes* already
    survive a force-stop in `cached_network_image`'s on-disk cache (keyed by URL),
    so the cached URL paints the hero from disk with no network, at ~2s. The hero
    is now rendered *inside* the skeleton (one shared `_CoverHero` widget, in its
    final position after the title/subtitle bars), so the cached thumb shows while
    the body loads; the fresh `publicProfile` result then replaces it (the fresh
    full photo fading over its fresh thumb) and re-persists the thumb for the next
    cold open. Keyed by uid (never a previous account's photo); a stale cached
    thumb (the user changed their primary) is replaced within the same open. No
    cached thumb → the NOTE 269 reserved frame, unchanged.
  - Tests: `main_photo_cache_test.dart` (save/load/clear, uid-keyed, no
    cross-user leak), `story_editor_screen_test.dart` (a cached thumb paints the
    `_CoverHero` in the loading skeleton at the grid width 400 and is not the
    reserved blank, then the fresh full hero replaces it and the fresh thumb is
    persisted; and with no cache the reserved frame still holds).
- **A `<base>_min` + `<base>_max` pair → ONE range row, never two bars.** The
  write-time backfill picks `bar_meter` for each numeric end, which is WRONG for
  a two-ended range. At the SECTION level (`_siblingWidgets`) the renderer scans
  the siblings for a min/max pair (by the field ids, with a Youngest/Oldest label
  fallback) and, when BOTH ends are present, renders ONE combined row —
  "Partner age preference: 21–56" (youngest–oldest) — with NO bar for either end,
  ignoring the stored `bar_meter`. The combined label derives from the shared
  base (`partner_age → "Partner age preference"`; any other base → the shared
  quantity from the two labels). A LONE end (no partner) renders as a plain
  labelled row, also no bar. Genuine single scale traits (`social_energy`,
  `cleanliness_index`, …) have no `_min`/`_max` and still render as bars.
  As of build 2507 the combined/lone range row also carries the base-keyed
  `_rangePairIcons` icon in place of the bullet (same visibility colour).
  Tests: `test/node_visualiser_test.dart` (standard-field ICON render + min/max
  range row groups + the three Looking-For icon/label:value rows + fixed order).
