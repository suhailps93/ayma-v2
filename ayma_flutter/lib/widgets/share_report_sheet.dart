import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/report_share.dart';
import '../screens/main_shell_screen.dart';
import '../services/api_client.dart';
import '../services/chat_inbox.dart';
import '../services/dm_service.dart';
import '../services/match_service.dart';
import '../services/share_service.dart';
import '../theme.dart';

/// The AppBar Share action every shareable report screen (web research,
/// Appearance, Match) carries. [reportType]/[reportId] are the same pair the
/// screen's `LivingReportView` reads.
class ShareReportButton extends StatelessWidget {
  const ShareReportButton({
    super.key,
    required this.reportType,
    required this.reportId,
    this.service,
    this.dmService,
    this.matchService,
    this.apiClient,
  });

  final String reportType;
  final String reportId;
  final ShareService? service;
  final DmService? dmService;
  final MatchService? matchService;
  final ApiClient? apiClient;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Share',
        icon: const Icon(Icons.ios_share),
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (_) => ShareReportSheet(
            reportType: reportType,
            reportId: reportId,
            service: service,
            dmService: dmService,
            matchService: matchService,
            apiClient: apiClient,
          ),
        ),
      );
}

/// Share sheet: Instagram Story, Share to Ayma, Send to a user, system sheet.
class ShareReportSheet extends StatefulWidget {
  const ShareReportSheet({
    super.key,
    required this.reportType,
    required this.reportId,
    this.service,
    this.dmService,
    this.matchService,
    this.apiClient,
  });

  final String reportType;
  final String reportId;
  final ShareService? service;
  final DmService? dmService;
  final MatchService? matchService;
  final ApiClient? apiClient;

  @override
  State<ShareReportSheet> createState() => _ShareReportSheetState();
}

class _ShareReportSheetState extends State<ShareReportSheet> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late final ShareService _svc = widget.service ?? ShareService(api: _api);
  ReportShare? _share;
  bool _busy = false;

  Future<ReportShare> _ensureShare() async =>
      _share ??= await _svc.create(widget.reportType, widget.reportId);

  /// Runs [action] with the created share, guarding against double taps and
  /// surfacing any failure as a snack bar.
  Future<void> _run(Future<void> Function(ReportShare s) action) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await action(await _ensureShare());
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text("Couldn't share that right now.")));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _instagram() => _run((s) async {
        if (!await _svc.shareToInstagramStory(s)) {
          await _svc.shareViaSystem(s);
        }
        if (mounted) Navigator.pop(context);
      });

  Future<void> _ayma() => _run((s) async {
        ChatInbox.instance.push(ChatKickoff.draftText(
            "Let's talk about this report.\n${s.plainMessage}"));
        final router = GoRouter.of(context);
        Navigator.pop(context);
        router.go(MainShellScreen.path);
      });

  Future<void> _system() => _run((s) async {
        await _svc.shareViaSystem(s);
        if (mounted) Navigator.pop(context);
      });

  Future<void> _sendToUser() => _run((s) async {
        final picked = await showModalBottomSheet<String>(
          context: context,
          isScrollControlled: true,
          builder: (_) => _RecipientPicker(
            dmService: widget.dmService,
            matchService: widget.matchService,
            api: _api,
          ),
        );
        if (picked == null || !mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        await _svc.sendToThread(widget.dmService ?? DmService(), picked, s);
        messenger.showSnackBar(const SnackBar(content: Text('Sent.')));
        if (mounted) Navigator.pop(context);
      });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_busy) const LinearProgressIndicator(),
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined),
            title: const Text('Instagram Story'),
            onTap: _instagram,
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('Share to Ayma'),
            onTap: _ayma,
          ),
          ListTile(
            leading: const Icon(Icons.send_outlined),
            title: const Text('Send to a user'),
            onTap: _sendToUser,
          ),
          ListTile(
            leading: const Icon(Icons.ios_share),
            title: const Text('More…'),
            onTap: _system,
          ),
        ],
      ),
    );
  }
}

/// Lists existing DM conversations and mutual matches; pops the chosen
/// thread id (matches and DM threads share the sorted-pair id).
class _RecipientPicker extends StatefulWidget {
  const _RecipientPicker({this.dmService, this.matchService, required this.api});

  final DmService? dmService;
  final MatchService? matchService;
  final ApiClient api;

  @override
  State<_RecipientPicker> createState() => _RecipientPickerState();
}

class _RecipientPickerState extends State<_RecipientPicker> {
  late final DmService _dm = widget.dmService ?? DmService();
  late final MatchService _matches = widget.matchService ?? MatchService();
  late final Future<List<_Recipient>> _recipients = _load();

  Future<List<_Recipient>> _load() async {
    final threads = await _dm.watchThreads().first;
    final matches = await _matches.watchMutualMatches().first;
    final byThread = <String, String>{
      for (final m in matches) m.matchId: m.otherUid,
      for (final t in threads) t.threadId: t.otherUid,
    };
    if (byThread.isEmpty) return const [];
    final names = await widget.api.miniProfiles(byThread.values.toList());
    return [
      for (final e in byThread.entries)
        _Recipient(
          threadId: e.key,
          name: (names[e.value]?.name ?? '').isEmpty
              ? 'Conversation'
              : names[e.value]!.name,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .6),
        child: FutureBuilder<List<_Recipient>>(
          future: _recipients,
          builder: (context, snap) {
            if (snap.hasError) {
              return const _PickerMessage("Couldn't load your conversations.");
            }
            if (!snap.hasData) {
              return const SizedBox(
                  height: 160,
                  child: Center(child: CircularProgressIndicator()));
            }
            final rows = snap.data!;
            if (rows.isEmpty) {
              return const _PickerMessage('No conversations or matches yet.');
            }
            return ListView(
              shrinkWrap: true,
              children: [
                for (final r in rows)
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(r.name),
                    onTap: () => Navigator.pop(context, r.threadId),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Recipient {
  const _Recipient({required this.threadId, required this.name});
  final String threadId;
  final String name;
}

class _PickerMessage extends StatelessWidget {
  const _PickerMessage(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 160,
        child: Center(
          child: Text(text,
              style: AymaType.sans(size: 14, color: context.ac.fgMute)),
        ),
      );
}
