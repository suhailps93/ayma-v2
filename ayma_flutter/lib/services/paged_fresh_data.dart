import 'package:flutter/foundation.dart';

/// Phase 1 freshness label (perf-phase1-freshness): the single-word sync
/// verdict every data surface renders in its header strip.
enum FreshnessState { live, syncing, stale, refused }

/// Pagination-aware freshness wrapper (Phase 2 pagination design §5.1):
/// everything [FreshData] says about page 1, plus the appended-page states
/// (loading the next page, a next-page failure that keeps earlier pages).
@immutable
class PagedFreshData<T> {
  const PagedFreshData({
    this.items = const [],
    this.isFromCache = false,
    this.hasPendingWrites = false,
    this.error,
    this.refreshing = false,
    this.loadingNextPage = false,
    this.nextPageError,
    this.nextCursor,
    this.hasMore = false,
  });

  /// All currently loaded items across all retrieved pages.
  final List<T> items;

  /// True if page 1 was hydrated from local disk cache without server confirmation.
  final bool isFromCache;

  /// True if local optimistic mutations are pending server ack.
  final bool hasPendingWrites;

  /// Initial load or full-refresh error.
  final Object? error;

  /// True while a full pull-to-refresh or tab reload is in flight over existing [items].
  final bool refreshing;

  /// True while an appended next page is actively loading at the bottom.
  final bool loadingNextPage;

  /// Non-null if the *next page* fetch failed (does NOT invalidate existing [items]).
  final Object? nextPageError;

  /// Opaque token for the next page, or null if end of feed reached.
  final String? nextCursor;

  /// True if more items can be fetched from the server.
  final bool hasMore;

  bool get hasData => items.isNotEmpty;

  /// Maps to Phase 1's FreshnessState for header indicators.
  FreshnessState get state {
    if (error != null && !hasData) return FreshnessState.refused;
    if (error != null && hasData) return FreshnessState.stale;
    if (hasPendingWrites || refreshing) return FreshnessState.syncing;
    if (isFromCache) return FreshnessState.stale;
    if (!hasData) return FreshnessState.syncing;
    return FreshnessState.live;
  }

  PagedFreshData<T> copyWith({
    List<T>? items,
    bool? isFromCache,
    bool? hasPendingWrites,
    Object? error,
    bool clearError = false,
    bool? refreshing,
    bool? loadingNextPage,
    Object? nextPageError,
    bool clearNextPageError = false,
    String? nextCursor,
    bool clearNextCursor = false,
    bool? hasMore,
  }) {
    return PagedFreshData<T>(
      items: items ?? this.items,
      isFromCache: isFromCache ?? this.isFromCache,
      hasPendingWrites: hasPendingWrites ?? this.hasPendingWrites,
      error: clearError ? null : (error ?? this.error),
      refreshing: refreshing ?? this.refreshing,
      loadingNextPage: loadingNextPage ?? this.loadingNextPage,
      nextPageError:
          clearNextPageError ? null : (nextPageError ?? this.nextPageError),
      nextCursor: clearNextCursor ? null : (nextCursor ?? this.nextCursor),
      hasMore: hasMore ?? this.hasMore,
    );
  }
}
