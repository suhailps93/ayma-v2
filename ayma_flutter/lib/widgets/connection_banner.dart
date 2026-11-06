import 'package:flutter/material.dart';

import '../services/connection_heartbeat.dart';
import '../services/fresh_data.dart';
import '../theme.dart';
import 'freshness_indicator.dart';

/// App-shell connection banner: every page carries it.
///
/// Mounted once in `MaterialApp.router`'s builder (above the routed pages),
/// it renders the familiar offline strip when [ConnectionHeartbeat] reports
/// [ConnectionQuality.offline], an identically-treated weak strip for
/// [ConnectionQuality.weak], and nothing at all when ok — in which case
/// [child] passes through untouched, so healthy sessions see zero layout
/// change.
///
/// The offline strip reuses [FreshnessIndicator]'s stale presentation
/// verbatim (same words, same strip); the weak strip is the same treatment
/// with an honest label. The per-screen `FreshnessIndicator`s are a separate
/// data-freshness signal and are left exactly as they are.
///
/// This widget also owns the heartbeat's app lifetime: it starts the
/// heartbeat on mount, pauses it while backgrounded, and probes immediately
/// on resume.
class ConnectionBanner extends StatefulWidget {
  const ConnectionBanner({
    super.key,
    required this.child,
    this.heartbeat,
  });

  final Widget child;

  /// Overridable for tests; defaults to the app-wide singleton.
  final ConnectionHeartbeat? heartbeat;

  @override
  State<ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends State<ConnectionBanner>
    with WidgetsBindingObserver {
  ConnectionHeartbeat get _heartbeat =>
      widget.heartbeat ?? ConnectionHeartbeat.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _heartbeat.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeat.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _heartbeat.setForeground(true);
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _heartbeat.setForeground(false);
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ConnectionQuality>(
      valueListenable: _heartbeat.listenable,
      builder: (context, quality, _) {
        if (quality == ConnectionQuality.ok) return widget.child;
        return Column(
          children: [
            if (quality == ConnectionQuality.offline)
              const _OfflineStrip()
            else
              const _WeakStrip(),
            Expanded(
              // The strip above already consumed the status-bar inset
              // (its own SafeArea, top: true). Remove that inset from
              // the MediaQuery the child subtree inherits, so each
              // page's own SafeArea does not apply the same inset a
              // second time -- the double-count was the dead band of
              // empty space under the banner on every page (founder
              // report, Nov 5 2026).
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: widget.child,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The offline strip, below the status bar so it never underlaps it.
class _OfflineStrip extends StatelessWidget {
  const _OfflineStrip();

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      top: true,
      bottom: false,
      left: false,
      right: false,
      // The stale strip IS the offline banner (same words, same style).
      child: FreshnessIndicator(state: FreshnessState.stale),
    );
  }
}

/// The weak strip: same treatment as the offline one, honest label.
class _WeakStrip extends StatelessWidget {
  const _WeakStrip();

  static const _label = 'Weak connection — showing saved data';

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Semantics(
      liveRegion: true,
      label: _label,
      child: SafeArea(
        top: true,
        bottom: false,
        left: false,
        right: false,
        child: Material(
          color: ac.bgElev,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Icon(
                  Icons.signal_cellular_alt_1_bar,
                  size: 14,
                  color: ac.fgMute,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _label,
                    style: AymaType.sans(size: 12, color: ac.fgMute),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
