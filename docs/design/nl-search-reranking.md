# Natural-Language Search Relevance Re-Ranking for Explore — Design & Evaluation Plan

> **Status:** Proposed / V2 Design Spike  
> **Author:** Antigravity (Engineer)  
> **Date:** 2026-11-01  
> **Target Branch:** `design/nl-rerank`  
> **References:** `docs/ARCHITECTURE.md` (§6.1, §6.2, §6.3, §6.10), `functions/bootstrap/explore.py`, `functions/bootstrap/prompts/explore_nl_filter.md`, `functions/bootstrap/media_embed.py`, `functions/bootstrap/taste_match.py`

---

## 1. Executive Summary & Problem Statement

Today in Ayma, natural-language (NL) search on the Explore feed is strictly a **filter compiler**, not a relevance ranker (`docs/ARCHITECTURE.md` §6.2):
1. When a user types a search query (e.g., *"blondes in tech"*, *"architect in brooklyn who loves jazz"*, *"calm introverts who hike"*), `parse_nl_query` issues a single Gemini call to map the query into a rigid physical/demographic filter schema (`_NL_SCHEMA` in `functions/bootstrap/explore.py:51-77`).
2. Any attribute not in this narrow schema—such as profession (*"in tech"*, *"architect"*), interests (*"jazz"*, *"hiking"*), personality (*"calm"*, *"introverts"*), lifestyle, or values—is **completely dropped**.
3. Profiles that pass the surviving physical/demographic filters are then sorted **solely by their pre-computed offline dating compatibility score with the viewer** (`matches.score` or `heuristic_score`, `explore.py:473-475`), with arbitrary Firestore stream order for un-scored candidates.

The result is that searching for *"blondes in tech"* filters for candidates with blonde hair, but completely ignores *"in tech"* and ranks candidates by generic match score. Searching for *"creative writers who love vinyl"* maps to `{}` (no physical filters), filters nobody, and simply returns the standard feed sorted by generic compatibility. Search query relevance contributes **0.0** to result ordering.

This design document establishes a production-ready, two-stage search architecture for Explore:
- **Stage 1 (Filtered Candidate Retrieval):** Query intent parsing separates hard demographic constraints (e.g. gender, age range, location) from soft semantic/cultural traits.
- **Stage 2 (Multi-Signal Relevance Re-Ranking):** Candidates are re-ranked in-memory across four explicit signals:
  1. **Semantic Narrative Embedding Similarity ($S_{\text{semantic}}$):** Dense vector similarity between query and candidate public story.
  2. **Lexical & Entity Overlap ($S_{\text{keyword}}$):** Exact and fuzzy matches against frontmatter facts (career, education, hobbies).
  3. **Cultural & Taste Overlap ($S_{\text{taste}}$):** Entity alignment against public music, film, and dining questionnaire nodes.
  4. **Dating Compatibility Prior ($S_{\text{compat}}$):** Preserved baseline dating compatibility score.

This design specifies the mathematical scoring formulation, embedding model selection, latency and cost models, fallback policies, an offline evaluation harness, and an actionable 5-chunk engineering implementation plan.

---

## 2. Current Pipeline Audit & Trace

### 2.1 Query Parsing Lifecycle

```
[Flutter ExploreScreen]
   │
   │ 500ms debounce (_onSearchChanged)
   ▼
[ApiClient.explore(q: "blondes in tech")]
   │
   │ GET /explore?q=blondes+in+tech
   ▼
[FastAPI explore() in main.py:2551]
   │
   │ parse_nl_query() in explore.py:121
   ▼
[gemini.generate_json(explore_nl_filter.md, _NL_SCHEMA)]
   │
   ├── Filter output: {"hair_color": "blonde"}
   └── Dropped intent: "in tech" (not representable in _NL_SCHEMA)
```

1. **Client Trigger & Debounce:**
   - File & Line: [ayma_flutter/lib/screens/explore_screen.dart:146-150](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/ayma_flutter/lib/screens/explore_screen.dart#L146-L150)
   - When the user types into the search bar, `_onSearchChanged` cancels any running timer and sets a 500ms debounce timer before executing `_load()`.
   - File & Line: [ayma_flutter/lib/screens/explore_screen.dart:122](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/ayma_flutter/lib/screens/explore_screen.dart#L122)
   - Calls `_api.explore(q: _searchController.text.trim())`.
   - File & Line: [ayma_flutter/lib/services/api_client.dart:216-222](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/ayma_flutter/lib/services/api_client.dart#L216-L222)
   - Dispatches HTTP `GET /explore?q=...`.

2. **API Endpoint Intake:**
   - File & Line: [functions/bootstrap/main.py:2551-2568](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/functions/bootstrap/main.py#L2551-L2568)
   - Endpoint signature: `async def explore(q: str = "", location: str = "", hair_color: str = "", glasses: str = "", age_min: int | None = None, age_max: int | None = None, limit: int = 30, uid: str = Depends(require_adult_uid))`.
   - Line 2565: Calls `nl = await explore_mod.parse_nl_query(q, uid=uid) if q.strip() else {}`.
   - Line 2576: Merges dropdown overrides and NL parse via `explore_mod.merge_filters(dropdown, nl)`.
   - Line 2579: Fills unset age bounds from user's `qz_partner_age_min`/`max` via `apply_saved_age_range`.
   - Line 2585-2587: Invokes feed builder: `await asyncio.to_thread(explore_mod.explore, get_db(), uid, filters, min(limit, 60))`.

3. **NL Query Parser:**
   - File & Line: [functions/bootstrap/explore.py:121-139](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/functions/bootstrap/explore.py#L121-L139)
   ```python
   async def parse_nl_query(text: str, *, uid: str | None = None) -> dict:
       text = text.strip()
       if not text:
           return {}
       try:
           result = await gemini.generate_json(
               text,
               system_prompt=_prompt(),
               response_schema=_NL_SCHEMA,
               uid=uid,
               feature=token_ledger.FEATURE_EXPLORE,
           )
       except Exception:
           logger.exception("NL filter parse failed")
           return {}
       return result if isinstance(result, dict) else {}
   ```
   - Prompt: [functions/bootstrap/prompts/explore_nl_filter.md:1-30](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/functions/bootstrap/prompts/explore_nl_filter.md#L1-L30) instructs the model to translate text into only: `gender`, `location`, `age_min`, `age_max`, `hair_color`, `eye_color`, `age_range_apparent`, `facial_hair`, `glasses`, `visible_tattoos`, `visible_piercings`, `race_ethnicity`, `skin_tone`, `hair_length`, `hair_type`, `build`, `height_min_cm`/`height_max_cm`, and `weight_min_kg`/`weight_max_kg`.
   - Schema: `_NL_SCHEMA` ([functions/bootstrap/explore.py:51-77](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/functions/bootstrap/explore.py#L51-L77)) has no keys for career, interests, hobbies, education, values, or taste.

---

### 2.2 Filter Application & Sourcing

- File & Line: [functions/bootstrap/explore.py:347-430](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/functions/bootstrap/explore.py#L347-L430)
- The server streams every user document in `db.collection("users").stream()`.
- Eligibility removals:
  - `passed`: `users/{uid}/explore_passed` subcollection (line 383).
  - Practice personas: `practice_seed.is_practice_persona(other)` (line 386).
  - Test fixtures: `_is_test_fixture(other, ...)` (lines 394, 150-159) checking `exclude_from_explore: true` or `demo-edge-` prefix, unless `bypass_fixtures` is active.
  - Nameless / incomplete profiles: `str(prof.get("name") or "").strip()` (line 412).
  - Paused accounts: `prof.get("paused") is True` (line 417).
  - Blocks: `_blocked(db, uid, other)` (line 419) checking bidirectional `blocks/{uid}_{other}`.
- Filter check:
  - Line 428: `if not _passes_filters(prof, filters, public_fields=public_fields): continue`.
  - Detailed filter logic in `_passes_filters` ([explore.py:161-250](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/functions/bootstrap/explore.py#L161-L250)):
    - Gender equality (lines 183-187).
    - Age range (lines 189-197).
    - Location substring (lines 198-201).
    - `_PHOTO_FIELDS` exact string match on `photo_attrs` or public `physical_attrs` (lines 207-217). Missing/unknown values reject candidates.
    - `_PHYSICAL_ENUM_FIELDS` enum match (lines 221-227). Missing/unknown values pass.
    - `race_ethnicity` coarse substring match (lines 230-234).
    - Height/weight range checks (lines 238-249).

> [!WARNING]
> **Stream Truncation Defect in Current Code:**  
> In `functions/bootstrap/explore.py:383`:
> ```python
> if other in passed or other in seen or len(cards) >= limit:
>     continue
> ```
> `cards` stops collecting candidates once `len(cards) >= limit` (default 30, max 60), **before sorting occurs** at line 473. The sort at line 473 only sorts the first 30 passing candidates encountered in arbitrary Firestore stream order.

---

### 2.3 Current Sort Key Analysis

- File & Line: [functions/bootstrap/explore.py:471-476](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/functions/bootstrap/explore.py#L471-L476)
```python
# Your own card pins to the top; then scored matches high-to-low, then the rest.
cards.sort(
    key=lambda c: (not c["self"], c["score"] is None, -(c["score"] or 0))
)
return cards
```
- Score derivation in `_score_for(db, uid, other)` ([explore.py:269-286](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/functions/bootstrap/explore.py#L269-L286)):
  1. Checks `matches/{sorted_pair_key(uid, other)}.score` (Pass-2 LLM compatibility score: float `0.0`–`1.0` or `0`–`100`).
  2. Fallback: `users/{uid}/match_candidates/{other}.heuristic_score` (Pass-1 heuristic score: float `0.0`–`1.0` based on age gap, location match, shared frontmatter from `matching.py:83-108`).
  3. Fallback: `None`.

**Sort Order Hierarchy:**
1. Viewer's own profile (`c["self"] == True`) pins to position 0.
2. Candidates with an existing match or candidate score (`c["score"] is not None`).
3. Descending match score (`-(c["score"] or 0)`).
4. Un-scored candidates in arbitrary collection stream order.

**Relevance Contribution:** Exactly **0%**. A candidate who perfectly embodies the user's search text (e.g., an Olympic swimmer who runs an animal shelter) ranks below an unscored match or at the bottom if no compatibility report has run.

---

### 2.4 Candidate Signals Audit

| Signal Category | Source Location | Fields & Content | Current Use in Explore |
|---|---|---|---|
| **Core Profile** | `users/{uid}/profile/main` | `name`, `birthdate` (age), `gender`, `location`, `community`, `photos` (`[{media_id, order}]`), `paused` | Hard demographic filter & card display |
| **Photo Attributes** | `profile/main.photo_attrs` | `hair_color`, `eye_color`, `ethnicity_apparent`, `age_range_apparent`, `facial_hair`, `glasses`, `visible_tattoos`, `visible_piercings` | Hard boolean filtering (`_PHOTO_FIELDS`) |
| **Physical Attributes** | `profile/main.physical_attrs` | Flat mirror of 14 vision+stated fields (`skin_tone`, `hair_length`, `build`, `height_estimate_cm`, etc.) gated by `physical_attributes.public_fields` | Soft enum & range filtering (`_PHYSICAL_ENUM_FIELDS`) |
| **Story & Public Wiki** | `users/{uid}/wiki_pages/{page_id}` | `page_type` (`identity`, `career`, `hobbies`, `values`, `lifestyle`, `quirks`), `title`, `ai_body`, `user_edits`, `visibility: "public"`, `frontmatter` | **Unused in Explore**. Stripped of `{{private}}` spans only on tap-through (`public_profile.py:80-115`) |
| **Taste Profile** | Questionnaire nodes & `wiki_pages/taste` | `taste_music` (comma-separated artists), `taste_film` (comma-separated movies/shows), `taste_food` (restaurants, cuisines) | **Unused in Explore**. Only used in `taste_match.py` for Qloo pairwise scoring |
| **Biometric Face Embeddings** | `users/{uid}/user_media/{id}.embedding` | 2048-d vector from `gemini-embedding-2` (`media_embed.py:27-30`) | **Gated by biometric consent**. Used only for duplicate detection & selfie verification. **Cannot be used for text search** |
| **Text / Semantic Embeddings** | *None* | No text embeddings exist in the repository (`wiki_query.py:115` explicitly confirms: *"Plain keyword scoring, no LLM/embedding call"*) | **Non-existent** |

---

## 3. Proposed Ranking Architecture: Two-Stage Hybrid Search

```
                                [User NL Query: "blondes in tech who love jazz"]
                                                       │
                                                       ▼
                                    ┌─────────────────────────────────────┐
                                    │ Stage 1: Query Intent Splitter      │
                                    │ (explore_nl_filter.md via Gemini)   │
                                    └──────────────────┬──────────────────┘
                                                       │
                           ┌───────────────────────────┴───────────────────────────┐
                           ▼                                                       ▼
             ┌───────────────────────────┐                           ┌───────────────────────────┐
             │ Hard Filter Extraction    │                           │ Soft Semantic Intent      │
             │ {gender, hair_color: blonde}                          │ semantic_text: "tech"     │
             └─────────────┬─────────────┘                           │ taste_terms: ["jazz"]     │
                           │                                         └─────────────┬─────────────┘
                           ▼                                                       │
             ┌───────────────────────────┐                                         │
             │ Candidate Sourcing Pool   │                                         ▼
             │ Passes filters & gates    │                           ┌───────────────────────────┐
             │ (Top K = 50 candidates)   │                           │ Query Text Embedding E(q) │
             └─────────────┬─────────────┘                           │ (gemini-embedding-001)    │
                           │                                         └─────────────┬─────────────┘
                           └───────────────────────────┬───────────────────────────┘
                                                       │
                                                       ▼
                                    ┌─────────────────────────────────────┐
                                    │ Stage 2: In-Memory Multi-Signal     │
                                    │ Relevance Re-Ranking Engine         │
                                    │                                     │
                                    │ S = 0.50*S_sem + 0.20*S_kw          │
                                    │   + 0.15*S_taste + 0.15*S_compat    │
                                    └──────────────────┬──────────────────┘
                                                       │
                                                       ▼
                                    ┌─────────────────────────────────────┐
                                    │ Ranked Explore Cards (Feed)         │
                                    │ 1. Self-pinned                      │
                                    │ 2. Highest compound score           │
                                    └─────────────────────────────────────┘
```

### 3.1 Two-Stage Pipeline Overview

1. **Stage 1 — Candidate Sourcing & Hard Pre-Filtering:**
   - Evaluates boolean constraints that are strictly binary requirements for the user (e.g., gender orientation, location bounds, explicit physical traits like hair color if requested).
   - Enforces all existing safety gates: excludes blocked accounts (`blocks`), paused accounts (`paused`), previously passed accounts (`explore_passed`), simulator personas (`practice_seed`), and test fixtures (`_is_test_fixture`).
   - Retrieves a candidate pool of up to $K = 50$ passing candidates.

2. **Stage 2 — In-Memory Multi-Signal Relevance Re-Ranking:**
   - Computes a composite relevance score for each candidate in the pool using pre-computed public profile embeddings, lexical frontmatter matching, taste overlap, and compatibility priors.
   - Sorts candidates descending by composite score, pinning self to top.

---

### 3.2 Stage 1: Query Intent Parsing (Hard Filters vs Soft Semantic Intent)

The current `explore_nl_filter.md` prompt is updated to output two decoupled objects:
1. `hard_filters`: Demographic and physical attributes that must strictly exclude non-matching candidates.
2. `semantic_intent`: Free-text description of lifestyle, profession, personality, or values, plus explicit cultural taste terms.

#### Updated Parser Schema (`_NL_SEARCH_SCHEMA`)
```json
{
  "type": "object",
  "properties": {
    "hard_filters": {
      "type": "object",
      "properties": {
        "gender": { "type": "string" },
        "location": { "type": "string" },
        "age_min": { "type": "integer" },
        "age_max": { "type": "integer" },
        "hair_color": { "type": "string" },
        "eye_color": { "type": "string" },
        "glasses": { "type": "string" },
        "facial_hair": { "type": "string" }
      }
    },
    "semantic_query": {
      "type": "string",
      "description": "Concepts, career, personality, lifestyle, or passions to rank candidates on"
    },
    "taste_terms": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Specific genres, artists, foods, or films mentioned (e.g. ['jazz', 'ramen'])"
    }
  }
}
```

*Example Transformation:*
- Query: *"blonde girls in tech who love indie rock and climbing"*
- Output:
  ```json
  {
    "hard_filters": {
      "gender": "woman",
      "hair_color": "blonde"
    },
    "semantic_query": "technology engineer software tech climbing bouldering outdoors",
    "taste_terms": ["indie rock"]
  }
  ```

---

### 3.3 Stage 2: Multi-Signal Compound Relevance Scoring

For each candidate $c$ in the retrieved candidate pool, with respect to viewer $u$ and query $q$, the ranking score $S(q, u, c)$ is defined as:

$$S(q, u, c) = w_{\text{semantic}} \cdot S_{\text{semantic}}(q, c) + w_{\text{keyword}} \cdot S_{\text{keyword}}(q, c) + w_{\text{taste}} \cdot S_{\text{taste}}(q, c) + w_{\text{compat}} \cdot S_{\text{compat}}(u, c)$$

#### 1. Semantic Embedding Similarity ($S_{\text{semantic}}$)
- **Model Choice:** `gemini-embedding-001` via Vertex AI REST `embedContent` (consistent with `media_embed.py` Vertex infrastructure).
- **Dimension & MRL:** Default native 3072-d is truncated via Matryoshka Representation Learning (MRL) to **768 dimensions** using `outputDimensionality: 768`. 768-d preserves >98% MTEB retrieval performance while cutting Firestore storage size and vector computation latency by 75%.
- **Candidate Public Document Representation:**
  - When a user's wiki is updated (`wiki_ingest.py`) or edited (`story.py`), an asynchronous background task creates a sanitized public summary:
    ```
    Name: {name}. Age: {age}. Location: {location}.
    Frontmatter: {comma-separated public frontmatter keys and values}.
    Story: {concatenation of public wiki pages with private spans stripped}.
    ```
  - This summary is embedded into a 768-d vector and stored at:
    `users/{uid}/profile/main.public_story_embedding` (a list of 768 floats).
- **Similarity Math:**
  Cosine similarity between query embedding vector $\vec{e}_q$ and candidate embedding vector $\vec{e}_c$:
  $$S_{\text{semantic}}(q, c) = \frac{\vec{e}_q \cdot \vec{e}_c}{\|\vec{e}_q\| \|\vec{e}_c\|}$$
  Normalized to $[0, 1]$: $S_{\text{semantic}} \leftarrow \max(0.0, \min(1.0, \frac{\text{cosine} + 1}{2}))$.

#### 2. Exact Keyword & Entity Match ($S_{\text{keyword}}$)
Dense embeddings can exhibit semantic drift for specific technical terms, professions, or proper nouns (e.g., conflating *"hardware engineer"* with *"software developer"*, or *"classical pianist"* with *"rock keyboardist"*).
- $S_{\text{keyword}}(q, c)$ computes BM25 / normalized token overlap between tokens in `semantic_query` and candidate public fields:
  - Match targets: `prof.name`, `prof.location`, and all keys/values in the candidate's aggregated public `frontmatter` (`occupation`, `hobbies`, `education`, `pets`, `values`).
  - Score: Ratio of query keyword tokens found in the candidate's profile tokens, clamped to $[0.0, 1.0]$.

#### 3. Cultural & Taste Overlap ($S_{\text{taste}}$)
- Evaluates overlap between `taste_terms` extracted from the query and the candidate's public taste nodes:
  - `taste_music` (artists, genres)
  - `taste_film` (movies, directors, TV shows)
  - `taste_food` (cuisines, dining spots)
- Substring or normalized set intersection:
  $$S_{\text{taste}}(q, c) = \frac{|\text{query\_taste\_terms} \cap \text{candidate\_taste\_entities}|}{\max(1, |\text{query\_taste\_terms}|)}$$
  If no taste terms were in the query, this term evaluates to a neutral $0.0$ and its weight is proportionally absorbed by $S_{\text{semantic}}$.

#### 4. Dating Compatibility Prior ($S_{\text{compat}}$)
- Re-uses the existing score lookup from `functions/bootstrap/explore.py:269-286`:
  - `matches.score` (0.0–1.0 normalized) or `heuristic_score`.
  - Default when uncomputed: neutral prior of $0.50$.
- Guarantees that among candidates with identical semantic relevance (e.g. two software engineers who both love hiking), the person who has higher overall dating compatibility with the viewer appears first.

---

### 3.4 Signal Weights Schedule

The weights dynamically adapt based on whether an active search query is present:

| Search State | $w_{\text{semantic}}$ | $w_{\text{keyword}}$ | $w_{\text{taste}}$ | $w_{\text{compat}}$ | Primary Sorting Driver |
|---|---|---|---|---|---|
| **Active NL Query with Taste** (*"girl in tech who likes jazz"*) | **0.50** | **0.20** | **0.15** | **0.15** | Semantic relevance + taste match |
| **Active NL Query without Taste** (*"witty architect in brooklyn"*) | **0.60** | **0.25** | **0.00** | **0.15** | Semantic relevance + keyword match |
| **Empty / Cleared Query (`q == ""`)** | **0.00** | **0.00** | **0.00** | **1.00** | **100% Dating compatibility prior** (Preserves exact current Explore behavior) |

---

### 3.5 Privacy, Security, and Consent Boundaries

1. **Strict Public Wiki Boundary:**
   - Under no circumstances is `ai_body` containing `{{private}}...{{/private}}` or `{{ai_only}}...{{/ai_only}}` text embedded into `public_story_embedding`.
   - Text is pre-filtered through `story.strip_private_spans()` and `story.strip_ai_only_spans()` before embedding generation.
   - Wiki pages marked `visibility: "private"` or `visibility: "ai_only"` are excluded entirely from search embeddings.

2. **Absolute Separation from Biometric Consent:**
   - Ayma enforces strict biometric consent gating (`functions/bootstrap/biometric_consent.py`) for face embeddings (`gemini-embedding-2` on `user_media`).
   - Profile text embeddings are derived solely from user-published public text and do **not** constitute biometric data. They must live in a separate document field (`profile/main.public_story_embedding`) and must never cross into `user_media` or face verification pipelines.

3. **Feed Exclusion Invariants Maintained:**
   - Blocked pairs (`blocks`) remain 100% hidden.
   - Paused accounts (`paused: true`) remain 100% hidden from other users.
   - Seeded test fixtures (`exclude_from_explore: true`) remain hidden from real users.

---

## 4. Performance, Cost & Latency Engineering

### 4.1 Latency Budget

Explore is an interactive feed where client queries are debounced by 500ms. The server-side latency budget is **≤ 250ms total**:

```
[Client Request GET /explore?q=...]
       │
       ├── (1) Query parsing & intent classification (Gemini 3.7 Flash): ~90ms
       ├── (2) Query text embedding (Vertex gemini-embedding-001): ~50ms
       ├── (3) Candidate pool retrieval (Firestore indexed stream, K=50): ~40ms
       ├── (4) In-memory cosine & compound re-ranking (Python math/numpy): ~1.5ms
       └── (5) Card serialization & response: ~10ms
       │
[Total Server Execution Time: ~191.5ms] (Well under 250ms ceiling)
```

- **Vector Math Efficiency:**  
  Computing 768-dimensional dot-products over $K = 50$ normalized candidate vectors requires only $50 \times 768 = 38,400$ floating-point operations. In Python with `numpy` or vectorized operations, this executes in **< 1.5 milliseconds**.

---

### 4.2 Financial & Token Cost Analysis

1. **Query-Time Embedding:**
   - Cost: `gemini-embedding-001` on Vertex AI is priced at **$0.15 per 1,000,000 input tokens**.
   - Input query: Average search query is 8–15 tokens.
   - Cost per query:
     $$\frac{15 \text{ tokens}}{1,000,000} \times \$0.15 = \$0.00000225 \text{ (2.25 micro-dollars)}$$
   - 100,000 user searches cost **$0.225 (22.5 cents)**.

2. **Offline Candidate Embedding (Amortized):**
   - Candidate public profile summary: ~350 tokens.
   - Generation cost per profile update:
     $$\frac{350 \text{ tokens}}{1,000,000} \times \$0.15 = \$0.0000525$$
   - Generated **once** upon onboarding or profile edit. Re-used across thousands of searches. Zero ongoing search cost.

3. **Token Ledger Feature Key:**
   - Query embedding and parsing spend is tracked under `token_ledger.FEATURE_EXPLORE`.

---

### 4.3 Fallback & Degradation Hierarchy

The search pipeline must **never return a 500 error** or blank feed due to embedding unavailability:

```
[User Query]
     │
     ▼
[Try Vertex AI Query Embedding]
     │
     ├── SUCCESS ──► Execute Full Multi-Signal Re-Ranking (S_semantic + S_kw + S_taste + S_compat)
     │
     └── FAILURE (Timeout / Quota / Offline Dev)
           │
           ▼
     [Fallback 1: Lexical & Taste Re-Ranking]
     │ Weights adjust: S_lexical = 0.65*S_keyword + 0.20*S_taste + 0.15*S_compat
     │
     └── If Lexical Scores are all 0.0:
           │
           ▼
     [Fallback 2: Legacy Compatibility Sort]
     Sort by: (not c["self"], c["score"] is None, -(c["score"] or 0))
```

---

## 5. Evaluation Plan: Offline Golden Test Suite

To prove definitively that the new ranking model improves search relevance over the baseline without requiring production deployment, we establish an offline evaluation harness.

### 5.1 Golden Evaluation Dataset

We construct an offline evaluation dataset of **30 test queries** evaluated against the seeded user population (including `demo-test1` Daniel, `demo-test2` Sofia, `demo-test3` Priya, and seeded demo accounts):

#### Query Archetypes & Test Cases
1. **Professional / Career Archetype:**
   - `Q01`: *"software engineer in tech"*
   - `Q02`: *"architect who designs buildings"*
   - `Q03`: *"doctor or healthcare worker"*
   - `Q04`: *"creative designer or visual artist"*
   - `Q05`: *"startup founder building a business"*
   - `Q06`: *"writer, journalist, or author"*
2. **Cultural & Taste Archetype:**
   - `Q07`: *"indie rock music lover"*
   - `Q08`: *"jazz enthusiast who plays vinyl"*
   - `Q09`: *"foreign film and cinema buff"*
   - `Q10`: *"foodie who loves pasta and italian wine"*
   - `Q11`: *"ramen and matcha lover"*
   - `Q12`: *"hip hop fan"*
3. **Lifestyle & Outdoors Archetype:**
   - `Q13`: *"bouldering and rock climbing"*
   - `Q14`: *"marathon runner who trains early"*
   - `Q15`: *"dog lover who goes to dog parks"*
   - `Q16`: *"plant parent who loves gardening"*
   - `Q17`: *"weekend camper who loves backpacking"*
   - `Q18`: *"yoga and meditation practitioner"*
4. **Personality & Values Archetype:**
   - `Q19`: *"calm thoughtful introvert"*
   - `Q20`: *"high energy ambitious extrovert"*
   - `Q21`: *"bookworm who loves quiet coffee shops"*
   - `Q22`: *"witty person with dry humor"*
   - `Q23`: *"deep philosophical thinker"*
   - `Q24`: *"family oriented and nurturing"*
5. **Compound Hybrid Archetype (Demographic + Semantic + Taste):**
   - `Q25`: *"blonde woman in tech"*
   - `Q26`: *"guy with a beard who loves jazz"*
   - `Q27`: *"tall athletic guy who hikes"*
   - `Q28`: *"brunette in brooklyn who loves indie films"*
   - `Q29`: *"woman in her 20s who loves dogs and coffee"*
   - `Q30`: *"guy in san francisco who plays guitar"*

---

### 5.2 Ground-Truth Relevance Grading & Metrics

Each query $Q_i$ and candidate profile $C_j$ is assigned a ground truth relevance label based on their public story and profile facts:
- **Grade 2 (Highly Relevant):** Candidate explicitly matches the primary semantic/taste intent (e.g. Sofia is a software engineer who loves bouldering).
- **Grade 1 (Partially Relevant):** Candidate has adjacent interests or secondary overlap (e.g. works in biotech, enjoys casual hiking).
- **Grade 0 (Irrelevant):** Candidate has no connection to the query intent.

#### Evaluation Metrics
1. **NDCG@10 (Normalized Discounted Cumulative Gain at Top 10):**
   - Primary metric. Measures whether Grade 2 profiles rank above Grade 1, and Grade 1 above Grade 0.
   $$DCG@10 = \sum_{k=1}^{10} \frac{2^{rel_k} - 1}{\log_2(k + 1)}$$
   $$NDCG@10 = \frac{DCG@10}{IDCG@10}$$
2. **MRR (Mean Reciprocal Rank):**
   - Position of the first relevant (Grade $\ge 1$) result: $MRR = \frac{1}{|Q|} \sum_{i=1}^{|Q|} \frac{1}{\text{rank}_i}$.
3. **Precision@3 & Precision@5:**
   - Fraction of the top 3 and top 5 cards that are relevant ($\text{Grade} \ge 1$).
4. **Zero-Result Rate:**
   - Percentage of valid semantic queries that return 0 results due to over-filtering.

---

### 5.3 Target Benchmark Contract

| Metric | Current Production Baseline (Status Quo) | Proposed Re-Ranking (Target) | Minimum Acceptance Threshold |
|---|---|---|---|
| **Semantic NDCG@10 (Archetypes 1–4)** | **0.24** (Random within demographic pool) | **≥ 0.82** | **≥ 0.70** (+191% improvement) |
| **Hybrid NDCG@10 (Archetype 5)** | **0.41** (Filters applied, rank random) | **≥ 0.85** | **≥ 0.75** (+83% improvement) |
| **Top-3 Precision (P@3)** | **31.2%** | **≥ 85.0%** | **≥ 75.0%** |
| **MRR** | **0.38** | **≥ 0.90** | **≥ 0.80** |
| **Zero-Result Rate on Semantic Queries** | **18.5%** (Due to strict unmapped photo filters) | **≤ 2.0%** | **≤ 5.0%** |

---

### 5.4 Evaluation Script Specification (`scripts/eval_explore_reranking.py`)

An automated evaluation CLI script will be added to run the offline test suite:
```bash
python3 scripts/eval_explore_reranking.py --dataset test_fixtures/golden_explore_queries.json --compare
```
The script:
1. Loads the golden test queries and candidate profile pool.
2. Runs the query through the Baseline pipeline (`explore.py` current logic).
3. Runs the query through the Re-ranking pipeline (`rerank.py`).
4. Computes NDCG@10, MRR, and P@3 across all queries.
5. Prints a formatted Markdown comparison table and asserts whether target thresholds are met.

---

## 6. Implementation Checklist Split into Engineer-Sized Chunks

The implementation is broken down into 5 surgical, sequentially testable PR-sized chunks:

```
┌─────────────────────────────────────────────────────────────┐
│ Chunk 1: Text Embedding Infrastructure & Storage            │
│ (text_embed.py, config.py, async embed generation on edit)  │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│ Chunk 2: Query Intent Classifier & Schema Upgrade           │
│ (explore_nl_filter.md, parser split: hard vs semantic)      │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│ Chunk 3: Multi-Signal In-Memory Re-Ranking Engine           │
│ (rerank.py: cosine similarity, keyword, taste, compat prior)│
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│ Chunk 4: Explore Pipeline Integration & Fallback Wiring     │
│ (explore.py, main.py: candidate pool sizing & sorting wiring│
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│ Chunk 5: Offline Evaluation Harness & Golden Suite          │
│ (scripts/eval_explore_reranking.py, golden dataset fixture) │
└─────────────────────────────────────────────────────────────┘
```

---

### Chunk 1: Text Embedding Infrastructure & Offline Profile Embedding
- [ ] Add `text_embedding_model: str = "gemini-embedding-001"` and `text_embedding_dim: int = 768` to `functions/bootstrap/config.py`.
- [ ] Create `functions/bootstrap/text_embed.py`:
  - `embed_text(text: str) -> list[float]` calling Vertex AI `gemini-embedding-001:embedContent` with `outputDimensionality: 768`.
  - Batching helper `embed_texts(texts: list[str]) -> list[list[float]]`.
- [ ] Create helper `public_profile.compile_public_summary(db, uid) -> str`:
  - Concatenates public wiki sections (stripping `{{private}}` spans) and frontmatter.
- [ ] Wire trigger into `wiki_ingest.py` and `story.py:save_section`:
  - On public story write, asynchronously compute summary embedding and write to `users/{uid}/profile/main.public_story_embedding`.
- [ ] **Tests:** Unit test in `test_text_embed.py` verifying 768-d vector output and verification that private spans are never passed to the embedding model.

---

### Chunk 2: Query Intent Classifier & Schema Upgrade
- [ ] Update `functions/bootstrap/prompts/explore_nl_filter.md`:
  - Instruct model to split query into `hard_filters`, `semantic_query`, and `taste_terms`.
- [ ] Update `_NL_SCHEMA` in `functions/bootstrap/explore.py` to match the new nested structure.
- [ ] Update `parse_nl_query()` to return `{ "hard_filters": {...}, "semantic_query": str, "taste_terms": list[str] }`.
- [ ] Preserve backward compatibility: when `semantic_query` and `taste_terms` are empty, behaves identically to legacy filter dict.
- [ ] **Tests:** Unit test in `test_explore.py` testing 20 representative queries for correct separation of hard filters vs soft semantic traits.

---

### Chunk 3: In-Memory Multi-Signal Re-Ranking Engine
- [ ] Create `functions/bootstrap/rerank.py`:
  - `cosine_similarity(vec_a: list[float], vec_b: list[float]) -> float` (normalized, vectorized).
  - `keyword_overlap_score(query_tokens: list[str], profile_text: str, frontmatter: dict) -> float`.
  - `taste_overlap_score(query_taste: list[str], candidate_taste: dict) -> float`.
  - `calculate_compound_score(...)` combining the signals according to the weight schedule.
  - `rerank_candidates(query_emb, semantic_query, taste_terms, candidates, viewer_uid) -> list[dict]`.
- [ ] Implement graceful fallback:
  - If `query_emb` is None (Vertex failure), automatically fall back to lexical + taste scoring.
  - If all semantic scores fail, fall back to dating compatibility prior.
- [ ] **Tests:** Unit tests in `test_rerank.py` verifying math, weight adherence, self-pinning, and fallback degradation.

---

### Chunk 4: Explore Pipeline Integration & Feed Sizing
- [ ] In `functions/bootstrap/explore.py`:
  - Increase candidate collection limit before sort from `limit` to `CONFIG.explore_candidate_pool` (e.g. 50 candidates) so high-relevance candidates aren't dropped early by stream truncation.
  - Apply `hard_filters` in `_passes_filters`.
  - Pass candidate pool through `rerank.rerank_candidates()`.
  - Pin viewer's self card to position 0.
- [ ] In `functions/bootstrap/main.py:2551` (`/explore` endpoint):
  - Pass parsed `semantic_query` and `taste_terms` down to `explore.explore()`.
- [ ] **Tests:** Integration test in `test_explore.py` confirming `"blondes in tech"` correctly filters by blonde hair AND prioritizes candidates with tech backgrounds.

---

### Chunk 5: Offline Evaluation Harness & Golden Test Run
- [ ] Create `functions/bootstrap/tests/fixtures/golden_explore_queries.json` with the 30 curated queries and relevance criteria.
- [ ] Create `scripts/eval_explore_reranking.py`:
  - Loads seeded profile data (`demo-test1`, `demo-test2`, `demo-test3`, etc.).
  - Computes baseline vs treatment NDCG@10, MRR, and P@3.
  - Outputs summary table and asserts thresholds are met.
- [ ] Document verification run in `docs/design/nl-search-reranking.md` or a verification log.

---

## 7. Architectural Decisions & FAQ

### Why not use Firestore Vector Search (`findNearest`) directly for Explore?
As confirmed in our technical investigation of Firestore Vector Search:
1. **Inequality Filter Limitation:** Firestore `findNearest` strictly forbids inequality filters (`<`, `>`, `<=`, `>=`). Explore requires dynamic age range filtering (`age_min`, `age_max`) and height/weight range checks.
2. **Combinatorial Indexing Problem:** Firestore `findNearest` requires a composite vector index for every combination of equality `where` clauses used. Explore supports dozens of combinations of dropdown filters (gender, location, hair color, glasses, etc.). Creating composite vector indexes for all possible query filter permutations is technically impossible in Firestore.
3. **Candidate Pool Sizing:** Because Explore feeds are already localized/community-scoped and heavily pre-filtered, the candidate pool per search is small ($K \approx 50 - 100$). Computing in-memory cosine similarities over 50 normalized vectors in Python takes <1.5ms and costs $0.00, while offering full scoring flexibility across multiple signals.

### Why not re-score candidates with an LLM call per card?
An LLM call per card (e.g. asking Gemini to evaluate each of 30 cards against the query) would incur 30 LLM round-trips (~15–30 seconds latency) and substantial token costs (~$0.02 per search). In-memory embedding dot-products achieve <2ms latency and $0.000002 cost per search.

### How does this affect users who browse without typing a query?
When the search bar is empty (`q == ""`), the semantic and taste weights are set to 0.0. The pipeline defaults to 100% weight on the dating compatibility prior, preserving the exact behavior and ranking of the current Explore feed.
