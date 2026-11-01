import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/dm_service.dart';
import '../services/fresh_data.dart';
import '../services/match_service.dart';
import '../theme.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/freshness_indicator.dart';
import '../widgets/overflow_guards.dart';
import '../widgets/staggered.dart';

/// Messages tab (§11.3): mutual matches and DM threads unified in one list.
/// A mutual match with no thread yet shows as a "start the conversation" row;
/// once a thread exists it shows the conversation row instead. Every row opens
/// `/dm/:threadId`.
class MessagesScreen extends StatefulWidget {
  const MessagesScreen({
    super.key,
    this.dmService,
    this.matchService,
    this.apiClient,
  });

  static const path = '/messages';

  final DmService? dmService;
  final MatchService? matchService;
  final ApiClient? apiClient;

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  late final DmService _dm = widget.dmService ?? DmService();
  late final MatchService _matches = widget.matchService ?? MatchService();
  late final ApiClient _api = widget.apiClient ?? ApiClient();

  @override
  void initState() {
    super.initState();
    // Belt-and-braces with the tab shell, which also sets this on tab change /
    // pop-back — but a lazily-built tab's first appearance is its own event.
    AppContext.instance.set(screen: 'messages');
  }

  /// otherUid -> name + photo, resolved server-side (a client can't turn
  /// another user's photo path into a URL itself).
  final Map<String, MiniProfile> _mini = {};
  bool _fetchingMini = false;

  void _ensureMini(Set<String> uids) {
    final missing = uids.where((u) => u.isNotEmpty && !_mini.containsKey(u))
        .toList();
    if (missing.isEmpty || _fetchingMini) return;
    _fetchingMini = true;
    _api.miniProfiles(missing).then((m) {
      if (!mounted) return;
      setState(() {
        _mini.addAll(m);
        _fetchingMini = false;
      });
    }).catchError((_) {
      _fetchingMini = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: StreamBuilder<FreshData<List<DmThread>>>(
          stream: _dm.watchThreadsFresh(),
          builder: (context, threadSnap) {
            return StreamBuilder<FreshData<List<MatchView>>>(
              stream: _matches.watchMutualMatchesFresh(),
              builder: (context, matchSnap) {
                final threadFresh = threadSnap.data;
                final matchFresh = matchSnap.data;
                final waiting = threadFresh == null && matchFresh == null;
                final freshness = (threadFresh != null && matchFresh != null)
                    ? FreshData.mergeMeta<bool>(
                        data: (threadFresh.hasData || matchFresh.hasData)
                            ? true
                            : null,
                        a: threadFresh,
                        b: matchFresh,
                      )
                    : (threadFresh ?? matchFresh);

                return Column(
                  children: [
                    const AymaScreenHeader(
                      title: 'Messages',
                      // Back arrow when pushed standalone (deep link /
                      // `open_screen`) — invisible in the shell tab, where
                      // the route can't pop.
                      automaticallyImplyBack: true,
                    ),
                    if (freshness != null)
                      FreshnessIndicator.fromFresh(freshness),
                    Expanded(
                      child: waiting
                          ? const Center(child: CircularProgressIndicator())
                          : _list(
                              context,
                              ac,
                              threads: threadFresh?.data ?? const <DmThread>[],
                              matches:
                                  matchFresh?.data ?? const <MatchView>[],
                            ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _list(
    BuildContext context,
    AymaTokens ac, {
    required List<DmThread> threads,
    required List<MatchView> matches,
  }) {
    final threadByUid = {for (final t in threads) t.otherUid: t};

    final rows = <_Row>[
      for (final t in threads)
        _Row.thread(t,
            matched: matches.any((m) => m.otherUid == t.otherUid)),
      for (final m in matches)
        if (!threadByUid.containsKey(m.otherUid)) _Row.match(m),
    ]..sort((a, b) => b.sortKey.compareTo(a.sortKey));

    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _ensureMini(rows.map((r) => r.otherUid).toSet()));

    if (rows.isEmpty) {
      return CenteredScroll(
        padding: const EdgeInsets.all(32),
        child: Text(
          'No matches or conversations yet.\nExplore to get started.',
          textAlign: TextAlign.center,
          style: AymaType.sans(size: 15, soft: true, color: ac.fgMute),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rows.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: ac.lineSoft),
      itemBuilder: (context, i) => FadeSlideIn(
        delay: staggerDelay(i),
        child: rows[i].build(context, _mini[rows[i].otherUid]),
      ),
    );
  }
}

class _Row {
  _Row._({
    required this.threadId,
    required this.otherUid,
    required this.fallbackName,
    required this.subtitle,
    required this.matched,
    required this.sortKey,
    this.unread = 0,
  });

  factory _Row.thread(DmThread t, {required bool matched}) => _Row._(
        threadId: t.threadId,
        otherUid: t.otherUid,
        fallbackName: 'Conversation',
        subtitle: t.lastMessageAt == null
            ? 'No messages yet'
            : 'Last activity ${_ago(t.lastMessageAt!)}',
        matched: matched,
        unread: t.unread,
        sortKey: t.lastMessageAt?.millisecondsSinceEpoch.toString() ??
            '0',
      );

  factory _Row.match(MatchView m) => _Row._(
        threadId: m.matchId, // matches + dm_threads share the sorted-pair id
        otherUid: m.otherUid,
        fallbackName: m.otherName,
        subtitle: m.myExplanation.isEmpty
            ? 'You matched — say hello'
            : m.myExplanation,
        matched: true,
        sortKey: 'zzz', // fresh matches float to the top
      );

  final String threadId;
  final String otherUid;
  final String fallbackName;
  final String subtitle;
  final bool matched;
  final String sortKey;
  final int unread;

  Widget build(BuildContext context, MiniProfile? mini) {
    final ac = context.ac;
    final name = (mini?.name.isNotEmpty ?? false) ? mini!.name : fallbackName;
    final photo = mini?.photo ?? '';
    final hasUnread = unread > 0;
    return ListTile(
      onTap: () => context.push('/dm/$threadId'),
      leading: ClipOval(
        child: SizedBox(
          width: 40,
          height: 40,
          child: photo.isEmpty
              ? Container(
                  color: ac.bgCard,
                  alignment: Alignment.center,
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: AymaType.sans(size: 16, color: ac.fgMute),
                  ),
                )
              : AymaPhoto(url: photo, displayWidth: 40),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(name,
                style: AymaType.sans(
                    size: 15,
                    color: ac.fg,
                    weight: hasUnread ? FontWeight.w700 : FontWeight.w400),
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
          style: AymaType.sans(
              size: 13,
              soft: !hasUnread,
              color: hasUnread ? ac.fg : ac.fgMute,
              weight: hasUnread ? FontWeight.w600 : FontWeight.w400)),
      trailing: hasUnread
          ? Container(
              key: const ValueKey('unread-badge'),
              constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: ac.accent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Center(
                  widthFactor: 1,
                  heightFactor: 1,
                  child: Text(unread > 99 ? '99+' : '$unread',
                      style: AymaType.sans(
                          size: 12, color: ac.bg, weight: FontWeight.w700)),
              ),
            )
          : null,
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
