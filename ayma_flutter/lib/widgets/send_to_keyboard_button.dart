import 'package:flutter/material.dart';

import '../services/keyboard_draft_store.dart';
import 'ayma_toast.dart';

/// "Send to Ayma Keyboard" — stores [text] as the current keyboard draft
/// so the user can switch to any other app, switch to the Ayma Keyboard,
/// and insert it with one tap.
///
/// This is the V1 entry point required by the spec: whenever Ayma (or the
/// user, in the composer) has a drafted message/reply, this action makes
/// it the keyboard draft. It never sends anything anywhere else.
class SendToKeyboardButton extends StatefulWidget {
  const SendToKeyboardButton({
    super.key,
    required this.text,
    this.service,
    this.label = 'Send to Ayma Keyboard',
    this.source = 'ayma_chat',
  });

  /// The drafted text, or a getter evaluated at tap time (composer text).
  final Object text;
  final KeyboardDraftService? service;
  final String label;
  final String? source;

  String get resolvedText =>
      text is String Function() ? (text as String Function())() : '$text';

  @override
  State<SendToKeyboardButton> createState() => _SendToKeyboardButtonState();
}

class _SendToKeyboardButtonState extends State<SendToKeyboardButton> {
  bool _busy = false;

  Future<void> _send() async {
    final text = widget.resolvedText.trim();
    if (text.isEmpty || _busy) return;
    final toast = AymaToast.of(context);
    setState(() => _busy = true);
    final ok = await (widget.service ?? keyboardDraftService)
        .setDraft(text, source: widget.source);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      toast.show(
        'Saved to Ayma Keyboard. Switch apps, switch keyboards, tap Insert.',
        kind: AymaToastKind.success,
      );
    } else {
      toast.show(
        'Could not save that to the keyboard.',
        kind: AymaToastKind.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      key: const ValueKey('send-to-ayma-keyboard'),
      onPressed: _busy ? null : _send,
      icon: const Icon(Icons.keyboard_outlined, size: 18),
      label: Text(widget.label),
    );
  }
}
