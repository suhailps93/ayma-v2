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
import 'ayma_photo.dart';
import 'ayma_toast.dart';
import 'ayma_wing_loader.dart';

/// The AppBar Share action the web-research and Match report screens carry
/// (Appearance shares its image report card instead, straight to the native
/// OS share sheet — see `appearance_report_screen.dart`). [reportType]/
/// [reportId] are the same pair the screen's `LivingReportView` reads.
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

/// Share sheet: Share to Ayma, Send to a user, and the native OS share sheet.
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
  /// surfacing any failure as a toast.
  Future<void> _run(Future<void> Function(ReportShare s) action) async {
    if (_busy) return;
    final toast = AymaToast.of(context);
    setState(() => _busy = true);
    try {
      await action(await _ensureShare());
    } catch (_) {
      toast.show("Couldn't share that right now.", kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
          builder: (_) => RecipientPicker(
            dmService: widget.dmService,
            matchService: widget.matchService,
            api: _api,
          ),
        );
        if (picked == null || !mounted) return;
        final toast = AymaToast.of(context);
        await _svc.sendToThread(widget.dmService ?? DmService(), picked, s);
        toast.show('Sent.', kind: AymaToastKind.success);
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
            leading: const Icon(Icons.ios_share),
            title: const Text('Share'),
            onTap: _system,
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
        ],
      ),
    );
  }
}

/// Instagram-DM-style "send to" picker (BUG P): each recipient is a row with
/// their profile photo + name, a Send button, and a tappable avatar that opens
/// their profile. A search box filters by name, and mutual matches are listed
/// first. Reuses the same recipient data source as before — DM threads +
/// mutual matches (both keyed by the sorted-pair id) with names/photos from
/// `/profiles/mini` — and pops the chosen thread id for the sheet to send to.
class RecipientPicker extends StatefulWidget {
  const RecipientPicker({
    super.key,
    this.dmService,
    this.matchService,
    required this.api,
  });

  final DmService? dmService;
  final MatchService? matchService;
  final ApiClient api;

  @override
  State<RecipientPicker> createState() => RecipientPickerState();
}

class RecipientPickerState extends State<RecipientPicker> {
  late final DmService _dm = widget.dmService ?? DmService();
  late final MatchService _matches = widget.matchService ?? MatchService();
  late final Future<List<_Recipient>> _recipients = _load();
  String _query = '';

  Future<List<_Recipient>> _load() async {
    final threads = await _dm.watchThreads().first;
    final matches = await _matches.watchMutualMatches().first;
    final matchedUids = {for (final m in matches) m.otherUid};
    // Matches first, then DM-only threads; a pair that is both shares the one
    // sorted-pair id, so it lands once (as matched).
    final byId = <String, String>{};
    for (final m in matches) {
      byId[m.matchId] = m.otherUid;
    }
    for (final t in threads) {
      byId.putIfAbsent(t.threadId, () => t.otherUid);
    }
    if (byId.isEmpty) return const [];
    final minis = await widget.api.miniProfiles(byId.values.toList());
    final rows = [
      for (final e in byId.entries)
        _Recipient(
          threadId: e.key,
          uid: e.value,
          name: (minis[e.value]?.name ?? '').isEmpty
              ? 'Conversation'
              : minis[e.value]!.name,
          photo: minis[e.value]?.photo ?? '',
          matched: matchedUids.contains(e.value),
        ),
    ];
    // Matched users first, then the rest; each group alphabetical.
    rows.sort((a, b) {
      if (a.matched != b.matched) return a.matched ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: TextField(
                  key: const ValueKey('recipientSearch'),
                  onChanged: (v) => setState(() => _query = v.trim()),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search people',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    filled: true,
                    fillColor: ac.bgCard,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: ac.lineSoft),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: ac.lineSoft),
                    ),
                  ),
                ),
              ),
              Flexible(
                child: FutureBuilder<List<_Recipient>>(
                  future: _recipients,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return const _PickerMessage(
                          "Couldn't load your conversations.");
                    }
                    if (!snap.hasData) {
                      // Threads + matches + mini-profiles for the picker.
                      return const SizedBox(
                        height: 160,
                        child: Center(
                          child: AymaWingLoader(
                            size: 44,
                            lines: AymaLoaderLines.messages,
                          ),
                        ),
                      );
                    }
                    final all = snap.data!;
                    if (all.isEmpty) {
                      return const _PickerMessage(
                          'No conversations or matches yet.');
                    }
                    final q = _query.toLowerCase();
                    final rows = q.isEmpty
                        ? all
                        : [
                            for (final r in all)
                              if (r.name.toLowerCase().contains(q)) r,
                          ];
                    if (rows.isEmpty) {
                      return const _PickerMessage('No people match your search.');
                    }
                    return ListView.builder(
                      shrinkWrap: true,
                      itemCount: rows.length,
                      itemBuilder: (context, i) => _RecipientRow(
                        recipient: rows[i],
                        onSend: () => Navigator.pop(context, rows[i].threadId),
                        onOpenProfile: rows[i].uid.isEmpty
                            ? null
                            : () => context.push('/profile/user/${rows[i].uid}'),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One Instagram-DM-style recipient row: tappable avatar (→ profile), name
/// (+ a "Matched" hint), and a Send button that triggers the share.
class _RecipientRow extends StatelessWidget {
  const _RecipientRow({
    required this.recipient,
    required this.onSend,
    this.onOpenProfile,
  });

  final _Recipient recipient;
  final VoidCallback onSend;
  final VoidCallback? onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return ListTile(
      leading: GestureDetector(
        onTap: onOpenProfile,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ac.bgCard,
            border: Border.all(color: ac.lineSoft),
          ),
          clipBehavior: Clip.antiAlias,
          child: recipient.photo.isEmpty
              ? Icon(Icons.person, color: ac.fgMute, size: 22)
              : AymaPhoto(
                  url: recipient.photo,
                  displayWidth: 44,
                  error: Icon(Icons.person, color: ac.fgMute, size: 22),
                ),
        ),
      ),
      title: Text(recipient.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: recipient.matched
          ? Text('Matched',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AymaType.sans(size: 12, color: ac.accent))
          : null,
      trailing: TextButton(
        onPressed: onSend,
        child: const Text('Send'),
      ),
      onTap: onOpenProfile,
    );
  }
}

class _Recipient {
  const _Recipient({
    required this.threadId,
    required this.uid,
    required this.name,
    required this.photo,
    required this.matched,
  });
  final String threadId;
  final String uid;
  final String name;
  final String photo;
  final bool matched;
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
