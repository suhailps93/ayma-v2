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
    visibility / links / bad input. **Follow-up (not done):** the live wiring —
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
- **Level-indent render rule (`fleet/level-indentation`, Nov 17 2026).** The
  `NodeVisualiser` indents each row by the node's **actual `level`** in the tree
  (`(level − 1)` indent steps of 18 dp), not by recursion depth — floored at the
  render depth so a nested child is always ≥1 step deeper than its parent, and
  **capped at 5 steps** so deep nesting wraps instead of running off a narrow
  phone. The indent is `EdgeInsetsDirectional.start`, so it grows from the left
  in LTR and the right in RTL. This fixes the founder's flat Story (build 2488):
  the Your Story editor and the live content writers mint `upsert_fact_node`
  facts at `level: 2` with **no parent**, so they render as flat section roots;
  indenting by recursion depth alone left every one of them flush with the
  level-1 standard block. The standard labelled rows (level 1) stay flush; only
  the conversational children step in. Report nodes are all `level: 1` (flat),
  so report surfaces are unaffected. Regression: `test/node_visualiser_test.dart`
  "parentless roots indent by their actual level" + "deep nesting never
  overflows at 320px / text-scale 2.0".
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
## Dedicated Career view (Nov 17 2026, "B-widened" — no schema change)

The founder's settled answer to the A/B/C career-timeline question: a **dedicated
Career view** that is a *presentation* over the existing graph Career section,
**not** a new data model. Option A (dated start/end fields on a node, node
migration, or resurrecting the deleted wiki-timeline subsystem) is **rejected** —
there is no career date schema and none is added.

- **Screen**: `CareerViewScreen` (`/profile/career`,
  `ayma_flutter/lib/screens/career_view_screen.dart`), reachable from the "Career
  & education" row on the Profile tab and via Ayma (`career` destination in
  `app_registry.json`, aliases "career / my work history / my timeline /
  education / …"). It loads the owner story tree (`GET /profile/graph/tree?
  surface=story`) and renders **only** the `career` section's nodes — the career
  seed nodes (`career_role_narrative`, `career_integration_vector`,
  `career_trajectory_narrative`, `work_schedule_pattern`, `education_level`), the
  injected LinkedIn link node (`career.linkedin`), and any **emergent** career
  children (`page_type: "career"`) the graph has grown — as an editable list.
- **Dates only where already present**: `person_graph_tree._node_dated` surfaces
  a read-only `dated` field on **every** tree node, populated from the first
  `Link.dated` on the node (`Link.dated` / `HistoryEntry.date` are the only
  date-ish fields in the model) and `""` otherwise. The Career view renders a
  timeline-style date beside an entry **only** when `dated` is non-empty;
  undated entries list with no date. No date is invented, no node migrated.
- **Editing reuses the generic paths**: each entry is a real `NodeVisualiser`, so
  a tap opens the same partial node chat directly (the owner actions ride inside
  it as the `NodeActionBubbles` row) and drives the same
  `/profile/graph/node/{id}/{visibility,text,add-child,delete}` endpoints as the
  generic Node-Visualiser — no duplicate edit path. Per-node visibility is
  respected: a public-tree viewer (the public-profile surface) only ever sees
  public career nodes; this view is owner-only.
- Tests: `tests/test_person_graph_tree.py::
  test_node_dated_surfaced_from_link_dated_only_where_present` (backend) and
  `ayma_flutter/test/career_view_test.dart` (lists seed + LinkedIn + emergent,
  dates only where present, edit persists through the node-edit path).

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
