import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Press-and-hold copies [text] to the clipboard (light haptic + a short
/// "Copied" snackbar). Does nothing when [text] is blank. Only a long-press
/// is claimed, so taps on [child] (image viewer, report cards) are untouched.
class CopyOnLongPress extends StatelessWidget {
  const CopyOnLongPress({super.key, required this.text, required this.child});

  final String text;
  final Widget child;

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    HapticFeedback.lightImpact();
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {
      messenger?.showSnackBar(
        const SnackBar(content: Text("Couldn't copy that.")),
      );
      return;
    }
    messenger?.showSnackBar(
      const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return child;
    return GestureDetector(onLongPress: () => _copy(context), child: child);
  }
}
