# Ayma — Loading Performance & Cache Strategy Plan (for Claude)

From Astro (Muse), 2026-10-31. Founder complaint, verbatim problem statement: some pages take too long to load, and "with caching sometimes it looks loaded but nothing works." This plan fixes both: real speed, and cache behaviour that never presents dead/stale data as live.

## Diagnosis — what the code does today (verified by Astro's scan of ayma_flutter, meta-hackathon era)

1. **Cache is presented as truth.** Firestore persistence is on (defaults; no explicit `Settings` anywhere), and across the whole app there is **zero** use of `SnapshotMetadata` — no `isFromCache`, no `hasPendingWrites`, no `GetOptions(source:)`. Screens render whatever the local cache holds as if it were live server data. When the network or backend is actually unreachable, the UI looks complete while actions queue or hang. This is the "looks loaded but nothing works" bug, structurally.
2. **Timeouts are far too long and there is no retry policy.** `api_client.dart` default timeout is **25s** (55s for long calls). A failing tap can appear dead for up to 25 seconds. Retry exists only as ad-hoc "caller offers Retry" comments.
3. **Startup is a serial waterfall.** `main()` awaits orientation → Firebase → Crashlytics → RevenueCat init → theme/accent/orb loads → MetaIntegrations before `runApp`, and then `SplashScreen._resolve()` awaits a backend `bootstrap()` before routing. First interactive frame waits on SDK inits + a network round trip, in series.
4. **No pagination.** Exactly **one** `.limit()` call exists in all of `lib/`. Match lists, inboxes, and message lists fetch unbounded result sets.
5. **Images are full-size and mostly uncached.** No resize/compression found in the photo upload path, no `cacheWidth` decode sizing on display, and `CachedNetworkImage` is used at only 4 call sites vs raw `Image.network`/`NetworkImage` elsewhere. Lists download and decode full-resolution photos. (Consistent with slow Explore cards and the blank-tile symptom, test flag F1.)
6. **Loading UX is spinners.** 37 files use bare `CircularProgressIndicator`; there is no skeleton system. Even fast loads *feel* slow.
7. **Good seeds already in the tree — generalize them.** `pending_chat_queue.dart` (durable offline write queue for chat) and the `loadCached()` + background `refresh()` pattern used for Meta/Sentry flags are exactly the right shapes; they're just only applied to chat sends and feature flags, not to product data.

## What high-scale consumer apps do (the strategy we're adopting)

- **One owner per data domain (repository / single source of truth).** UI subscribes to one stream per domain that carries *content + freshness state*, never to raw Firestore/API calls. (Standard Android/iOS architecture guidance at scale.)
- **Stale-while-revalidate for reads.** Render cached data instantly, refresh in the background, swap in fresh data in place — no full-screen reloads, no scroll jumps.
- **Freshness is a UI state, not an afterthought.** Every data surface is in one of four states — **Live / Syncing / Stale-or-offline / Refused-failed** — mapped directly from `isFromCache` + `hasPendingWrites` + connectivity + write errors. Success labels bind to *server confirmation*, never to the local write call. Cached screens carry a subtle "offline / updating" affordance; actions that can't complete say so immediately instead of hanging.
- **Optimistic mutations with reconciliation** (Instagram/Facebook pattern): apply locally with a visible pending marker, confirm or roll back on server response.
- **Timeouts in seconds, retries with backoff, request dedup.** User-initiated requests outrank prefetch; concurrent identical GETs collapse to one call.
- **Prefetch with priority** (Instagram's model): likely-next content (next tab's data, next feed page, visible cards' images) prefetches at idle priority and escalates as the user approaches it.
- **Right-sized images end to end** (Instagram's srcset lesson): server/storage delivers thumbnail + medium + full variants; lists decode at display size (`cacheWidth`); everything goes through the disk cache — no raw `Image.network` for remote content.
- **Pagination everywhere** (cursor-based, bounded pages).
- **Skeleton screens for structure, spinners only for bounded actions** (Facebook/LinkedIn/Airbnb; Instagram measured ~25% better perceived performance from skeletons alone).
- **Performance budgets + real-user telemetry**: cold start, time-to-interactive per screen, cache-hit/stale rates, slow-screen percentiles in Sentry — you can't hold a budget you don't measure.

## Phased work (one phase per step; test → Astro verifies → commit, per repo discipline)

### Phase 0 — Measure (no behaviour change)
- Add lightweight perf telemetry: cold-start time, splash→interactive time, per-screen time-to-first-content and time-to-interactive, Firestore cache-vs-server ratio per listener, API latency percentiles. Emit to Sentry/analytics.
- Acceptance: Astro can read a baseline table for the top 6 screens (Chat home, Explore, Messages, Profile/You, Plan, Practice Date) from a test build.

### Phase 1 — Correctness: kill the "loaded but dead" state (highest priority)
- Introduce a thin data-state wrapper for Firestore listeners and API reads exposing `{data, isFromCache, hasPendingWrites, error}`; migrate the top surfaces first (Chat home, Explore, Messages, DM thread, Profile).
- Global connectivity + freshness affordance: when data is cache-only/offline, show the subtle offline/updating indicator; network-dependent actions either queue visibly (extend the `pending_chat_queue` pattern) or fail fast with a message — never fake-succeed.
- Writes: bind "saved/sent" confirmation to server ack (`hasPendingWrites == false` snapshot or API response); surface refusals with retry built from the original input.
- API client: cut interactive timeouts to a short budget (target ≤8s connect/read for interactive calls; long calls keep their budget but must show progress + cancel), add bounded retry with backoff for idempotent GETs, dedupe concurrent identical GETs.
- Acceptance: Astro's test pack Section PC3/PC4/PC5 pass — offline open is honestly labelled, offline actions pend and reconcile on reconnect (incl. a forced server refusal), mid-session network drop fails visibly within the short budget.

### Phase 2 — Real speed
- **Startup:** flatten `main()` — only Firebase + auth restoration block first frame; RevenueCat init, flag refreshes, push setup move after `runApp`/unawaited; splash `bootstrap()` gets a short timeout with cached-config fallback so routing never waits on a cold backend.
- **Images:** upload pipeline produces resized variants (thumb ~400px, medium ~1080px, full original); lists/cards use thumb/medium via `CachedNetworkImage` with `cacheWidth` at display size; ban raw `Image.network`/`NetworkImage` for remote photos (lint/review rule).
- **Pagination:** cursor-paginate matches, inbox, messages, notifications (page ~20–30) with in-place append.
- **Prefetch:** on app start (post-first-frame) and on tab hover/scroll proximity — next tab's first page + visible cards' images, idle priority, cancelled when superseded.
- Acceptance: PC1 (cold start ≤3s to interactive on emulator Wi-Fi), PC6/PC7/PC8 pass; Explore shows no blank tiles on a cold image cache (closes F1 if image-related).

### Phase 3 — Perceived speed
- Skeleton components matching the real layouts for Explore cards, Messages rows, Profile, Plan; progressive fill (structure → text → images); spinners remain only for bounded actions (<2s expected).
- Acceptance: PC6 on throttled 3G — skeletons render instantly on all three surfaces, content fills progressively, nothing flashes blank.

## Rules for the work
- No behaviour change in Phase 0. No phase ships without Astro's Section PC run (plus Section A smoke) passing on the fix build.
- Cache format changes must handle upgrade-in-place (PC10): migrate or version-and-clear, never crash on an old cache.
- Keep Cloud Run deployment and all store builds untouched by this work; feature-branch it (suggest `perf-cache` off meta-hackathon) so the release line stays clean.
- Budgets are the contract: if a phase can't hit its budget on the emulator, say so with the telemetry instead of silently relaxing it.

— Astro (Muse)
