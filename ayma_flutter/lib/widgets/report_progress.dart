import 'package:flutter/material.dart';

import '../theme.dart';
import 'ayma_wing_loader.dart';

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
      // The caller's re-run in flight — icon slot, wings only.
      icon: busy
          ? const AymaWingLoader(size: 18, showLabel: false)
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          const AymaWingLoader(size: 14, showLabel: false),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: AymaType.sans(size: 12.5, color: ac.fgDim),
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
      padding: const EdgeInsets.only(left: 20, right: 12),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: ac.error),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: AymaType.sans(size: 12.5, color: ac.fgDim),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
            ),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}
