import 'package:flutter/material.dart';

import '../theme.dart';

/// AppBar action for a report's re-run / recalculate: the refresh icon, which
/// becomes a small spinner and is disabled while [busy].
class ReportRefreshButton extends StatelessWidget {
  const ReportRefreshButton({
    super.key,
    required this.tooltip,
    required this.busyTooltip,
    required this.busy,
    required this.onPressed,
  });

  final String tooltip;
  final String busyTooltip;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: busy ? busyTooltip : tooltip,
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh),
    );
  }
}

/// Thin in-body strip shown above a report while it is being re-generated.
class ReportProgressBanner extends StatelessWidget {
  const ReportProgressBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      width: double.infinity,
      color: ac.accentFaint,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: ac.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AymaType.sans(size: 12.5, color: ac.accent),
            ),
          ),
        ],
      ),
    );
  }
}

/// Same strip, for a re-generation that didn't finish: the message plus a
/// "Try again" button instead of a spinner.
class ReportFailedBanner extends StatelessWidget {
  const ReportFailedBanner({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      width: double.infinity,
      color: ac.accentFaint,
      padding: const EdgeInsets.only(left: 16, right: 4),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: ac.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AymaType.sans(size: 12.5, color: ac.error),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}
