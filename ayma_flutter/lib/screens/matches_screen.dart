import 'package:flutter/material.dart';

import '../services/app_context.dart';
import '../services/match_service.dart';
import '../theme.dart';
import '../widgets/staggered.dart';

/// "New from Ayma" — scored matches awaiting a response (§5.8, §14.3). Tap a
/// card for the detail + accept/reject.
class MatchesScreen extends StatefulWidget {
  const MatchesScreen({super.key, this.matchService});

  static const path = '/matches';

  final MatchService? matchService;

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
      appBar: AppBar(title: const Text('New from Ayma')),
      body: StreamBuilder<List<MatchView>>(
        stream: _matches.watchNewMatches(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not load matches (${snap.error}).',
                    style: AymaType.sans(size: 14, color: AymaColors.error)),
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  "No new matches yet. Keep talking to Ayma — she's still "
                  'getting to know you.',
                  textAlign: TextAlign.center,
                  style: AymaType.sans(size: 15, soft: true, color: ac.fgMute),
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, i) => FadeSlideIn(
              delay: staggerDelay(i),
              child: _MatchCard(match: items[i], service: _matches),
            ),
          );
        },
      ),
    );
  }
}

class _MatchCard extends StatelessWidget {
  const _MatchCard({required this.match, required this.service});
  final MatchView match;
  final MatchService service;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MatchDetailScreen(match: match, service: service),
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
                      style: AymaType.serif(size: 20, color: ac.fg)),
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

class MatchDetailScreen extends StatefulWidget {
  const MatchDetailScreen({
    super.key,
    required this.match,
    required this.service,
  });

  final MatchView match;
  final MatchService service;

  @override
  State<MatchDetailScreen> createState() => _MatchDetailScreenState();
}

class _MatchDetailScreenState extends State<MatchDetailScreen> {
  bool _working = false;
  String? _done;

  Future<void> _respond(bool accept) async {
    setState(() => _working = true);
    try {
      await widget.service.respond(widget.match.matchId, accept: accept);
      if (!mounted) return;
      setState(() => _done = accept ? 'Accepted' : 'Passed');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('That didn\'t work ($e).')));
      setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final m = widget.match;
    return Scaffold(
      appBar: AppBar(title: Text(m.otherName)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        children: [
          Text('${(m.score * 100).round()}% match',
              style: AymaType.mono(size: 13, color: ac.accent)),
          const SizedBox(height: 16),
          Text(m.myExplanation,
              style: AymaType.sans(size: 16, color: ac.fgDim, height: 1.5)),
          const SizedBox(height: 32),
          if (_done != null)
            Text(_done!,
                style: AymaType.serif(size: 18, color: ac.fg))
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _working ? null : () => _respond(false),
                    child: const Text('Pass'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _working ? null : () => _respond(true),
                    child: const Text('Accept'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
