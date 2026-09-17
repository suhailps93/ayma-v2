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

const String _kDefaultMessage = "You're out of credits — tap Reload to top up.";

/// Ayma's own first-person phrasing of the same state, for turns where she's
/// "saying" it (a resolved chat turn, a voice-session error) rather than the
/// app narrating a system banner. One constant so every capped surface —
/// chat's skills-triggered jobs, voice — reads identically instead of each
/// call site hand-rolling its own wording.
const String kAymaOutOfCreditsMessage =
    "I'm out of credits — tap Reload to top up.";

/// Open credits above any modal chat that raised the capped state.
void openCredits(BuildContext context) {
  final router = GoRouter.of(context);
  // A photo/story/floating chat may be a modal above the routed screens.
  // Dismiss that modal so it cannot cover the destination after navigation.
  if (ModalRoute.of(context) is PopupRoute) Navigator.of(context).pop();
  router.push(UsageScreen.path);
}

/// Show the shared capped message and its Reload action.
void showOutOfCreditsSnack(BuildContext context, {String? message}) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message ?? _kDefaultMessage),
        action: SnackBarAction(
          label: 'Reload',
          onPressed: () => openCredits(context),
        ),
      ),
    );
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
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: onReload ?? () => openCredits(context),
            child: const Text('Reload'),
          ),
        ],
      ),
    );
  }
}
