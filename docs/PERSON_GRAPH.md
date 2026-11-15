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

## Phases 5, 6b, 7 — gated on real-account verification (design §9–§10)

The remaining work switches live consumers and **deletes** the old stores. The
design gates deletion on migration being verified against real accounts first
("old documents are kept read-only until the graph path is verified, then
deleted"). That verification is Astro's post-merge job, so these are held until
the foundation (Phases 1–4) is confirmed against real data:

5. Consumers switch — sims, match report, deterministic scorer, per-user
   emergent gates; **delete old stores**.
6b. Guided flow by level (completeness/Ayma order read levels, delete the old
    core/deep gate); reports-as-views + image nodes.
7. Cutover + delete — wiki write path and old report/assessment docs removed.
