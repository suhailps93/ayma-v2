import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/usage_screen.dart';
import '../theme.dart';

/// Shared "you're out of credits" affordances. Every credit-metered action that
/// can come back capped (match scoring, recalculating a report, a report re-run)
/// should route the user straight to the reload screen rather than leave them at
/// a dead-end message. `UsageScreen` (`/profile/usage`) has the real
/// "Reload credits" button.
///
/// The in-chat capped line has its own reload button — see `chat_screen.dart`.

const String _kDefaultMessage =
    "You're out of credits — tap Reload to top up.";

/// A SnackBar that says the user is out of credits, with a one-tap **Reload**
/// action that opens [UsageScreen]. Clears any existing snackbars first so the
/// CTA is never buried.
void showOutOfCreditsSnack(BuildContext context, {String? message}) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(message ?? _kDefaultMessage),
      action: SnackBarAction(
        label: 'Reload',
        onPressed: () => context.push(UsageScreen.path),
      ),
    ));
}

/// A compact inline card — "You're out of credits" plus a **Reload** button —
/// for a screen where a banner reads better than a snack (e.g. a report body
/// left staring at stale content after a failed recalc). [onReload] defaults to
/// pushing [UsageScreen].
class OutOfCreditsBanner extends StatelessWidget {
  const OutOfCreditsBanner({super.key, this.onReload, this.message});

  final VoidCallback? onReload;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Row(
        children: [
          Icon(Icons.toll_rounded, size: 18, color: ac.fgMute),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message ?? _kDefaultMessage,
              style: AymaType.sans(size: 13, color: ac.fgDim),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: onReload ?? () => context.push(UsageScreen.path),
            child: const Text('Reload'),
          ),
        ],
      ),
    );
  }
}
