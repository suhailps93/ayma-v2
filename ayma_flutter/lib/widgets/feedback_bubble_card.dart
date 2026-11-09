import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/api_client.dart';
import '../services/feedback_bubble.dart';
import '../theme.dart';
import 'ayma_toast.dart';
import 'ayma_wing_loader.dart';

/// The in-chat feedback bubble (founder spec, 2026-11-06).
///
/// Rendered inside the chat stream when the user asks to "capture
/// feedback" or when Ayma's handling frustrated them (see
/// `feedback_bubble.dart` for the triggers and caps). Unlike the drafted
/// `FeedbackDraftCard` — which confirms text Ayma already summarised —
/// this bubble ASKS: an always-editable text field, kind chips, Submit
/// and Dismiss (whatever the user says in conversation while the bubble
/// is up is also mirrored into the field via [fillText]/[fillRevision]).
///
/// Nothing is filed until Submit, and then only through the existing
/// product-feedback path: `POST /feedback/submit`, `source: 'chat_card'`
/// — the same collection and admin view as every other feedback row.
/// Dismiss writes nothing.
class FeedbackBubbleCard extends StatefulWidget {
  const FeedbackBubbleCard({
    super.key,
    required this.trigger,
    this.initialText = '',
    this.fillText = '',
    this.fillRevision = 0,
    this.screen = 'chat',
    this.api,
    this.screenshotFile,
    this.screenshotPath,
    this.screenshotFailed = false,
    this.appVersionOverride,
    this.platformOverride,
    this.onDismiss,
    this.onSent,
    this.initiallySent = false,
  });

  final FeedbackBubbleTrigger trigger;

  /// Feedback the user already stated with the trigger phrase.
  final String initialText;

  /// Conversational fill (spec: "just tell Ayma"): when [fillRevision]
  /// changes, [fillText] replaces/appends into the field so the user
  /// sees their spoken/typed words in the card before confirming.
  final String fillText;
  final int fillRevision;

  final String screen;
  final ApiClient? api;

  /// The auto-captured screenshot of the app as it looked when the
  /// bubble opened (founder addendum, 2026-11-06): [screenshotFile] is
  /// the local capture shown as a thumbnail; [screenshotPath] is its
  /// already-uploaded Storage path under `uploads/{uid}/`, filed via
  /// the existing `screenshot_paths` support on submit. The user can
  /// remove it before submitting. Both null + [screenshotFailed] means
  /// the capture was attempted and failed — the card says so and the
  /// submission still works without it.
  final File? screenshotFile;
  final String? screenshotPath;
  final bool screenshotFailed;

  final String? appVersionOverride;
  final String? platformOverride;
  final VoidCallback? onDismiss;
  final VoidCallback? onSent;

  /// True when this bubble was already submitted in this session: a
  /// recreated card restores the sent view instead of a fresh,
  /// submittable form. The restored sent view still auto-dismisses
  /// after the same brief linger as a fresh submit.
  final bool initiallySent;

  @override
  State<FeedbackBubbleCard> createState() => _FeedbackBubbleCardState();
}

class _FeedbackBubbleCardState extends State<FeedbackBubbleCard> {
  late final ApiClient _api = widget.api ?? ApiClient();
  late final TextEditingController _body =
      TextEditingController(text: widget.initialText);
  String _kind = 'feature';
  File? _shotFile;
  String? _shotPath;

  @override
  void initState() {
    super.initState();
    _shotFile = widget.screenshotFile;
    _shotPath = widget.screenshotPath;
    if (_sent) _startSentExpiry();
  }
  bool _sending = false;
  late bool _sent = widget.initiallySent;
  bool _dismissed = false;

  /// The sent confirmation is transient: it lingers briefly (the same
  /// 3 seconds the success toast shows), then the card dismisses
  /// itself, so the thanks never sits at the end of the thread for
  /// the rest of the session.
  Timer? _sentExpiry;

  void _startSentExpiry() {
    _sentExpiry?.cancel();
    _sentExpiry = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _dismissed = true);
      widget.onDismiss?.call();
    });
  }

  @override
  void didUpdateWidget(covariant FeedbackBubbleCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The capture finishes asynchronously after the card mounts.
    if (widget.screenshotPath != oldWidget.screenshotPath ||
        widget.screenshotFile != oldWidget.screenshotFile) {
      _shotFile = widget.screenshotFile;
      _shotPath = widget.screenshotPath;
    }
    if (widget.fillRevision != oldWidget.fillRevision &&
        widget.fillText.trim().isNotEmpty) {
      final incoming = widget.fillText.trim();
      final current = _body.text.trim();
      if (current.isEmpty) {
        _body.text = incoming;
      } else if (!current.contains(incoming)) {
        _body.text = '$current $incoming';
      }
      _body.selection =
          TextSelection.collapsed(offset: _body.text.length);
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _sentExpiry?.cancel();
    _body.dispose();
    super.dispose();
  }

  String get _prompt => widget.trigger == FeedbackBubbleTrigger.frustration
      ? 'Sounds like I missed the mark — want to tell us what went wrong?'
      : 'What feedback would you like to share?';

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

  Future<void> _submit() async {
    if (_sending || _sent) return;
    final body = _body.text.trim();
    if (body.isEmpty) {
      AymaToast.show(context, 'Tell us a little first — or Dismiss.',
          kind: AymaToastKind.warning);
      return;
    }
    setState(() => _sending = true);
    try {
      final title =
          body.length > 80 ? '${body.substring(0, 80).trim()}…' : body;
      await _api.submitFeedbackCard(
        kind: _kind,
        title: title,
        body: body,
        screenshotPaths: _shotPath != null ? [_shotPath!] : const [],
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
      _startSentExpiry();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      AymaToast.show(context, "Couldn't send that ($e).",
          kind: AymaToastKind.error);
    }
  }

  void _dismiss() {
    setState(() => _dismissed = true);
    widget.onDismiss?.call();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    if (_dismissed) return const SizedBox.shrink();
    if (_sent) {
      return Container(
        key: const ValueKey('feedback-bubble-sent'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: ac.bgElev,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: ac.lineSoft, width: 0.5),
        ),
        child: Row(
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
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.feedback_outlined, size: 16, color: ac.accent),
              const SizedBox(width: 8),
              Text(
                'Feedback',
                style: AymaType.sans(size: 12, color: ac.accent)
                    .copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _prompt,
            style: AymaType.sans(size: 14, color: ac.fg, height: 1.35),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'feature', label: Text('Feature')),
              ButtonSegment(value: 'bug', label: Text('Bug')),
            ],
            selected: {_kind},
            onSelectionChanged:
                _sending ? null : (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('feedback-bubble-field'),
            controller: _body,
            minLines: 2,
            maxLines: 6,
            maxLength: 4000,
            decoration: const InputDecoration(
              labelText: 'Your feedback',
              counterText: '',
            ),
          ),
          if (_shotFile != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(_shotFile!,
                      key: const ValueKey('feedback-bubble-shot'),
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Screenshot of the app attached',
                    style:
                        AymaType.sans(size: 12, soft: true, color: ac.fgMute),
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('feedback-bubble-remove-shot'),
                  onPressed: _sending
                      ? null
                      : () => setState(() {
                            _shotFile = null;
                            _shotPath = null;
                          }),
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('Remove'),
                ),
              ],
            ),
          ] else if (widget.screenshotFailed) ...[
            const SizedBox(height: 12),
            Text(
              key: const ValueKey('feedback-bubble-shot-failed'),
              "Screenshot couldn't be captured — you can still submit.",
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton(
                key: const ValueKey('feedback-bubble-submit'),
                onPressed: _sending ? null : _submit,
                child: _sending
                    ? const AymaWingLoader(size: 16, showLabel: false)
                    : const Text('Submit'),
              ),
              TextButton(
                key: const ValueKey('feedback-bubble-dismiss'),
                onPressed: _sending ? null : _dismiss,
                child: const Text('Dismiss'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'You can also just tell Ayma — your words land here for review.',
            style: AymaType.sans(size: 11, soft: true, color: ac.fgMute),
          ),
        ],
      ),
    );
  }
}
