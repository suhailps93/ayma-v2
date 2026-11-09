import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../routing/app_router.dart';
import '../services/api_client.dart';
import '../services/inbox_actions.dart';
import '../services/notification_service.dart';
import '../theme.dart';
import '../widgets/ayma_rail_icons.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/ayma_wing_loader.dart';
import '../widgets/overflow_guards.dart';
import '../widgets/staggered.dart';
import 'notification_prefs_screen.dart';
import '../widgets/ayma_back_button.dart';

/// Notification centre (§7.3, §7.9 step 8): the most recent notifications,
/// newest first, grouped under mono-uppercase relative-date headers (Today /
/// Yesterday / This week / Older — founder redesign, 2026-09-22). Multiple
/// unread messages from the same person collapse into a single row with
/// their name and an unread count; opening it takes you to that conversation
/// and marks those messages read. Read vs unread is shown clearly — nothing
/// is marked read just by opening this screen.
class NotificationCenterScreen extends StatefulWidget {
  const NotificationCenterScreen({super.key, this.service, this.apiClient});

  static const path = '/notifications';

  final NotificationService? service;
  final ApiClient? apiClient;

  @override
  State<NotificationCenterScreen> createState() =>
      _NotificationCenterScreenState();
}

class _NotificationCenterScreenState extends State<NotificationCenterScreen> {
  late final NotificationService _svc = widget.service ?? NotificationService();
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late final String _myUid = _svc.currentUid;

  /// The active centre filter — shared with Ayma's
  /// `set_notification_filter` command via [NotificationFilterState]:
  /// a filter she sets applies here live, and the chips below write the
  /// same state she sets.
  NotificationFilter _filter = NotificationFilterState.instance.current.value;

  @override
  void initState() {
    super.initState();
    NotificationFilterState.instance.current.addListener(_onFilterState);
  }

  @override
  void dispose() {
    NotificationFilterState.instance.current.removeListener(_onFilterState);
    super.dispose();
  }

  void _onFilterState() {
    if (!mounted) return;
    setState(() => _filter = NotificationFilterState.instance.current.value);
  }

  final Map<String, MiniProfile> _mini = {};

  void _ensureMini(Set<String> uids) {
    final missing =
        uids.where((u) => u.isNotEmpty && !_mini.containsKey(u)).toList();
    if (missing.isEmpty) return;
    _api.miniProfiles(missing).then((m) {
      if (mounted && m.isNotEmpty) setState(() => _mini.addAll(m));
    }).catchError((_) {/* fall back to the initial letter */});
  }

  /// Fold the flat list into rows: one per non-DM notification, one per DM
  /// sender (all their unread messages together), newest-first by first
  /// appearance.
  List<_Entry> _entries(List<AppNotification> items) {
    final out = <_Entry>[];
    final dmIndex = <String, int>{}; // actor key -> index in `out`
    for (final n in items) {
      if (n.type == 'dm_message') {
        final key = n.resolveActorUid(_myUid);
        final bucket = key.isEmpty ? n.deepLink : key;
        final at = dmIndex[bucket];
        if (at == null) {
          dmIndex[bucket] = out.length;
          out.add(_Entry.dmGroup([n], key));
        } else {
          out[at].group.add(n);
        }
      } else {
        out.add(_Entry.single(n));
      }
    }
    return out;
  }

  /// Folds `entries` (already newest-first) into a flat render list of
  /// section-header labels and the entries under them — one header per
  /// contiguous run of the same relative-date bucket, so it only appears
  /// once even though every row in that span shares it.
  List<Object> _grouped(List<_Entry> entries) {
    final out = <Object>[];
    String? lastBucket;
    for (final e in entries) {
      final b = _dateBucket(e.when);
      if (b != lastBucket) {
        out.add(b);
        lastBucket = b;
      }
      out.add(e);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return StreamBuilder<List<AppNotification>>(
      stream: _svc.watch(),
      builder: (context, snap) {
        final items = snap.data ?? const <AppNotification>[];
        final entries = _entries(filterNotifications(items, _filter));
        final grouped = _grouped(entries);
        WidgetsBinding.instance.addPostFrameCallback((_) => _ensureMini(
            entries.where((e) => e.isDmGroup).map((e) => e.actorUid).toSet()));

        return Scaffold(
          appBar: AppBar(
        leading: const AymaBackButton(),
        
            title: const Text('Notifications'),
            actions: [
              if (items.isNotEmpty)
                IconButton(
                  tooltip: 'Mark all read',
                  icon: const Icon(Icons.done_all),
                  onPressed: () => _confirmMarkAllRead(items),
                ),
              if (items.isNotEmpty)
                IconButton(
                  tooltip: 'Clear all',
                  icon: const Icon(Icons.clear_all),
                  onPressed: () => _confirmClearAll(items),
                ),
              IconButton(
                tooltip: 'Preferences',
                icon: const Icon(Icons.tune),
                onPressed: () => context.push(NotificationPrefsScreen.path),
              ),
            ],
          ),
          body: Column(
            children: [
              if (items.isNotEmpty) _filterChips(ac),
              Expanded(
                child: Builder(builder: (context) {
            if (snap.hasError) {
              return CenteredScroll(
                padding: const EdgeInsets.all(24),
                child: Text('Could not load notifications (${snap.error}).',
                    style: AymaType.sans(size: 14, color: ac.errorText)),
              );
            }
            if (!snap.hasData) {
              // First emission of the notifications stream.
              return const Center(
                child: AymaWingLoader(lines: AymaLoaderLines.notifications),
              );
            }
            if (entries.isEmpty) {
              return Center(
                child: Text(
                    items.isEmpty
                        ? 'Nothing here yet.'
                        : 'Nothing matches this filter.',
                    style: AymaType.sans(
                        size: 15, soft: true, color: ac.fgMute)),
              );
            }
            var rowIndex = 0;
            return ListView.builder(
              itemCount: grouped.length,
              itemBuilder: (context, i) {
                final item = grouped[i];
                if (item is String) {
                  return _SectionHeader(label: item, isFirst: i == 0);
                }
                final e = item as _Entry;
                final delay = staggerDelay(rowIndex++);
                return Dismissible(
                  key: ValueKey(e.isDmGroup ? 'dm:${e.actorUid}:${e.notif.id}'
                      : e.notif.id),
                  direction: DismissDirection.endToStart,
                  onDismissed: (_) => _dismissEntry(e),
                  background: Container(
                    color: ac.lineSoft,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    child: Icon(Icons.close, size: 18, color: ac.fgMute),
                  ),
                  child: FadeSlideIn(
                    delay: delay,
                    child: Column(
                      children: [
                        _EntryRow(entry: e, mini: e.isDmGroup ? _mini[e.actorUid] : null,
                            onTap: () => _open(e)),
                        Divider(height: 1, color: ac.lineSoft),
                      ],
                    ),
                  ),
                );
              },
            );
                }),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The filter chips row (founder feedback item 11): one chip per
  /// [NotificationFilter] bucket; tapping writes the shared
  /// [NotificationFilterState] — the same state Ayma's
  /// `set_notification_filter` command sets.
  Widget _filterChips(AymaTokens ac) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Row(
        children: [
          for (final f in NotificationFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(f.label),
                selected: _filter == f,
                onSelected: (_) =>
                    NotificationFilterState.instance.setFilter(f),
              ),
            ),
        ],
      ),
    );
  }

  /// Confirms before marking everything read — lower-stakes than Clear all,
  /// but still a bulk action the founder wants a check on (§7.9).
  Future<void> _confirmMarkAllRead(List<AppNotification> items) async {
    final unread = items.where((n) => !n.read).toList();
    if (unread.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(
          'Mark ${unread.length} notification'
          '${unread.length == 1 ? '' : 's'} as read?',
        ),
        content: const Text("They'll no longer show as unread."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Mark read')),
        ],
      ),
    );
    if (ok != true) return;
    await _markAllRead(unread.map((n) => n.id).toList());
  }

  /// Catches internally, so the toast's Retry can safely re-invoke it.
  Future<void> _markAllRead(List<String> ids) async {
    try {
      await _svc.markReadMany(ids);
    } catch (e) {
      if (!mounted) return;
      AymaToast.show(context, 'Could not mark read ($e).',
          kind: AymaToastKind.error,
          action: AymaToastAction(
              label: 'Retry', onPressed: () => _markAllRead(ids)));
    }
  }

  Future<void> _confirmClearAll(List<AppNotification> items) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Clear all notifications?'),
        content: const Text(
          "They'll be removed from this list. This cannot be undone.",
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear all')),
        ],
      ),
    );
    if (ok != true) return;
    await _clearAll(items);
  }

  /// Catches internally, so the toast's Retry can safely re-invoke it.
  Future<void> _clearAll(List<AppNotification> items) async {
    try {
      await _svc.dismissAll(items);
    } catch (e) {
      if (!mounted) return;
      AymaToast.show(context, 'Could not clear ($e).',
          kind: AymaToastKind.error,
          action:
              AymaToastAction(label: 'Retry', onPressed: () => _clearAll(items)));
    }
  }

  Future<void> _dismissEntry(_Entry e) async {
    // Reuse the soft-dismiss write for every id the row covers. The list is
    // stream-driven, so a refused write reconciles itself (the row comes
    // back); the toast says why, with Retry from the same ids.
    try {
      for (final id in e.ids) {
        await _svc.dismiss(id);
      }
    } catch (err) {
      if (!mounted) return;
      AymaToast.show(context, 'Could not dismiss ($err).',
          kind: AymaToastKind.error,
          action: AymaToastAction(
              label: 'Retry', onPressed: () => _dismissEntry(e)));
    }
  }

  Future<void> _open(_Entry e) async {
    try {
      await _svc.markReadMany(e.ids);
    } catch (_) {
      // Best-effort — the user asked to open, not to mark read; the unread
      // badge is stream-driven and heals on the next open.
    }
    if (!mounted) return;
    navigateToRoute(deepLinkToRoute(e.notif.deepLink, myUid: _myUid),
        context: context);
  }
}

/// One notification-centre row: a single non-DM notification, or a DM sender
/// with all of their messages folded together.
class _Entry {
  _Entry.single(AppNotification n)
      : notif = n,
        group = <AppNotification>[],
        actorUid = '';

  _Entry.dmGroup(List<AppNotification> g, this.actorUid)
      : notif = g.first,
        group = g;

  /// The newest notification in the row (the representative).
  final AppNotification notif;

  /// Every DM in the group, newest first. Empty for a single non-DM row.
  final List<AppNotification> group;
  final String actorUid;

  bool get isDmGroup => group.isNotEmpty;

  List<String> get ids =>
      isDmGroup ? group.map((n) => n.id).toList() : <String>[notif.id];

  int get unreadCount => isDmGroup
      ? group.where((n) => !n.read).length
      : (notif.read ? 0 : 1);

  bool get read => unreadCount == 0;

  DateTime? get when => notif.createdAt;
}

/// Small uppercase mono section label ("TODAY" / "YESTERDAY" / "THIS WEEK" /
/// "OLDER") — the same all-caps letter-spaced eyebrow style
/// (`AymaType.mono`) already used for micro-labels elsewhere in the app
/// (e.g. the Living Report's section headings, Explore's location chip),
/// reused here rather than a new style, with a thin rule underneath echoing
/// the divider between rows.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.isFirst});

  final String label;
  final bool isFirst;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: EdgeInsets.only(top: isFirst ? 12 : 24, left: 20, right: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: AymaType.mono(size: 11, color: ac.fgMute)
                  .copyWith(letterSpacing: 2.4)),
          const SizedBox(height: 8),
          Divider(height: 1, color: ac.lineSoft),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.mini, required this.onTap});

  final _Entry entry;
  final MiniProfile? mini;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final unread = !entry.read;
    final n = entry.notif;
    final count = entry.unreadCount;
    final isCheckin = n.type == 'ayma_checkin';

    final String title;
    final String? subtitle;
    if (entry.isDmGroup) {
      final name = (mini?.name.isNotEmpty ?? false) ? mini!.name : 'Someone';
      title = count > 1 ? '$name · $count new messages' : name;
      subtitle = n.body.isEmpty ? 'New message' : n.body;
    } else if (n.body.isNotEmpty) {
      // The one string the backend gives us reads as the headline (a
      // proactive check-in's own question, a match/DM summary, …) — the
      // category name becomes the smaller supporting line beneath it.
      title = n.body;
      subtitle = notificationCategories[n.type];
    } else {
      title = notificationCategories[n.type] ?? n.type;
      subtitle = null;
    }

    final titleStyle = isCheckin
        ? AymaType.sans(
            size: 15, color: unread ? ac.fg : ac.fgDim, height: 1.4)
        : AymaType.sans(
            size: 14,
            color: unread ? ac.fg : ac.fgDim,
            weight: unread ? FontWeight.w600 : FontWeight.w400);

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Leading(notif: n),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: titleStyle),
                        ),
                        if (entry.when != null) ...[
                          const SizedBox(width: 8),
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(_clockLabel(entry.when!),
                                style: AymaType.mono(
                                    size: 11, color: ac.fgMute)),
                          ),
                        ],
                        if (count > 0) ...[
                          const SizedBox(width: 8),
                          _UnreadBadge(count: count, color: ac.accent),
                        ],
                      ],
                    ),
                    if (subtitle != null && subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AymaType.sans(
                              size: 13, soft: true, color: ac.fgMute)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count, required this.color});
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text('$count',
          style: AymaType.mono(size: 10, color: context.ac.onAccent)),
    );
  }
}

/// The row's leading circular icon — per-type, matching the icon language
/// already established for the same action elsewhere in the app (founder
/// spec, 2026-09-22: "the icons in the notification should match the icon
/// where it came from"):
///
/// - `mutual_match` (a mutual like) — [AymaHeartGlyph], the same heart glyph
///   the public-profile action rail's Like button uses.
/// - `new_scored_match` (Ayma surfaced a new candidate on her own) and a
///   `skill_result` whose deep link opens a match report (`match/…` or
///   `match_request/…`) — [AymaMatchGlyph], the rail's Match button glyph.
///   `skill_result` covers two different finished skills (deep dive *and*
///   match) under one notification type, so the deep link — not the type
///   string — decides which glyph matches.
/// - any other `skill_result` (a web search / deep dive finishing) —
///   [AymaSearchGlyph], the rail's web-search glyph.
/// - `dm_message` — [AymaChatGlyph], the rail's chat glyph.
/// - `ayma_checkin` and anything else with no dedicated glyph — the flat
///   [AymaWingsIcon] wings mark in the same `bgCard` disc, so every row
///   speaks one flat icon language (founder order, 2026-11-09). Ayma is the
///   first party behind these rows, so her wings read as "from Ayma" in
///   place of the glossy orb; the check-in title keeps its own `AymaType.sans`
///   size-15 treatment — see `_EntryRow.titleStyle`.
class _Leading extends StatelessWidget {
  const _Leading({required this.notif});

  final AppNotification notif;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: ac.bgCard, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: _glyphFor(notif, ac.accent),
    );
  }

  Widget _glyphFor(AppNotification n, Color accent) {
    switch (n.type) {
      case 'mutual_match':
        return AymaHeartGlyph(accent: accent, filled: true, size: 18);
      case 'new_scored_match':
        return AymaMatchGlyph(accent: accent, filled: true, size: 18);
      case 'dm_message':
        return AymaChatGlyph(accent: accent, filled: true, size: 18);
      case 'skill_result':
        final link = n.deepLink;
        if (link.startsWith('match/') || link.startsWith('match_request/')) {
          return AymaMatchGlyph(accent: accent, filled: true, size: 18);
        }
        return AymaSearchGlyph(accent: accent, filled: true, size: 18);
      default:
        return AymaWingsIcon(size: 18, color: accent);
    }
  }
}

/// "TODAY" / "YESTERDAY" / "THIS WEEK" / "OLDER" — the section a timestamp
/// falls into, calendar-day based (not a rolling 24h window) so "Yesterday"
/// means the previous calendar date regardless of what time it is now.
String _dateBucket(DateTime? t) {
  if (t == null) return 'OLDER';
  final now = DateTime.now();
  final startOfToday = DateTime(now.year, now.month, now.day);
  final startOfYesterday = startOfToday.subtract(const Duration(days: 1));
  final startOfWeek = startOfToday.subtract(const Duration(days: 7));
  if (!t.isBefore(startOfToday)) return 'TODAY';
  if (!t.isBefore(startOfYesterday)) return 'YESTERDAY';
  if (!t.isBefore(startOfWeek)) return 'THIS WEEK';
  return 'OLDER';
}

/// 12-hour clock label ("6:42 PM") — no separate date, since the section
/// header above each row already carries that context.
String _clockLabel(DateTime t) {
  final period = t.hour >= 12 ? 'PM' : 'AM';
  var h = t.hour % 12;
  if (h == 0) h = 12;
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m $period';
}
