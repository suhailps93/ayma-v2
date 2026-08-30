import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/dm_service.dart';
import '../services/match_service.dart';
import '../theme.dart';
import '../widgets/notification_bell.dart';

/// Messages tab (§11.3): mutual matches and DM threads unified in one list.
/// A mutual match with no thread yet shows as a "start the conversation" row;
/// once a thread exists it shows the conversation row instead. Every row opens
/// `/dm/:threadId`.
class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key, this.dmService, this.matchService});

  static const path = '/messages';

  final DmService? dmService;
  final MatchService? matchService;

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  late final DmService _dm = widget.dmService ?? DmService();
  late final MatchService _matches = widget.matchService ?? MatchService();

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        actions: const [NotificationBellButton()],
      ),
      body: StreamBuilder<List<DmThread>>(
        stream: _dm.watchThreads(),
        builder: (context, threadSnap) {
          return StreamBuilder<List<MatchView>>(
            stream: _matches.watchMutualMatches(),
            builder: (context, matchSnap) {
              if (!threadSnap.hasData && !matchSnap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final threads = threadSnap.data ?? const <DmThread>[];
              final matches = matchSnap.data ?? const <MatchView>[];
              final threadByUid = {for (final t in threads) t.otherUid: t};

              final rows = <_Row>[
                for (final t in threads)
                  _Row.thread(t, matched: matches
                      .any((m) => m.otherUid == t.otherUid)),
                for (final m in matches)
                  if (!threadByUid.containsKey(m.otherUid)) _Row.match(m),
              ]..sort((a, b) => b.sortKey.compareTo(a.sortKey));

              if (rows.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'No matches or conversations yet.\nExplore to get started.',
                      textAlign: TextAlign.center,
                      style: AymaType.sans(
                          size: 15, soft: true, color: ac.fgMute),
                    ),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: rows.length,
                separatorBuilder: (_, __) =>
                    Divider(height: 1, color: ac.lineSoft),
                itemBuilder: (context, i) => rows[i].build(context),
              );
            },
          );
        },
      ),
    );
  }
}

class _Row {
  _Row._({
    required this.threadId,
    required this.title,
    required this.subtitle,
    required this.matched,
    required this.sortKey,
  });

  factory _Row.thread(DmThread t, {required bool matched}) => _Row._(
        threadId: t.threadId,
        title: 'Conversation',
        subtitle: t.lastMessageAt == null
            ? 'No messages yet'
            : 'Last activity ${_ago(t.lastMessageAt!)}',
        matched: matched,
        sortKey: t.lastMessageAt?.millisecondsSinceEpoch.toString() ??
            '0',
      );

  factory _Row.match(MatchView m) => _Row._(
        threadId: m.matchId, // matches + dm_threads share the sorted-pair id
        title: m.otherName,
        subtitle: m.myExplanation.isEmpty
            ? 'You matched — say hello'
            : m.myExplanation,
        matched: true,
        sortKey: 'zzz', // fresh matches float to the top
      );

  final String threadId;
  final String title;
  final String subtitle;
  final bool matched;
  final String sortKey;

  Widget build(BuildContext context) {
    final ac = context.ac;
    return ListTile(
      onTap: () => context.push('/dm/$threadId'),
      title: Row(
        children: [
          Flexible(
            child: Text(title,
                style: AymaType.sans(size: 15, color: ac.fg),
                overflow: TextOverflow.ellipsis),
          ),
          if (matched) ...[
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: ac.accentSoft,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text('Matched',
                  style: AymaType.mono(size: 9, color: ac.accent)),
            ),
          ],
        ],
      ),
      subtitle: Text(subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AymaType.sans(size: 13, soft: true, color: ac.fgMute)),
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}
