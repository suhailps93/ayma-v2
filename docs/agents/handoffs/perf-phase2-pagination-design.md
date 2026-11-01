# Handoff: Perf Phase 2 Chunk C — Pagination & Prefetch Design

**Task**: Perf Phase 2 DESIGN ONLY: pagination + prefetch for Explore feed and conversation/message lists  
**Branch**: `perf2-pagination-design`  
**Date**: 2026-11-01  
**Author**: Antigravity (Engineer)  
**Deliverable**: `docs/perf/phase2-pagination-design.md`  

---

## 1. Summary of Deliverable

Completed the comprehensive architectural design for Phase 2 pagination and prefetch in `docs/perf/phase2-pagination-design.md`.

The design doc covers:
1. **Trace of Current Unbounded Feeds (File:Line Evidence)**:
   - **Explore Feed**: Traced `ExploreScreenState._load` ([`explore_screen.dart:116-144`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/perf2-pagination-design/ayma_flutter/lib/screens/explore_screen.dart#L116-L144)), `ApiClient.explore` ([`api_client.dart:216-234`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/perf2-pagination-design/ayma_flutter/lib/services/api_client.dart#L216-L234)), `GET /explore` ([`main.py:2551-2591`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/perf2-pagination-design/functions/bootstrap/main.py#L2551-L2591)), and `explore_mod.explore` ([`explore.py:347-476`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/perf2-pagination-design/functions/bootstrap/explore.py#L347-L476)). Uncovered the backend's full table scan (`db.collection("users").stream()`), per-candidate synchronous Firestore reads, post-slice sorting distortion, and client-side chip filtering false negatives.
   - **Conversation List**: Traced nested `StreamBuilder`s in `MessagesScreen` ([`messages_screen.dart:92-140`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/perf2-pagination-design/ayma_flutter/lib/screens/messages_screen.dart#L92-L140)), unbounded queries in `DmService.watchThreads` ([`dm_service.dart:154-179`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/perf2-pagination-design/ayma_flutter/lib/services/dm_service.dart#L154-L179)) and `MatchService.watchMutualMatches` ([`match_service.dart:68-83`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/perf2-pagination-design/ayma_flutter/lib/services/match_service.dart#L68-L83)), severe N+1 query loops in `_toView` ([`match_service.dart:96-98`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/perf2-pagination-design/ayma_flutter/lib/services/match_service.dart#L96-L98)), and `POST /profiles/mini` batch size vulnerability ([`main.py:3367`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/perf2-pagination-design/functions/bootstrap/main.py#L3367)).
   - **DM Message History**: Traced unbounded subcollection streaming in `DmService.watchMessages` ([`dm_service.dart:267-273`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/perf2-pagination-design/ayma_flutter/lib/services/dm_service.dart#L267-L273)) and `DmThreadScreen` ([`dm_thread_screen.dart:634-700`](file:///home/suhailps/workspace/ayma/.fleet-worktrees/perf2-pagination-design/ayma_flutter/lib/screens/dm_thread_screen.dart#L634-L700)), noting the complete absence of a backend REST GET endpoint.
   - **Repo Best-Practice Contrast**: Benchmarked against `chat_screen.dart` and `chat_history.py` which already use a clean `before` / `limit` / `next_before` cursor pagination pattern.
2. **Proposed Pagination Contracts & Schemas**:
   - `GET /explore`: Cursor-based contract (`limit=24`, Base64-encoded `cursor` encoding tier, score, and uid tiebreakers, `next_cursor`, `has_more`).
   - Conversation List: Bounded top-25 real-time listener + on-demand older archive query (`startAfterDocument`), with denormalized partner name/photo on match creation to eliminate the N+1 query.
   - DM Message History: Tail listener for newest 30 messages + backwards pagination query prepending older messages without breaking `ListView(reverse: true)` scroll stability.
3. **Prefetch Architecture & Triggers**:
   - Viewport scroll proximity trigger (600px remaining, velocity suppression guard).
   - Shell tab warm-up: Idle post-first-frame background prefetch of Explore Page 1 and Conversation list Page 1, rendering instantly on tab switch.
   - Preemptive photo caching: `AymaPhoto` / `CachedNetworkImageProvider` decode prefetching for incoming cards, eliminating blank photo tiles (Flag F1).
4. **Cache Interplay with `FreshData`**:
   - Specified `PagedFreshData<T>` data model and transition matrix across cold open, background revalidation, next page fetching, and offline degradation.
5. **Risks & Mitigations**:
   - Monotonic cursor sorting against ordering drift.
   - ID-keyed set deduplication against cross-page duplicates.
   - Graceful offline degradation with inline retry footers.
   - Bounded in-memory list length and texture cache limits (`memCacheWidth`).
6. **Implementation Checklist & Verification Matrix**:
   - Sized into 3 discrete chunks: C1 (Explore), C2 (Conversations & DMs), C3 (Prefetch & Assets).
   - Tied to `PERF_PLAN.md` test suites: PC1, PC6, PC7, PC8, PC9, and layout matrix.

---

## 2. Top 3 Architectural Findings

1. **Backend Full Table Scan in Explore Feed**:
   `explore_mod.explore()` runs `for user_snap in db.collection("users").stream():` across the entire database, executing multiple synchronous Firestore reads per candidate, before sorting by match score *after* cutting off at limit 30. This skews global ranking and degrades linearly with database size.
2. **Catastrophic N+1 Waterfall in Mutual Matches**:
   In `MatchService.watchMutualMatches()`, every Firestore snapshot update executes sequential awaited `users/$other/profile/main` reads inside `asyncMap` for every single match, multiplying latency and Firestore read costs by the user's match count.
3. **Unbounded Real-Time Streaming on Message Histories**:
   Both `dm_threads` and `dm_threads/$threadId/messages` stream unbounded datasets into memory with zero `.limit()`, causing initial loading spinners to scale with conversation age and risking memory exhaustion on mature threads.
