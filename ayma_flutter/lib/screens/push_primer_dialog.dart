import 'package:flutter/material.dart';

import '../services/push_permission.dart';
import '../services/push_service.dart';
import '../theme.dart';

/// Pre-permission explainer shown at the end of onboarding. "Turn on
/// notifications" is the single place onboarding triggers the OS prompt (iOS
/// and Android 13+); "Not now" closes without asking and nothing re-asks
/// automatically — the user can enable it later in notification preferences.
///
/// Skipped when the OS permission is already decided.
Future<void> showPushPrimer(
  BuildContext context, {
  PushPermission? permission,
  Future<void> Function()? onGranted,
}) async {
  final perm = permission ?? PushPermission();
  if (await perm.status() != PushPermissionState.notAsked) return;
  if (!context.mounted) return;
  final turnOn = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: const Text('Stay in the loop'),
      content: Text(
        'Turn on notifications to hear about new messages, matches, and '
        'reminders from Ayma.',
        style: AymaType.sans(size: 14, color: ctx.ac.fg),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Turn on notifications'),
        ),
      ],
    ),
  );
  if (turnOn != true) return;
  if (await perm.request() == PushPermissionState.granted) {
    await (onGranted ?? PushService().syncToken)();
  }
}
