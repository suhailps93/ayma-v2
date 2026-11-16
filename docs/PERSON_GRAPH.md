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

  All three 5b read switches share `PERSON_GRAPH_READS` — flip it only after the
  graph is migrated for the account under test; flag-off is today's reads
  exactly across scorer, report and sims.
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
  - *Reports-as-views + image nodes.* NEXT.
- **7 — cutover + delete** (wiki write path, old report/assessment docs). GATED
  on founder post-switch re-verification.
