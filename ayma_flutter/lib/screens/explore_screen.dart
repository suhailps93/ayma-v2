import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/chat_inbox.dart';
import '../services/paged_fresh_data.dart';
import '../services/report_cache.dart';
import '../services/tab_prefetch_coordinator.dart';
import '../theme.dart';
import '../util/cold_start_retry.dart';
import '../widgets/ayma_wing_loader.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/overflow_guards.dart';
import '../widgets/staggered.dart';
import 'main_shell_screen.dart';

/// Explore — the live filtered feed (§6.1, §6.4, §6.11 step 6). Text search is
/// parsed server-side; the hair-colour chips are exact dropdown filters.
///
/// Laid out as the design's two-column card grid: a photo (or a seeded gradient
/// when there's none), a serif name, and the location in mono.
class ExploreScreen extends StatefulWidget {
  const ExploreScreen({
    super.key,
    this.apiClient,
    this.initialQuery = '',
    this.cacheUid,
  });

  static const path = '/explore';

  final ApiClient? apiClient;

  /// Test seam for the last-known feed cache's uid scope; production reads
  /// the signed-in user from FirebaseAuth instead.
  final String? cacheUid;

  /// Pre-fill the search box and run it once — used when Ayma opens Explore
  /// with a query in a voice call (`?q=…`), or via [AppContext.pendingExploreQuery].
  final String initialQuery;

  @override
  State<ExploreScreen> createState() => ExploreScreenState();
}

enum _Filter { all, liked, likedMe, mutual, scored }

/// Public so [MainShellScreen] — which keeps this screen alive across tab
/// switches in an `IndexedStack` rather than rebuilding it — can reach in and
/// refetch when Explore becomes the visible tab again. Without this, a score
/// or like recorded elsewhere (recalculating a match report, say) never
/// shows up here until the app restarts: `initState` only runs once, the
/// very first time the tab is built.
class ExploreScreenState extends State<ExploreScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _debounce;

  /// Paged feed state (Phase 2 pagination design §5.1): page-1 items plus
  /// the appended-page states. Page 1 of the default feed persists in the
  /// last-known cache ([ReportCache]) so a cold start paints instantly
  /// (`isFromCache`) while the fetch revalidates behind it.
  PagedFreshData<ExploreCard> _feed = const PagedFreshData();
  _Filter _filter = _Filter.all;

  /// The signed-in uid scoping the last-known feed cache (own data only).
  /// Empty when signed out or when no Firebase app is configured (unit
  /// tests), which disables caching gracefully.
  String get _cacheUid {
    final injected = widget.cacheUid;
    if (injected != null) return injected;
    try {
      return FirebaseAuth.instance.currentUser?.uid ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Uids already in [_feed], so a profile edited mid-browse can't appear
  /// twice across a page boundary (design §6.2 dedup invariant).
  final Set<String> _seenUids = {};

  /// Last scroll sample for the fling guard (design §4.1): page prefetches
  /// are suppressed while the list is flying past content.
  double _lastPixels = 0;
  DateTime _lastScrollAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// In-memory card cap (design §6.4): paging stops here rather than
  /// growing the model without bound.
  static const _maxCards = 120;

  /// True once the initial feed load's first attempt has failed and a
  /// cold-start backoff retry is pending/in flight: the loader swaps its line
  /// to "Reconnecting…" instead of holding the original line indefinitely
  /// (loader retest, Nov 2026, Leg 4). Reset on every new initial load.
  bool _initialRetrying = false;

  /// Test seam for the §4.1 fling guard: prefetches are suppressed above
  /// this scroll velocity (logical px/s). Widget tests drive the clock, so
  /// they pin this to [double.infinity] to exercise paging deterministically.
  @visibleForTesting
  static double debugFlingVelocityThreshold = 2500;

  List<ExploreCard> get _visibleCards {
    final cards = _feed.items;
    if (_filter == _Filter.all) return cards;
    return cards.where((c) {
      if (c.isSelf) return true; // your card always shows
      return switch (_filter) {
        _Filter.liked => c.liked,
        _Filter.likedMe => c.likedMe,
        _Filter.mutual => c.mutual,
        _Filter.scored => c.score != null,
        _Filter.all => true,
      };
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    final seed = widget.initialQuery.trim().isNotEmpty
        ? widget.initialQuery.trim()
        : (AppContext.instance.pendingExploreQuery ?? '').trim();
    AppContext.instance.pendingExploreQuery = null;
    if (seed.isNotEmpty) _searchController.text = seed;
    _scrollController.addListener(_onScroll);
    _syncContext();
    _loadInitial();
  }

  static const _filterLabels = {
    _Filter.all: 'Everyone',
    _Filter.liked: 'Your likes',
    _Filter.likedMe: 'Liked me',
    _Filter.mutual: 'Mutual',
    _Filter.scored: 'Match run',
  };

  /// Mirrors what the grid shows (query, active chip, the people) into the
  /// screen context Ayma reads, so she can describe the page.
  void _syncContext() {
    AppContext.instance.set(
      screen: 'explore',
      note: _searchController.text.trim(),
      detail: _feed.hasData
          ? exploreSummary(
              query: _searchController.text,
              filterLabel: _filterLabels[_filter]!,
              cards: _visibleCards,
            )
          : '',
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Refetch the feed from page 1 — called on search submit, and by
  /// [MainShellScreen] each time this tab becomes visible again after the
  /// first build (a re-selected tab, or Android back landing on it). A fetch
  /// already in flight is left alone rather than raced against a second one.
  Future<void> reload() =>
      _feed.refreshing || _feed.loadingNextPage
          ? Future<void>.value()
          : _loadInitial();

  Future<void> _loadInitial() async {
    // Idle warm-up hit (design §4.2): paint page 1 instantly, then fall
    // through to the background revalidation below. Only for the default
    // (unsearched) feed the warm-up fetched.
    if (!_feed.hasData && _searchController.text.trim().isEmpty) {
      final warm = TabPrefetchCoordinator.instance.takeExplorePage();
      if (warm != null) {
        _seenUids
          ..clear()
          ..addAll(warm.cards.map((c) => c.uid));
        setState(() {
          _feed = PagedFreshData<ExploreCard>(
            items: List.of(warm.cards),
            nextCursor: warm.nextCursor,
            hasMore: warm.hasMore,
          );
        });
        _syncContext();
        _prefetchVisiblePhotos(warm.cards);
      }
    }
    // Last-known disk cache (offline-first): when neither this session's
    // warm-up nor an earlier load has data, paint the previous session's
    // page 1 instantly — marked from-cache (stale) — while the fetch below
    // revalidates. Default (unsearched) feed only, like the warm-up.
    if (!_feed.hasData && _searchController.text.trim().isEmpty) {
      await _restoreCachedFeed();
    }
    setState(() {
      _feed = _feed.copyWith(refreshing: true, clearError: true);
      _initialRetrying = false;
    });
    try {
      // Ride through a scale-to-zero cold start: the first feed page uses a
      // cold-start-tolerant timeout and auto-retries with exponential backoff
      // over a generous budget, staying on the loading indicator the whole
      // time. Only a sustained failure (budget spent) sets `_feed.error` and
      // the manual "Couldn't load — Retry" state — never the first timeout.
      final page = await withColdStartRetry(
        () => _api.explore(
          q: _searchController.text.trim(),
          timeout: kColdStartCallTimeout,
        ),
        onRetry: () {
          if (mounted) setState(() => _initialRetrying = true);
        },
      );
      if (!mounted) return;
      if (_searchController.text.trim().isEmpty) _persistFeedPage(page);
      _seenUids
        ..clear()
        ..addAll(page.cards.map((c) => c.uid));
      setState(() {
        _feed = _feed.copyWith(
          items: List.of(page.cards),
          isFromCache: false,
          refreshing: false,
          clearError: true,
          clearNextPageError: true,
          loadingNextPage: false,
          nextCursor: page.nextCursor,
          clearNextCursor: page.nextCursor == null,
          hasMore: page.hasMore,
        );
      });
      _syncContext();
      AppContext.instance.exploreReport.value = ExploreReport(
        query: _searchController.text.trim(),
        summary: exploreSummary(
          query: _searchController.text,
          filterLabel: _filterLabels[_filter]!,
          cards: _visibleCards,
        ),
      );
      _prefetchVisiblePhotos(page.cards);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _feed = _feed.copyWith(refreshing: false, error: e);
      });
    }
  }

  /// Paint the last-known page 1 from the disk cache (see [ReportCache]),
  /// marked from-cache so the freshness strip reads stale while the fetch
  /// in [_loadInitial] revalidates. Best-effort: any storage/parse problem
  /// just leaves the normal network load to proceed.
  Future<void> _restoreCachedFeed() async {
    final uid = _cacheUid;
    if (uid.isEmpty) return;
    try {
      final raw = await ReportCache.instance
          .readReport(uid, 'last_known', 'explore_feed');
      if (raw == null || !mounted || _feed.hasData) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final cards = ((m['cards'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ExploreCard.fromMap)
          .toList();
      if (cards.isEmpty) return;
      _seenUids
        ..clear()
        ..addAll(cards.map((c) => c.uid));
      setState(() {
        _feed = PagedFreshData<ExploreCard>(
          items: cards,
          isFromCache: true,
          nextCursor: m['next_cursor'] as String?,
          hasMore: m['has_more'] as bool? ?? false,
        );
      });
      _syncContext();
      _prefetchVisiblePhotos(cards);
    } catch (_) {
      // A corrupt / unreadable cache entry just means a normal load.
    }
  }

  /// Persist a freshly fetched page 1 as the last-known feed, so the next
  /// cold start paints instantly even with no connection.
  void _persistFeedPage(ExplorePage page) {
    final uid = _cacheUid;
    if (uid.isEmpty) return;
    unawaited(ReportCache.instance.writeReport(
      uid,
      'last_known',
      'explore_feed',
      jsonEncode({
        'cards': [for (final c in page.cards) c.toMap()],
        'next_cursor': page.nextCursor,
        'has_more': page.hasMore,
      }),
    ));
  }

  /// Append the next page in place (design §3.1.4). Guarded against
  /// concurrent calls, terminal feeds, and the in-memory cap; a failure
  /// keeps earlier pages and surfaces a retry footer (design §5.2).
  Future<void> _loadNextPage() async {
    final cursor = _feed.nextCursor;
    if (_feed.loadingNextPage ||
        _feed.refreshing ||
        !_feed.hasMore ||
        cursor == null ||
        _feed.items.length >= _maxCards) {
      return;
    }
    setState(() {
      _feed = _feed.copyWith(loadingNextPage: true, clearNextPageError: true);
    });
    try {
      final page = await _api.explore(
        q: _searchController.text.trim(),
        cursor: cursor,
      );
      if (!mounted) return;
      final fresh = page.cards.where((c) => _seenUids.add(c.uid)).toList();
      final total = _feed.items.length + fresh.length;
      setState(() {
        _feed = _feed.copyWith(
          items: [..._feed.items, ...fresh],
          loadingNextPage: false,
          clearNextPageError: true,
          nextCursor: page.nextCursor,
          clearNextCursor: page.nextCursor == null,
          hasMore: page.hasMore && total < _maxCards,
        );
      });
      _prefetchVisiblePhotos(fresh);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _feed = _feed.copyWith(loadingNextPage: false, nextPageError: e);
      });
    }
  }

  /// Scroll proximity prefetch (design §4.1): fetch the next page when
  /// within 600px of the bottom, unless the list is flinging past.
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final now = DateTime.now();
    final dtMs = now.difference(_lastScrollAt).inMilliseconds;
    final velocity = dtMs > 0
        ? (pos.pixels - _lastPixels).abs() / dtMs * 1000
        : 0.0;
    _lastPixels = pos.pixels;
    _lastScrollAt = now;
    if (pos.extentAfter >= 600) return;
    if (velocity > debugFlingVelocityThreshold) return; // fling guard
    _loadNextPage();
  }

  /// Warm the image cache for freshly decoded cards (design §4.3) once the
  /// frame that carries them is scheduled.
  void _prefetchVisiblePhotos(List<ExploreCard> cards) {
    if (!mounted || cards.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      prefetchCardPhotos(context, cards.map((c) => c.gridPhotoUrl));
    });
  }

  void _submitSearch() {
    _debounce?.cancel();
    _loadInitial();
  }

  void _onSearchChanged(String _) {
    _syncContext();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _loadInitial);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ChromeColumn(
          header: [
            // Same rendering as the old plain serif `Text` (identical
            // padding/size defaults), plus a back arrow when this screen is
            // pushed standalone (`/explore` deep link / `open_screen`) —
            // invisible in the shell tab, where the route can't pop.
            const AymaScreenHeader(
              title: 'Explore',
              automaticallyImplyBack: true,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                onChanged: _onSearchChanged,
                onSubmitted: (_) => _submitSearch(),
                decoration: InputDecoration(
                  hintText: 'Describe who you’re looking for…',
                  prefixIcon: IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: _submitSearch,
                    tooltip: 'Search',
                  ),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            _submitSearch();
                          },
                          tooltip: 'Clear',
                        )
                      : null,
                  isDense: true,
                ),
              ),
            ),
            SizedBox(
              // The chip row's height follows the text size, so large text
              // never squeezes the chips' labels.
              height: MediaQuery.textScalerOf(context).scale(14) + 24,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final f in _Filter.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(switch (f) {
                          _Filter.all => 'Everyone',
                          _Filter.liked => 'Your likes',
                          _Filter.likedMe => 'Liked me',
                          _Filter.mutual => 'Mutual',
                          _Filter.scored => 'Match run',
                        }),
                        selected: _filter == f,
                        onSelected: (_) {
                          setState(
                              () => _filter = _filter == f ? _Filter.all : f);
                          _syncContext();
                        },
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                ],
              ),
            ),
            if (_feed.refreshing && _feed.hasData)
              const LinearProgressIndicator(minHeight: 2)
            else
              const SizedBox(height: 2),
          ],
          body: Builder(builder: (context) {
            if (_feed.refreshing && !_feed.hasData) {
              // GET /explore page 1 (cold-start retries included): while a
              // retry is pending/in flight the line says so instead of
              // holding the original line indefinitely.
              return AymaWingLoader(
                lines: _initialRetrying
                    ? AymaLoaderLines.reconnect
                    : AymaLoaderLines.explore,
              );
            }
            if (_feed.error != null && !_feed.hasData) {
              // Shown only after the cold-start retry budget is spent (see
              // [_loadInitial]); Retry restarts the whole load sequence.
              return CenteredScroll(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "Couldn't load Explore.",
                      textAlign: TextAlign.center,
                      style: AymaType.sans(
                        size: 15,
                        soft: true,
                        color: ac.fgMute,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      key: const ValueKey('explore-error-retry'),
                      onPressed: _loadInitial,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              );
            }
            final cards = _visibleCards;
            final isSearching = _searchController.text.trim().isNotEmpty;
            final hasNoMatches =
                cards.isEmpty || (isSearching && cards.every((c) => c.isSelf));
            if (hasNoMatches) {
              return CenteredScroll(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _filter == _Filter.all
                      ? 'No one matches that yet.'
                      : 'Nothing here for this filter.',
                  textAlign: TextAlign.center,
                  style: AymaType.sans(
                      size: 15, soft: true, color: ac.fgMute),
                ),
              );
            }
            // Search field above: dragging the results
            // away dismisses the keyboard (iOS has no
            // dismiss key).
            return CustomScrollView(
              controller: _scrollController,
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  // Two columns on a phone; more on the Fold's inner
                  // display, a tablet or landscape, instead of two
                  // giant cards.
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 240,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 0.66,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => FadeSlideIn(
                        delay: staggerDelay(i),
                        child: _Card(card: cards[i], api: _api),
                      ),
                      childCount: cards.length,
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: _PageFooter(
                    feed: _feed,
                    onRetry: _loadNextPage,
                  ),
                ),
              ],
            );
          }),
          headerShare: 0.5,
          footerShare: 0.5,
        ),
      ),
    );
  }
}

/// Pagination footer (design §5.2): a dots indicator while the next page
/// is in flight, a retry chip when it fails (earlier pages stay visible).
class _PageFooter extends StatelessWidget {
  const _PageFooter({required this.feed, required this.onRetry});

  final PagedFreshData<ExploreCard> feed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (feed.loadingNextPage) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          // GET /explore next page — footer slot, no room for a line.
          child: AymaWingLoader(size: 20, showLabel: false),
        ),
      );
    }
    if (feed.nextPageError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: TextButton(
            onPressed: onRetry,
            child: const Text('Could not load more · Tap to retry'),
          ),
        ),
      );
    }
    return const SizedBox(height: 8);
  }
}

/// Most people listed in [exploreSummary]; the rest are only counted.
const _summaryMaxPeople = 12;
const _summaryMaxChars = 1200;

/// Plain-text description of what Explore is showing — the applied search and
/// chip filter, how many people, and the first few (name, age, place, score,
/// like state) — capped so it can ride along as screen context or tool output.
@visibleForTesting
String exploreSummary({
  required String query,
  required String filterLabel,
  required List<ExploreCard> cards,
}) {
  final q = query.trim();
  final head = StringBuffer(q.isEmpty ? 'No search text' : 'Search "$q"')
    ..write(', filter "$filterLabel": ');
  final others = cards.where((c) => !c.isSelf).toList();
  if (others.isEmpty) {
    head.write('nobody is listed.');
    return head.toString();
  }
  head.write('${others.length} ${others.length == 1 ? 'person' : 'people'}');
  final parts = <String>[];
  for (final c in others.take(_summaryMaxPeople)) {
    final bits = <String>[
      c.name.isEmpty ? 'Someone' : c.name,
      if (c.age != null) '${c.age}',
      if (c.location.isNotEmpty) c.location,
      if (c.score != null) '${(c.score! * 100).round()}% match',
      if (c.mutual)
        'mutual like'
      else if (c.liked)
        'you liked'
      else if (c.likedMe)
        'liked you',
    ];
    parts.add(bits.join(', '));
  }
  head.write(': ${parts.join('; ')}');
  if (others.length > _summaryMaxPeople) {
    head.write('; and ${others.length - _summaryMaxPeople} more');
  }
  final out = head.toString();
  return out.length <= _summaryMaxChars
      ? out
      : '${out.substring(0, _summaryMaxChars - 1)}…';
}

class _Card extends StatelessWidget {
  const _Card({required this.card, required this.api});

  final ExploreCard card;
  final ApiClient api;

  void _sheet(BuildContext context) {
    final name = card.name.isEmpty ? 'them' : card.name;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text('View $name’s profile'),
              onTap: () {
                Navigator.pop(sheetCtx);
                context.push('/profile/user/${card.uid}');
              },
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: Text('Ask Ayma about $name'),
              onTap: () {
                Navigator.pop(sheetCtx);
                ChatInbox.instance.push(ChatKickoff.talkAbout(
                  targetUid: card.uid,
                  label: name,
                ));
                context.go(MainShellScreen.path);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final score = card.score;
    return GestureDetector(
      onTap: () => context.push('/profile/user/${card.uid}'),
      onLongPress: card.isSelf ? null : () => _sheet(context),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: ac.bgElev,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: ac.lineSoft, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _Photo(seed: card.uid, url: card.gridPhotoUrl, name: card.name),
                  // Like / Message / Match all live on the profile now — the
                  // card is just a way in. A small heart flags a like / mutual.
                  if (!card.isSelf && (card.liked || card.mutual))
                    Positioned(
                      right: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          card.mutual ? Icons.favorite : Icons.favorite_border,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(11, 10, 11, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Flexible(
                        child: Text(
                          card.name.isEmpty ? 'Someone' : card.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AymaType.sans(size: 16, weight: FontWeight.w600, color: ac.fg),
                        ),
                      ),
                      if (card.age != null)
                        Text(' · ${card.age}',
                            style: AymaType.sans(size: 11, color: ac.fgMute)),
                    ],
                  ),
                  if (card.location.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      card.location.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AymaType.mono(size: 8, color: ac.fgMute)
                          .copyWith(letterSpacing: 1.2),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    card.isSelf
                        ? (card.paused
                            ? 'Paused · only you see this'
                            : 'This is you')
                        : score != null
                            ? '${(score * 100).round()}% match'
                            : 'View profile',
                    style: card.isSelf
                        ? AymaType.sans(size: 11, color: ac.fgMute)
                        : score != null
                            ? AymaType.mono(size: 10, color: ac.accent)
                            : AymaType.sans(size: 11, color: ac.fgMute),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// turn another user's photo path into a URL itself.
class _Photo extends StatelessWidget {
  const _Photo({required this.seed, this.url, this.name = ''});

  final String seed;
  final String? url;
  final String name;

  @override
  Widget build(BuildContext context) {
    final h1 = (seed.hashCode.abs() % 360).toDouble();
    // When there's no photo (or it fails to load), the tile is a seeded
    // gradient with a centred initial — the same graceful placeholder the
    // Messages avatars use — rather than a blank dark square (Issue F1).
    final initial =
        name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : '';
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, h1, 0.28, 0.30).toColor(),
            HSLColor.fromAHSL(1, (h1 + 40) % 360, 0.22, 0.18).toColor(),
          ],
        ),
      ),
      child: Center(
        child: initial.isNotEmpty
            ? Text(
                initial,
                style: AymaType.sans(
                  size: 32,
                  weight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.8),
                ),
              )
            : Icon(
                Icons.person_outline,
                size: 36,
                color: Colors.white.withValues(alpha: 0.6),
              ),
      ),
    );
    if (url == null || url!.isEmpty) return fallback;
    // Explore is list-heavy — decode/cache these small and hard.
    return AymaPhoto(url: url!, displayWidth: 260, error: fallback);
  }
}
