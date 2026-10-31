import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/chat_inbox.dart';
import '../theme.dart';
import '../widgets/app_loading_indicator.dart';
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
  const ExploreScreen({super.key, this.apiClient, this.initialQuery = ''});

  static const path = '/explore';

  final ApiClient? apiClient;

  /// Pre-fill the search box and run it once — used when Ayma opens Explore
  /// with a query in a voice call (`?q=…`), or via [AppContext.pendingExploreQuery].
  final String initialQuery;

  @override
  State<ExploreScreen> createState() => ExploreScreenState();
}

enum _Filter { all, liked, mutual, scored }

/// Public so [MainShellScreen] — which keeps this screen alive across tab
/// switches in an `IndexedStack` rather than rebuilding it — can reach in and
/// refetch when Explore becomes the visible tab again. Without this, a score
/// or like recorded elsewhere (recalculating a match report, say) never
/// shows up here until the app restarts: `initState` only runs once, the
/// very first time the tab is built.
class ExploreScreenState extends State<ExploreScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  final _searchController = TextEditingController();
  Timer? _debounce;

  bool _loading = true;
  String? _error;
  List<ExploreCard> _cards = const [];
  _Filter _filter = _Filter.all;

  List<ExploreCard> get _visibleCards {
    if (_filter == _Filter.all) return _cards;
    return _cards.where((c) {
      if (c.isSelf) return true; // your card always shows
      return switch (_filter) {
        _Filter.liked => c.liked,
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
    _syncContext();
    _load();
  }

  static const _filterLabels = {
    _Filter.all: 'Everyone',
    _Filter.liked: 'Your likes',
    _Filter.mutual: 'Mutual',
    _Filter.scored: 'Match run',
  };

  /// Mirrors what the grid shows (query, active chip, the people) into the
  /// screen context Ayma reads, so she can describe the page.
  void _syncContext() {
    AppContext.instance.set(
      screen: 'explore',
      note: _searchController.text.trim(),
      detail: _loading || _error != null
          ? ''
          : exploreSummary(
              query: _searchController.text,
              filterLabel: _filterLabels[_filter]!,
              cards: _visibleCards,
            ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// Refetch the feed — called by [_load] itself, and by [MainShellScreen]
  /// each time this tab becomes visible again after the first build (a
  /// re-selected tab, or Android back landing on it). A fetch already in
  /// flight is left alone rather than raced against a second one.
  Future<void> reload() => _loading ? Future<void>.value() : _load();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cards = await _api.explore(q: _searchController.text.trim());
      if (!mounted) return;
      setState(() {
        _cards = cards;
        _loading = false;
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load Explore ($e).';
        _loading = false;
      });
    }
  }

  void _onSearchChanged(String _) {
    _syncContext();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _load);
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
                onChanged: _onSearchChanged,
                onSubmitted: (_) => _load(),
                decoration: const InputDecoration(
                  hintText: 'Describe who you’re looking for…',
                  prefixIcon: Icon(Icons.search),
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
            const SizedBox(height: 4),
          ],
          body: _loading
              ? const AppLoadingIndicator()
              : _error != null
                  ? CenteredScroll(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!,
                          style: AymaType.sans(
                              size: 14, color: AymaColors.error)),
                    )
                  : _visibleCards.isEmpty
                      ? Center(
                          child: Text(
                              _filter == _Filter.all
                                  ? 'No one matches that yet.'
                                  : 'Nothing here for this filter.',
                              style: AymaType.sans(
                                  size: 15,
                                  soft: true,
                                  color: ac.fgMute)),
                        )
                      : GridView.builder(
                          // Search field above: dragging the results
                          // away dismisses the keyboard (iOS has no
                          // dismiss key).
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          // Two columns on a phone; more on the Fold's inner
                          // display, a tablet or landscape, instead of two
                          // giant cards.
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 240,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.66,
                          ),
                          itemCount: _visibleCards.length,
                          itemBuilder: (context, i) => FadeSlideIn(
                            delay: staggerDelay(i),
                            child:
                                _Card(card: _visibleCards[i], api: _api),
                          ),
                        ),
          headerShare: 0.5,
          footerShare: 0.5,
        ),
      ),
    );
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
      if (c.mutual) 'mutual like' else if (c.liked) 'you liked',
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
                  _Photo(seed: card.uid, url: card.photoUrl),
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
  const _Photo({required this.seed, this.url});

  final String seed;
  final String? url;

  @override
  Widget build(BuildContext context) {
    final h1 = (seed.hashCode.abs() % 360).toDouble();
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
    );
    if (url == null || url!.isEmpty) return fallback;
    // Explore is list-heavy — decode/cache these small and hard.
    return AymaPhoto(url: url!, displayWidth: 260, error: fallback);
  }
}
