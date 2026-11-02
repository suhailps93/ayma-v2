import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/match_service.dart';
import '../theme.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/nav_bar_shell.dart';
import '../widgets/overflow_guards.dart';
import '../widgets/staggered.dart';
import 'public_profile_screen.dart';
import '../widgets/ayma_back_button.dart';

/// "New from Ayma" — scored matches awaiting a response (§5.8, §14.3). Tap a
/// card for the detail + accept/reject.
class MatchesScreen extends StatefulWidget {
  const MatchesScreen({super.key, this.matchService, this.api});

  static const path = '/matches';

  final MatchService? matchService;
  final ApiClient? api;

  @override
  State<MatchesScreen> createState() => _MatchesScreenState();
}

class _MatchesScreenState extends State<MatchesScreen>
    with ScreenContextReasserter<MatchesScreen> {
  late final MatchService _matches = widget.matchService ?? MatchService();

  @override
  void initState() {
    super.initState();
    reassertScreenContext();
  }

  @override
  void reassertScreenContext() => AppContext.instance.set(screen: 'matches');

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('New from Ayma')),
      body: StreamBuilder<List<MatchView>>(
        stream: _matches.watchNewMatches(),
        builder: (context, snap) {
          if (snap.hasError) {
            return CenteredScroll(
              padding: const EdgeInsets.all(24),
              child: Text('Could not load matches (${snap.error}).',
                  style: AymaType.sans(size: 14, color: AymaColors.error)),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return CenteredScroll(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                "No new matches yet. Keep talking to Ayma — she's still "
                'getting to know you.',
                textAlign: TextAlign.center,
                style: AymaType.sans(size: 15, soft: true, color: ac.fgMute),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, i) => FadeSlideIn(
              delay: staggerDelay(i),
              child: _MatchCard(match: items[i], service: _matches, api: widget.api),
            ),
          );
        },
      ),
    );
  }
}

class _MatchCard extends StatelessWidget {
  const _MatchCard({required this.match, required this.service, this.api});
  final MatchView match;
  final MatchService service;
  final ApiClient? api;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        // Pushed directly here (already has the `MatchView` in hand, so no
        // point re-fetching via the `/match-request/:matchId` GoRoute the
        // deep-link path below uses) rather than through GoRouter, so it
        // isn't covered by `app_router.dart`'s per-route `NavBarShell`
        // wrapping the way every other screen is. Wrap it here instead, same
        // widget, same effect.
        builder: (_) => NavBarShell(
          child: MatchDetailScreen(
            matchId: match.matchId,
            initialMatch: match,
            service: service,
            api: api,
          ),
        ),
      )),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: ac.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: ac.lineSoft, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(match.otherName,
                      style: AymaType.sans(size: 16, weight: FontWeight.w600, color: ac.fg)),
                ),
                Text('${(match.score * 100).round()}%',
                    style: AymaType.mono(size: 12, color: ac.accent)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              match.myExplanation,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: AymaType.sans(size: 14, color: ac.fgDim, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// What [MatchDetailScreen] needs once loaded: the match itself (score,
/// Ayma's blurb, response state) plus the same full [PublicProfile] the
/// public profile screen renders (photos, name, age, location, bio).
class _MatchRequestData {
  const _MatchRequestData(this.match, this.profile);
  final MatchView match;
  final PublicProfile profile;
}

/// The match-request screen — "Ayma found someone for you" (§5.8, §14.3).
/// Shows the *same full public profile* [PublicProfileScreen] shows
/// (reusing [PublicProfileBody]) with Ayma's match score/blurb and the
/// Pass/Accept actions layered on top, not in place of it.
///
/// Reachable two ways: tapped from the "New from Ayma" list (which already
/// has the [MatchView] loaded — passed as [initialMatch] so this screen
/// doesn't re-fetch it), or opened directly via [path] from a notification
/// tap / deep link (§7.6), which only has the id.
class MatchDetailScreen extends StatefulWidget {
  const MatchDetailScreen({
    super.key,
    required this.matchId,
    this.initialMatch,
    this.service,
    this.api,
  });

  /// Registered in `app_router.dart` for the `match_request/{id}` deep link
  /// — a notification tap opens this exact match request directly instead
  /// of landing on the list (or, before that routing existed, on chat).
  static const path = '/match-request/:matchId';

  final String matchId;
  final MatchView? initialMatch;
  final MatchService? service;
  final ApiClient? api;

  @override
  State<MatchDetailScreen> createState() => _MatchDetailScreenState();
}

class _MatchDetailScreenState extends State<MatchDetailScreen> {
  late final MatchService _matches = widget.service ?? MatchService();
  late final ApiClient _api = widget.api ?? ApiClient();
  late Future<_MatchRequestData> _future = _load();

  bool _working = false;
  String? _done;

  Future<_MatchRequestData> _load() async {
    final match = widget.initialMatch ?? await _matches.fetchMatch(widget.matchId);
    final profile = await _api.publicProfile(match.otherUid);
    return _MatchRequestData(match, profile);
  }

  Future<void> _respond(bool accept) async {
    setState(() => _working = true);
    try {
      await _matches.respond(widget.matchId, accept: accept);
      if (!mounted) return;
      setState(() => _done = accept ? 'Accepted' : 'Passed');
    } catch (e) {
      if (!mounted) return;
      AymaToast.show(context, 'That didn\'t work ($e).',
          kind: AymaToastKind.error,
          action: AymaToastAction(
              label: 'Retry', onPressed: () => _respond(accept)));
      setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      body: FutureBuilder<_MatchRequestData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SafeArea(
                child: Center(child: CircularProgressIndicator()));
          }
          if (snap.hasError || !snap.hasData) {
            return SafeArea(
              child: CenteredScroll(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text("Couldn't load this match.",
                        style: AymaType.sans(size: 14, color: ac.fgMute)),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () => setState(() => _future = _load()),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }
          final m = snap.data!.match;
          final p = snap.data!.profile;
          final displayName = p.name.isEmpty
              ? (m.otherName.isEmpty ? 'Someone' : m.otherName)
              : p.name;
          return ChromeColumn(
            header: [
              SafeArea(
                bottom: false,
                child: SizedBox(
                  height: 52,
                  child: Row(
                    children: [
                      const BackButton(),
                      Expanded(
                        child: Text(displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AymaType.sans(size: 16, weight: FontWeight.w600, color: ac.fg)),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ),
            ],
            body: ProfileBody(
              // Ayma's own case for this match — kept as an addition above
              // the full profile, not a replacement for it. It rides inside
              // the profile's own scroll (not the capped ChromeColumn header)
              // so a long explanation gets full width and room to breathe
              // instead of being crammed against the photo (§ BUG).
              leading: Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: ac.bgCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: ac.lineSoft, width: 0.5),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${(m.score * 100).round()}% match',
                        style: AymaType.mono(
                            size: 14, weight: FontWeight.w600, color: ac.accent)),
                    if (m.myExplanation.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(m.myExplanation,
                          style: AymaType.sans(
                              size: 14, color: ac.fgDim, height: 1.4)),
                    ],
                  ],
                ),
              ),
              reportType: 'public_profile',
              reportId: p.uid,
              api: _api,
              profile: p,
            ),
            footer: [
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  child: _done != null
                      ? Text(_done!,
                          textAlign: TextAlign.center,
                          style: AymaType.sans(size: 16, color: ac.fg, height: 1.4))
                      : Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed:
                                    _working ? null : () => _respond(false),
                                child: const Text('Pass'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                onPressed:
                                    _working ? null : () => _respond(true),
                                child: const Text('Accept'),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
            headerShare: 0.4,
            footerShare: 0.3,
          );
        },
      ),
    );
  }
}
