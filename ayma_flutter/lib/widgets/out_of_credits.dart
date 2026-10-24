import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/trial_paywall_screen.dart';
import '../theme.dart';

/// Shared "you're out of credits" affordances. Every credit-metered action that
/// can come back capped (match scoring, recalculating a report, a report re-run)
/// should route the user straight to the plans screen rather than leave them at
/// a dead-end message. `PlansScreen` is where credits are bought.
///
/// The in-chat capped line has its own Upgrade button — see `chat_screen.dart`.

const String _kDefaultMessage = "You're out of credits.";

/// Ayma's own first-person phrasing of the same state, for turns where she's
/// "saying" it (a resolved chat turn, a voice-session error) rather than the
/// app narrating a system banner. One constant so every capped surface —
/// chat's skills-triggered jobs, voice — reads identically instead of each
/// call site hand-rolling its own wording.
const String kAymaOutOfCreditsMessage =
    "I'm out of credits — tap Upgrade.";

/// Open credits above any modal chat that raised the capped state: the Pro
/// free-trial paywall for an eligible unsubscribed user (at most once a day per
/// device), else the plans screen.
void openCredits(BuildContext context) {
  final router = GoRouter.of(context);
  // A photo/story/floating chat may be a modal above the routed screens.
  // Dismiss that modal so it cannot cover the destination after navigation.
  if (ModalRoute.of(context) is PopupRoute) Navigator.of(context).pop();
  unawaited(openTrialPaywallOrPlans(router));
}

/// The shared out-of-credits popup: says what still works for free and offers
/// [openCredits] (trial paywall or plans). Every capped surface opens this.
Future<void> showOutOfCreditsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.ac.bgElev,
    showDragHandle: true,
    builder: (sheetContext) => _OutOfCreditsSheet(
      onUpgrade: () {
        Navigator.of(sheetContext).pop();
        if (context.mounted) openCredits(context);
      },
      onDismiss: () => Navigator.of(sheetContext).pop(),
    ),
  );
}

class _OutOfCreditsSheet extends StatelessWidget {
  const _OutOfCreditsSheet({required this.onUpgrade, required this.onDismiss});

  final VoidCallback onUpgrade;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "You're out of credits",
              style: AymaType.sans(
                size: 20,
                weight: FontWeight.w600,
                color: ac.fg,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'You can still use Ayma without her: browse and find other '
              'users, and chat with them — messages, matches and explore are '
              'all still free.',
              style: AymaType.sans(size: 14, color: ac.fgDim),
            ),
            const SizedBox(height: 8),
            Text(
              'Ayma herself — voice and chat with her, reports and match '
              'scoring — needs credits.',
              style: AymaType.sans(size: 14, color: ac.fgDim),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: onUpgrade,
                child: const Text('Upgrade'),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: onDismiss,
                child: const Text('Keep exploring'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A compact inline card — "You're out of credits" plus a **Upgrade** button —
/// for a screen where a banner reads better than a snack (e.g. a report body
/// left staring at stale content after a failed recalc). [onReload] defaults to
/// opening [showOutOfCreditsSheet].
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
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              textStyle: AymaType.sans(size: 13, weight: FontWeight.w600),
            ),
            onPressed: onReload ?? () => showOutOfCreditsSheet(context),
            child: const Text('Upgrade'),
          ),
        ],
      ),
    );
  }
}
