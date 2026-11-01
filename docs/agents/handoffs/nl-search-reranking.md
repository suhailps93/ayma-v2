# Handoff: Explore Natural-Language Search Relevance Re-Ranking Design

**Task**: Natural-Language Search Relevance Re-Ranking for Explore (Design & Spike)  
**Branch**: `design/nl-rerank`  
**Date**: 2026-11-01  
**Author**: Antigravity (Engineer)  
**Deliverable**: `docs/design/nl-search-reranking.md`  

---

## 1. Summary of Deliverable

Completed the comprehensive design document for Explore natural-language search relevance re-ranking in `docs/design/nl-search-reranking.md`.

The design doc covers:
1. **Pipeline Audit & Trace (with exact file:line citations)**:
   - **Query Parsing Lifecycle**: Traced Flutter `ExploreScreenState._onSearchChanged` ([`explore_screen.dart:146-150`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/ayma_flutter/lib/screens/explore_screen.dart#L146-L150)), `ApiClient.explore` ([`api_client.dart:216-222`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/ayma_flutter/lib/services/api_client.dart#L216-L222)), `main.explore` ([`main.py:2551-2568`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/functions/bootstrap/main.py#L2551-L2568)), `explore.parse_nl_query` ([`explore.py:121-139`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/functions/bootstrap/explore.py#L121-L139)), and prompt `explore_nl_filter.md` ([`prompts/explore_nl_filter.md:1-30`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/functions/bootstrap/prompts/explore_nl_filter.md#L1-L30)). Established that non-physical search intent (*"in tech"*, *"jazz lover"*, *"architect"*) is completely dropped by `_NL_SCHEMA` (`explore.py:51-77`).
   - **Filter Application & Sourcing**: Traced `explore.py:347-430` user stream, safety exclusions (blocks, passed, paused, simulator personas, test fixtures), and multi-attribute evaluation in `_passes_filters` ([`explore.py:161-250`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/nl-rerank-design/functions/bootstrap/explore.py#L161-L250)). Identified the stream truncation defect at line 383 where candidate collection terminates at `limit` (30) *before* sort.
   - **Current Sort Key**: Traced `explore.py:471-476` sorting exclusively by `(not c["self"], c["score"] is None, -(c["score"] or 0))`, where `score` is offline dating compatibility (`matches.score` or `heuristic_score`). Proved search query relevance contributes **0.0** to result ordering.
   - **Candidate Signals Audit**: Audited core profile fields (`profile/main`), photo/physical attributes, living public wiki pages (`wiki_pages` stripped of private spans), taste profile nodes (`taste_music`, `taste_film`, `taste_food`), and biometric multimodal embeddings (`media_embed.py`, strictly consent-gated for face verification). Confirmed no text embeddings exist today (`wiki_query.py:115`).
2. **Proposed Two-Stage Architecture**:
   - **Stage 1 (Retrieval & Filter Sourcing)**: Query intent parser splits query into `hard_filters` (gender, age bounds, location) and `semantic_query` / `taste_terms`.
   - **Stage 2 (In-Memory Multi-Signal Re-Ranking)**: Composite scoring formula:
     $$S(q, u, c) = 0.50 \cdot S_{\text{semantic}} + 0.20 \cdot S_{\text{keyword}} + 0.15 \cdot S_{\text{taste}} + 0.15 \cdot S_{\text{compat}}$$
     With 100% fallback to compatibility prior when query is empty, preserving existing browse behavior.
   - **Model & Representation**: Google `gemini-embedding-001` via Vertex AI REST `embedContent` with Matryoshka Representation Learning (MRL) dimension 768-d. Offline public profile embedding generated asynchronously on story updates.
   - **Privacy Boundary**: Strips `{{private}}` and `{{ai_only}}` spans before embedding. Complete legal and technical isolation from biometric face consent.
3. **Performance, Cost & Latency Budget**:
   - Total latency budget: ≤ 250ms (query embedding ~50ms, candidate pool sourcing ~40ms, in-memory dot-product math over 50 candidates < 1.5ms).
   - Cost: $0.15 per 1M tokens on Vertex AI -> $0.00000225 per search query (100,000 searches cost $0.225).
   - Multi-tiered graceful fallback hierarchy: Embedding failure -> Lexical/Taste scoring fallback -> Compatibility sort fallback (guaranteeing zero 500 errors).
4. **Offline Evaluation Plan**:
   - Golden test suite of 30 queries across 5 archetypes (Professional, Cultural Taste, Lifestyle, Personality, Compound Hybrid).
   - Metrics: NDCG@10 (target ≥ 0.82 vs baseline 0.24), MRR (target ≥ 0.90 vs baseline 0.38), Precision@3 (target ≥ 85%), Zero-result rate (target ≤ 2%).
   - Automated evaluation script specification: `scripts/eval_explore_reranking.py`.
5. **Implementation Checklist**:
   - Sized into 5 engineer-sized chunks:
     - Chunk 1: Text Embedding Infrastructure & Offline Summary Embedding
     - Chunk 2: Query Intent Classifier & Schema Upgrade
     - Chunk 3: Multi-Signal In-Memory Re-Ranking Engine
     - Chunk 4: Explore Pipeline Integration & Feed Sizing
     - Chunk 5: Offline Evaluation Harness & Golden Test Run

---

## 2. Top Architectural Takeaways

1. **Natural Language Search is Currently a Pure Filter Compiler:**
   The entire semantic richness of user queries (*"in tech"*, *"indie rock fan"*, *"calm introvert"*) is completely discarded by `_NL_SCHEMA`. The surviving candidates are sorted purely by dating compatibility or arbitrary Firestore document ID stream order.
2. **In-Memory Cosine Re-Ranking Beats Firestore `findNearest` for Explore:**
   Firestore's native `findNearest` forbids inequality range queries (`<`, `>`, `<=`, `>=`) required for Explore age/height/weight filters and requires impossible combinatorial composite indexes across all dropdown combinations. Sourcing a pre-filtered pool of $K = 50$ candidates and executing 768-d dot products in Python memory takes <1.5ms, costs nothing extra, and supports hybrid multi-signal weighting.
3. **Strict Separation of Biometric Face Embeddings and Public Text Embeddings:**
   Ayma's existing `gemini-embedding-2` face embeddings are subject to sensitive biometric consent gates (`biometric_consent.py`). Public text embeddings must remain strictly isolated on `profile/main.public_story_embedding` and must only ever embed public wiki sections with private spans rigorously stripped.
