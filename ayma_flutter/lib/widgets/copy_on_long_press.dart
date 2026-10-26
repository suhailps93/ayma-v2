import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ayma_toast.dart';

/// Press-and-hold copies [text] to the clipboard (light haptic + a short
/// "Copied" toast). Does nothing when [text] is blank. Only a long-press
/// is claimed, so taps on [child] (image viewer, report cards) are untouched.
class CopyOnLongPress extends StatelessWidget {
  const CopyOnLongPress({super.key, required this.text, required this.child});

  final String text;
  final Widget child;

  Future<void> _copy(BuildContext context) async {
    final toast = AymaToast.of(context);
    HapticFeedback.lightImpact();
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {
      toast.show("Couldn't copy that.", kind: AymaToastKind.error);
      return;
    }
    toast.show('Copied', kind: AymaToastKind.success);
  }

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return child;
    return GestureDetector(onLongPress: () => _copy(context), child: child);
  }
}
