import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/api_client.dart';
import '../services/chat_service.dart';
import '../theme.dart';
import 'ayma_toast.dart';
import 'ayma_wing_loader.dart';

/// The in-chat feedback catcher's confirmation card (F5 / founder request),
/// modelled on Claude Duet's "Send this feature request?" card.
///
/// Ayma drafts it (the `submit_feedback` tool) when the user asks for a feature
/// or reports something broken. It shows a kind chip (Feature request / Bug), a
/// title, an editable body, [Send] / [Edit] / [Not now], and an "Add
/// screenshot" affordance. **Nothing is filed until the user taps Send** — only
/// then does it upload any screenshot and `POST /feedback/submit`
/// (`source: 'chat_card'`). Styling matches the chat's other inline cards
/// (`bgElev`, hairline border).
class FeedbackDraftCard extends StatefulWidget {
  const FeedbackDraftCard({
    super.key,
    required this.kind,
    required this.title,
    required this.body,
    this.screen = 'chat',
    this.api,
    this.chatService,
    this.picker,
    this.appVersionOverride,
    this.platformOverride,
    this.onDismiss,
    this.onSent,
    this.resolvedOutcome = '',
  });

  /// `'feature'` or `'bug'`.
  final String kind;
  final String title;
  final String body;

  /// The screen the user was on when Ayma drafted this — stored for triage.
  final String screen;

  final ApiClient? api;
  final ChatService? chatService;
  final ImagePicker? picker;

  /// Test seams — otherwise read from `package_info_plus` / `dart:io`.
  final String? appVersionOverride;
  final String? platformOverride;

  /// "Not now" — the user dismissed the card without sending.
  final VoidCallback? onDismiss;

  /// Called once the feedback has been filed successfully.
  final VoidCallback? onSent;

  /// How a previous instance of this card was resolved: `'sent'` or
  /// `'dismissed'`, restored from the transcript turn. A recreated card
  /// (ListView recycling, turn replacement) seeds its state from this,
  /// so already-filed feedback never reappears as a fresh draft the
  /// user can send a second time.
  final String resolvedOutcome;

  @override
  State<FeedbackDraftCard> createState() => _FeedbackDraftCardState();
}

class _FeedbackDraftCardState extends State<FeedbackDraftCard> {
  late final ApiClient _api = widget.api ?? ApiClient();
  late final ChatService _chat = widget.chatService ?? ChatService();
  late final ImagePicker _picker = widget.picker ?? ImagePicker();

  late String _kind = widget.kind == 'bug' ? 'bug' : 'feature';
  late final TextEditingController _title =
      TextEditingController(text: widget.title);
  late final TextEditingController _body =
      TextEditingController(text: widget.body);

  bool _editing = false;
  bool _sending = false;
  late bool _sent = widget.resolvedOutcome == 'sent';
  late bool _dismissed = widget.resolvedOutcome == 'dismissed';
  File? _shot;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  String get _kindLabel => _kind == 'bug' ? 'Bug' : 'Feature request';

  Future<void> _addShot() async {
    try {
      final p = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (p != null && mounted) setState(() => _shot = File(p.path));
    } catch (_) {
      /* ignore — the user can still send without a screenshot */
    }
  }

  Future<String> _platform() async {
    if (widget.platformOverride != null) return widget.platformOverride!;
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return Platform.operatingSystem;
  }

  Future<String> _appVersion() async {
    if (widget.appVersionOverride != null) return widget.appVersionOverride!;
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '';
    }
  }

  Future<void> _send() async {
    if (_sending || _sent) return;
    final title = _title.text.trim();
    final body = _body.text.trim();
    if (body.isEmpty) {
      AymaToast.show(context, 'Add a little detail first.',
          kind: AymaToastKind.warning);
      return;
    }
    setState(() => _sending = true);
    try {
      final paths = <String>[];
      if (_shot != null) {
        final up = await _chat.uploadImage(_shot!, prefix: 'feedback');
        paths.add(up.storagePath);
      }
      await _api.submitFeedbackCard(
        kind: _kind,
        title: title,
        body: body,
        screenshotPaths: paths,
        screen: widget.screen,
        appVersion: await _appVersion(),
        platform: await _platform(),
        source: 'chat_card',
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sent = true;
      });
      AymaToast.show(context, 'Thanks — sent to the team.',
          kind: AymaToastKind.success);
      widget.onSent?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      AymaToast.show(context, "Couldn't send that ($e).",
          kind: AymaToastKind.error);
    }
  }

  void _notNow() {
    setState(() => _dismissed = true);
    widget.onDismiss?.call();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    if (_dismissed) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: _sent ? _sentView(ac) : _draftView(ac),
    );
  }

  Widget _sentView(AymaTokens ac) => Row(
        key: const ValueKey('feedback-sent'),
        children: [
          Icon(Icons.check_circle, size: 18, color: ac.success),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Thanks — sent to the team.',
              style: AymaType.sans(size: 13, color: ac.fgDim),
            ),
          ),
        ],
      );

  Widget _draftView(AymaTokens ac) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Kind chip + a tiny caption that this is a draft.
        Row(
          children: [
            _KindChip(label: _kindLabel, isBug: _kind == 'bug'),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Draft — nothing is sent until you tap Send',
                style: AymaType.sans(size: 11, soft: true, color: ac.fgMute),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_editing) ...[
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'feature', label: Text('Feature')),
              ButtonSegment(value: 'bug', label: Text('Bug')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('feedback-title-field'),
            controller: _title,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'Title',
              counterText: '',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('feedback-body-field'),
            controller: _body,
            minLines: 2,
            maxLines: 6,
            maxLength: 4000,
            decoration: const InputDecoration(labelText: 'Details'),
          ),
        ] else ...[
          if (_title.text.trim().isNotEmpty)
            Text(
              _title.text.trim(),
              style: AymaType.sans(size: 15, color: ac.fg)
                  .copyWith(fontWeight: FontWeight.w600),
            ),
          if (_title.text.trim().isNotEmpty) const SizedBox(height: 4),
          Text(
            _body.text.trim(),
            style: AymaType.sans(size: 14, color: ac.fgDim, height: 1.4),
          ),
        ],
        const SizedBox(height: 12),
        // Screenshot affordance / thumbnail.
        if (_shot != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(_shot!,
                      width: 56, height: 56, fit: BoxFit.cover),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  key: const ValueKey('feedback-remove-shot'),
                  onPressed: () => setState(() => _shot = null),
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('Remove'),
                ),
              ],
            ),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('feedback-add-shot'),
              onPressed: _sending ? null : _addShot,
              icon: const Icon(Icons.add_a_photo_outlined, size: 18),
              label: const Text('Add screenshot'),
            ),
          ),
        // Actions — wrap so they never overflow on a narrow / scaled layout.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton(
              key: const ValueKey('feedback-send'),
              onPressed: _sending ? null : _send,
              // Screenshot upload + feedback submit in flight — wings only.
              child: _sending
                  ? const AymaWingLoader(size: 16, showLabel: false)
                  : const Text('Send'),
            ),
            if (!_editing)
              OutlinedButton(
                key: const ValueKey('feedback-edit'),
                onPressed: _sending
                    ? null
                    : () => setState(() => _editing = true),
                child: const Text('Edit'),
              ),
            TextButton(
              key: const ValueKey('feedback-not-now'),
              onPressed: _sending ? null : _notNow,
              child: const Text('Not now'),
            ),
          ],
        ),
      ],
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({required this.label, required this.isBug});

  final String label;
  final bool isBug;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final bg = isBug ? ac.warning.withValues(alpha: 0.16) : ac.accentFaint;
    final fg = isBug ? ac.warning : ac.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isBug ? Icons.bug_report_outlined : Icons.lightbulb_outline,
              size: 13, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: AymaType.sans(size: 12, color: fg)
                .copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
