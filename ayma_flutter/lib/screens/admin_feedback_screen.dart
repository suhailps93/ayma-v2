import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_photo.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/ayma_wing_loader.dart';

/// Developer → Feedback: the product-feedback triage list (§15). Shows every
/// row from the unified `feedback` collection's product sources — the in-chat
/// catcher (`chat_card`) and the Settings form (`settings_form`) together —
/// with kind, title, body, screenshots, the screen it came from, app version,
/// platform, user and status. Read-mostly; the only write is changing a row's
/// triage status. Reached from the (password-unlocked) Developer panel and
/// gated server-side by the dev-view allowlist, so normal users can never read
/// other people's feedback.
class AdminFeedbackScreen extends StatefulWidget {
  const AdminFeedbackScreen({super.key, this.api});

  static const path = '/settings/developer/feedback';

  final ApiClient? api;

  @override
  State<AdminFeedbackScreen> createState() => _AdminFeedbackScreenState();
}

class _AdminFeedbackScreenState extends State<AdminFeedbackScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  late Future<List<FeedbackRow>> _future = _api.adminListFeedback();

  void _refresh() =>
      setState(() => _future = _api.adminListFeedback());

  Future<void> _setStatus(FeedbackRow row, String status) async {
    try {
      await _api.adminSetFeedbackStatus(row.id, status);
      if (!mounted) return;
      AymaToast.show(context, 'Marked $status.', kind: AymaToastKind.success);
      _refresh();
    } catch (e) {
      if (mounted) {
        AymaToast.show(context, "Couldn't update ($e).",
            kind: AymaToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Feedback'),
        actions: [
          IconButton(
            key: const ValueKey('admin-feedback-refresh'),
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<List<FeedbackRow>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            // Feedback-rows fetch still in flight.
            return const Center(
              child: AymaWingLoader(lines: AymaLoaderLines.adminFeedback),
            );
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  "Couldn't load feedback (${snap.error}).",
                  style: AymaType.sans(size: 13, color: ac.errorText),
                ),
              ),
            );
          }
          final rows = snap.data ?? const [];
          if (rows.isEmpty) {
            return Center(
              child: Text(
                'No feedback yet.',
                key: const ValueKey('admin-feedback-empty'),
                style: AymaType.sans(size: 14, soft: true, color: ac.fgMute),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, i) => _FeedbackCardTile(
              row: rows[i],
              api: _api,
              onStatus: (s) => _setStatus(rows[i], s),
            ),
          );
        },
      ),
    );
  }
}

class _FeedbackCardTile extends StatelessWidget {
  const _FeedbackCardTile({
    required this.row,
    required this.api,
    required this.onStatus,
  });

  final FeedbackRow row;
  final ApiClient api;
  final ValueChanged<String> onStatus;

  bool get _isBug => row.kind == 'bug';

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _pill(
                ac,
                _isBug ? 'Bug' : 'Feature',
                _isBug ? ac.warning : ac.accent,
              ),
              _pill(ac, row.source, ac.fgMute),
              _pill(ac, row.status, ac.secondary),
            ],
          ),
          const SizedBox(height: 8),
          if (row.title.isNotEmpty)
            Text(
              row.title,
              style: AymaType.sans(size: 15, color: ac.fg)
                  .copyWith(fontWeight: FontWeight.w600),
            ),
          if (row.title.isNotEmpty) const SizedBox(height: 4),
          Text(
            row.body,
            style: AymaType.sans(size: 14, color: ac.fgDim, height: 1.4),
          ),
          if (row.screenshotPaths.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in row.screenshotPaths)
                  _Thumb(path: p, api: api),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(
            _meta(),
            style: AymaType.sans(size: 11, soft: true, color: ac.fgMute),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              style: SegmentedButton.styleFrom(minimumSize: const Size(0, 44)),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'new', label: Text('New')),
                ButtonSegment(value: 'triaged', label: Text('Triaged')),
                ButtonSegment(value: 'done', label: Text('Done')),
              ],
              selected: {
                if (const {'new', 'triaged', 'done'}.contains(row.status))
                  row.status
                else
                  'new',
              },
              onSelectionChanged: (s) => onStatus(s.first),
            ),
          ),
        ],
      ),
    );
  }

  String _meta() {
    final parts = <String>[
      if (row.screen.isNotEmpty) 'on ${row.screen}',
      if (row.platform.isNotEmpty) row.platform,
      if (row.appVersion.isNotEmpty) 'v${row.appVersion}',
      if (row.uid.isNotEmpty) 'uid ${row.uid}',
      if (row.createdAt != null) '${row.createdAt!.toLocal()}',
    ];
    return parts.join('  ·  ');
  }

  Widget _pill(AymaTokens ac, String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          style: AymaType.sans(size: 11, color: ac.fgDim)
              .copyWith(fontWeight: FontWeight.w600),
        ),
      );
}

/// A feedback screenshot thumbnail. Resolves the Storage path to a viewable
/// URL through the dev-gated endpoint, then shows it; tap opens it full-screen.
class _Thumb extends StatefulWidget {
  const _Thumb({required this.path, required this.api});

  final String path;
  final ApiClient api;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  late final Future<String> _url =
      widget.api.adminFeedbackMediaUrl(widget.path);

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return FutureBuilder<String>(
      future: _url,
      builder: (context, snap) {
        final url = snap.data ?? '';
        final placeholder = Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: ac.bgCard,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.image_outlined, size: 20, color: ac.fgMute),
        );
        if (url.isEmpty) return placeholder;
        return GestureDetector(
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => Dialog(
              child: InteractiveViewer(
                child: AymaPhoto(url: url, error: placeholder),
              ),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 64,
              height: 64,
              child: AymaPhoto(
                url: url,
                displayWidth: 64,
                error: placeholder,
              ),
            ),
          ),
        );
      },
    );
  }
}
