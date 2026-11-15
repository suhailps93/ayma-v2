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

## Phases 2–7 — planned (design §10)

2. Graph store (`users/{uid}/graph`) + the 5 tools (`set_answer`, `set_weight`,
   `set_visibility`, `add_node`, `query_nodes`) + relationship-type registry.
3. Renders — `render_story`, `render_public_profile`, persona/match-report.
4. Migration — questionnaire answers / profile fields / wiki / assessment → overlay.
5. Consumers switch — sims, match report, deterministic scorer, per-user
   emergent gates; delete old stores.
6. Guided flow by level; reports-as-views + image nodes; completeness tiers
   (Surface / Core / Deep / Uncharted).
7. Cutover + delete — wiki write path and old report/assessment docs removed.
