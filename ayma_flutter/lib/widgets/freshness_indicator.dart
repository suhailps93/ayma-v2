import 'package:flutter/material.dart';

import '../services/fresh_data.dart';
import '../theme.dart';

/// Minimal strip that surfaces non-[FreshnessState.live] data.
///
/// Live renders nothing. Syncing / Stale / Refused show a one-line caption
/// under the screen header so cache-only or failed data is never mistaken
/// for a working live session (PERF_PLAN Phase 1).
class FreshnessIndicator extends StatelessWidget {
  const FreshnessIndicator({
    super.key,
    required this.state,
    this.onRetry,
  });

  /// Convenience: derive from a [FreshData] wrapper.
  factory FreshnessIndicator.fromFresh(
    FreshData<dynamic> fresh, {
    Key? key,
    VoidCallback? onRetry,
  }) =>
      FreshnessIndicator(key: key, state: fresh.state, onRetry: onRetry);

  final FreshnessState state;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (state == FreshnessState.live) return const SizedBox.shrink();

    final ac = context.ac;
    final (label, color, icon, showSpinner) = switch (state) {
      FreshnessState.syncing => (
          'Updating…',
          ac.fgMute,
          Icons.cloud_sync_outlined,
          true,
        ),
      FreshnessState.stale => (
          'Offline — showing saved data',
          ac.fgMute,
          Icons.cloud_off_outlined,
          false,
        ),
      FreshnessState.refused => (
          "Couldn't refresh",
          ac.error,
          Icons.error_outline,
          false,
        ),
      FreshnessState.live => (
          '',
          ac.fgMute,
          Icons.cloud_done_outlined,
          false,
        ),
    };

    return Semantics(
      liveRegion: true,
      label: label,
      child: Material(
        color: state == FreshnessState.refused ? ac.accentFaint : ac.bgElev,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              if (showSpinner)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: color,
                  ),
                )
              else
                Icon(icon, size: 14, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: AymaType.sans(size: 12, color: color),
                ),
              ),
              if (state == FreshnessState.refused && onRetry != null)
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    foregroundColor: ac.error,
                  ),
                  child: const Text('Retry'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
