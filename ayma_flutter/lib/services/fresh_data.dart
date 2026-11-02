import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// The four freshness labels every data surface must be in (PERF_PLAN Phase 1).
///
/// Mapped from Firestore [SnapshotMetadata] (`isFromCache`, `hasPendingWrites`)
/// plus an optional load/write [error]. API reads use the same labels via
/// [FreshData.fromApi].
enum FreshnessState {
  /// Server-confirmed data; safe to treat as current.
  live,

  /// Local writes not yet acked, or a refresh in flight over existing data.
  syncing,

  /// Showing cache / last-known data; not confirmed live from the server.
  stale,

  /// The read or write failed; [FreshData.error] carries the reason.
  refused,
}

/// Thin content + freshness wrapper for Firestore listeners and API reads.
///
/// UI subscribes to streams/futures of this type instead of raw snapshots so
/// screens can distinguish Live / Syncing / Stale / Refused without guessing.
@immutable
class FreshData<T> {
  const FreshData({
    this.data,
    this.isFromCache = false,
    this.hasPendingWrites = false,
    this.error,
    this.refreshing = false,
  });

  /// Payload. May be non-null even when [state] is [FreshnessState.stale] or
  /// [FreshnessState.refused] (last-known content kept on screen).
  final T? data;

  /// From [SnapshotMetadata.isFromCache]. For API reads, true when [data] is
  /// last-known content not confirmed by the latest successful fetch.
  final bool isFromCache;

  /// From [SnapshotMetadata.hasPendingWrites].
  final bool hasPendingWrites;

  /// Non-null when the latest read/write failed.
  final Object? error;

  /// True while an API refresh is in flight over existing [data].
  final bool refreshing;

  bool get hasData => data != null;

  FreshnessState get state {
    if (error != null && !hasData) return FreshnessState.refused;
    if (error != null && hasData) return FreshnessState.stale;
    if (hasPendingWrites || refreshing) return FreshnessState.syncing;
    if (isFromCache) return FreshnessState.stale;
    if (!hasData) return FreshnessState.syncing;
    return FreshnessState.live;
  }

  FreshData<T> copyWith({
    T? data,
    bool? isFromCache,
    bool? hasPendingWrites,
    Object? error,
    bool? refreshing,
    bool clearError = false,
  }) =>
      FreshData<T>(
        data: data ?? this.data,
        isFromCache: isFromCache ?? this.isFromCache,
        hasPendingWrites: hasPendingWrites ?? this.hasPendingWrites,
        error: clearError ? null : (error ?? this.error),
        refreshing: refreshing ?? this.refreshing,
      );

  /// Build from a Firestore [DocumentSnapshot]'s metadata.
  factory FreshData.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> snap,
    T Function(DocumentSnapshot<Map<String, dynamic>> snap) map,
  ) {
    try {
      return FreshData<T>(
        data: map(snap),
        isFromCache: snap.metadata.isFromCache,
        hasPendingWrites: snap.metadata.hasPendingWrites,
      );
    } catch (e) {
      return FreshData<T>(error: e);
    }
  }

  /// Build from a Firestore [QuerySnapshot]'s metadata.
  factory FreshData.fromQuery(
    QuerySnapshot<Map<String, dynamic>> snap,
    T Function(QuerySnapshot<Map<String, dynamic>> snap) map,
  ) {
    try {
      return FreshData<T>(
        data: map(snap),
        isFromCache: snap.metadata.isFromCache,
        hasPendingWrites: snap.metadata.hasPendingWrites,
      );
    } catch (e) {
      return FreshData<T>(error: e);
    }
  }

  /// API-read helper: successful fetch → live; failed with prior data → stale;
  /// failed with nothing → refused; in-flight over prior data → syncing.
  factory FreshData.fromApi({
    T? data,
    Object? error,
    bool refreshing = false,
    bool fromPrior = false,
  }) =>
      FreshData<T>(
        data: data,
        isFromCache: fromPrior,
        error: error,
        refreshing: refreshing,
      );

  /// Merge two freshness signals (e.g. DM threads + mutual matches). Payload
  /// is left to the caller; metadata ORs the pessimistic flags.
  static FreshData<R> mergeMeta<R>({
    required R? data,
    required FreshData<dynamic> a,
    required FreshData<dynamic> b,
  }) =>
      FreshData<R>(
        data: data,
        isFromCache: a.isFromCache || b.isFromCache,
        hasPendingWrites: a.hasPendingWrites || b.hasPendingWrites,
        error: a.error ?? b.error,
        refreshing: a.refreshing || b.refreshing,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FreshData<T> &&
          other.data == data &&
          other.isFromCache == isFromCache &&
          other.hasPendingWrites == hasPendingWrites &&
          other.error == error &&
          other.refreshing == refreshing;

  @override
  int get hashCode => Object.hash(
        data,
        isFromCache,
        hasPendingWrites,
        error,
        refreshing,
      );
}
