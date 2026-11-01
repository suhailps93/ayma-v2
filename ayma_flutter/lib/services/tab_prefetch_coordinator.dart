import 'package:flutter/widgets.dart';

import 'api_client.dart';
import 'dm_service.dart';

/// Idle post-first-frame warm-up (Phase 2 pagination design §4.2): while the
/// user sits on the Ayma home tab, prefetch Explore page 1 and the top
/// conversations' mini profiles into memory so those tabs paint instantly —
/// with zero spinner — on first visit, then revalidate in the background.
///
/// Best-effort throughout: any failure (signed out, offline, backend down)
/// leaves the tabs to load normally on visit. Never runs before the first
/// frame: scheduled via [scheduleIdleWarmup] with a 400ms settling delay so
/// the launch animations never drop frames.
class TabPrefetchCoordinator {
  TabPrefetchCoordinator._();

  static final TabPrefetchCoordinator instance = TabPrefetchCoordinator._();

  ExplorePage? _warmExplore;
  DateTime? _warmExploreAt;
  final Map<String, MiniProfile> _warmMinis = {};
  bool _warming = false;

  /// Warmed snapshots older than this are discarded, never painted.
  @visibleForTesting
  static const warmStaleAfter = Duration(minutes: 2);

  /// Schedules one idle warm-up. Safe to call on every shell mount; while a
  /// warm-up is in flight further calls are ignored.
  void scheduleIdleWarmup({ApiClient? api, DmService? dm}) {
    if (_warming) return;
    _warming = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      try {
        await _warm(api ?? ApiClient(), dm);
      } catch (_) {
        // Best-effort: tabs load normally on visit.
      } finally {
        _warming = false;
      }
    });
  }

  Future<void> _warm(ApiClient api, DmService? dm) async {
    try {
      _warmExplore = await api.explore(limit: 24);
      _warmExploreAt = DateTime.now();
    } catch (_) {}
    try {
      final svc = dm ?? DmService();
      final threads = await svc.fetchActiveThreads(limit: 25);
      final uids = threads
          .map((t) => t.otherUid)
          .where((u) => u.isNotEmpty)
          .toSet()
          .toList();
      if (uids.isNotEmpty) _warmMinis.addAll(await api.miniProfiles(uids));
    } catch (_) {}
  }

  /// Page-1 Explore snapshot warmed while idle, or null. Consumed once —
  /// the screen revalidates in the background after painting it.
  ExplorePage? takeExplorePage() {
    final page = _warmExplore;
    final at = _warmExploreAt;
    _warmExplore = null;
    _warmExploreAt = null;
    if (page == null || at == null) return null;
    if (DateTime.now().difference(at) > warmStaleAfter) return null;
    return page;
  }

  /// Warmed mini profiles, for the messages list's first paint. Consumed
  /// once — the screen keeps them in its own state afterwards.
  Map<String, MiniProfile> takeMiniProfiles() {
    final out = Map<String, MiniProfile>.of(_warmMinis);
    _warmMinis.clear();
    return out;
  }

  @visibleForTesting
  void debugSeed({ExplorePage? explore, Map<String, MiniProfile>? minis}) {
    _warmExplore = explore;
    _warmExploreAt = explore == null ? null : DateTime.now();
    _warmMinis
      ..clear()
      ..addAll(minis ?? const {});
  }

  @visibleForTesting
  void debugReset() {
    _warmExplore = null;
    _warmExploreAt = null;
    _warmMinis.clear();
    _warming = false;
  }
}
