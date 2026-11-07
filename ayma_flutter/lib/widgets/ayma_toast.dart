import 'dart:async';

import 'package:flutter/material.dart';

import '../services/screen_capture.dart';
import '../theme.dart';
import 'ayma_tab_bar.dart';

/// What a toast is telling the user. Each kind pairs a tint with its own icon
/// and mono label, so the meaning never rests on colour alone.
enum AymaToastKind { success, info, warning, error }

/// The one optional button on a toast (Undo, Retry, Open, …).
class AymaToastAction {
  const AymaToastAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

/// Ayma's in-app notification: a floating paper card above the bottom nav bar
/// (docs/ARCHITECTURE.md §14.1, "Toasts"). Replaces Material `SnackBar`
/// app-wide.
///
/// One toast at a time: a new [show] replaces whatever is showing. It
/// auto-dismisses ([AymaToast.durationFor]), and a tap or a downward swipe
/// dismisses it early. It never takes focus and only its own card takes
/// pointer events.
///
/// Rendered by the [AymaToastHost] that `main.dart` mounts above the router,
/// so a toast survives the route that raised it (a sheet that pops, a screen
/// that navigates away). Where no host is mounted (a widget test pumping a
/// bare `MaterialApp`), it falls back to the root [Overlay] of the caller's
/// context.
class AymaToast {
  const AymaToast._();

  /// Shows [message] (up to two lines) as a [kind] toast, replacing any toast
  /// already on screen.
  static void show(
    BuildContext context,
    String message, {
    AymaToastKind kind = AymaToastKind.info,
    AymaToastAction? action,
  }) => of(context).show(message, kind: kind, action: action);

  /// A handle that can still raise a toast after an `await` in which
  /// [context] may unmount (the `ScaffoldMessenger.of` capture pattern).
  static AymaToaster of(BuildContext context) => AymaToaster._(
    _AymaToastLayerState._active == null
        ? Overlay.maybeOf(context, rootOverlay: true)
        : null,
  );

  /// Dismisses the toast on screen, if any. Safe to call from `dispose`: the
  /// dismissal runs in a microtask, after the tree is unlocked.
  static void hide() => scheduleMicrotask(() {
    final layer = _AymaToastLayerState._active;
    if (layer != null && layer.mounted) layer._dismiss();
  });

  /// How long a toast stays up: 3 s, 5 s with an action or for an error, 6 s
  /// for an error with an action.
  static Duration durationFor(AymaToastKind kind, {required bool hasAction}) {
    final isError = kind == AymaToastKind.error;
    if (isError && hasAction) return const Duration(seconds: 6);
    if (isError || hasAction) return const Duration(seconds: 5);
    return const Duration(seconds: 3);
  }
}

/// See [AymaToast.of].
class AymaToaster {
  AymaToaster._(this._fallback);

  /// The root [Overlay] to show in when no [AymaToastHost] is mounted.
  final OverlayState? _fallback;

  /// See [AymaToast.show].
  void show(
    String message, {
    AymaToastKind kind = AymaToastKind.info,
    AymaToastAction? action,
  }) {
    final request = _ToastRequest(message: message, kind: kind, action: action);
    final layer = _AymaToastLayerState._active;
    if (layer != null) {
      layer._show(request);
      return;
    }
    final overlay = _fallback;
    if (overlay == null || !overlay.mounted) return;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _AymaToastLayer(
        initial: request,
        onIdle: () {
          if (entry.mounted) entry.remove();
        },
      ),
    );
    overlay.insert(entry);
  }
}

/// Mounts the app-wide toast layer over [child] (`MaterialApp.builder`).
class AymaToastHost extends StatelessWidget {
  const AymaToastHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [child, const _AymaToastLayer()],
    );
  }
}

class _ToastRequest {
  _ToastRequest({required this.message, required this.kind, this.action});

  final String message;
  final AymaToastKind kind;
  final AymaToastAction? action;
}

class _AymaToastLayer extends StatefulWidget {
  const _AymaToastLayer({this.initial, this.onIdle});

  /// Shown as soon as the layer mounts (the [Overlay] fallback).
  final _ToastRequest? initial;

  /// Called once the toast has fully left the screen (the [Overlay]
  /// fallback removes its entry here).
  final VoidCallback? onIdle;

  @override
  State<_AymaToastLayer> createState() => _AymaToastLayerState();
}

class _AymaToastLayerState extends State<_AymaToastLayer>
    with SingleTickerProviderStateMixin {
  /// Every mounted layer, newest last; the newest one shows toasts.
  static final List<_AymaToastLayerState> _mounted = [];
  static _AymaToastLayerState? get _active =>
      _mounted.isEmpty ? null : _mounted.last;

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    reverseDuration: const Duration(milliseconds: 180),
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _anim,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  _ToastRequest? _current;
  Timer? _timer;
  double _drag = 0;

  @override
  void initState() {
    super.initState();
    _mounted.add(this);
    _anim.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) {
        setState(() {
          _current = null;
          _drag = 0;
        });
        widget.onIdle?.call();
      }
    });
    final initial = widget.initial;
    if (initial != null) {
      // Laid out from the first frame; the entrance (which reads
      // MediaQuery for reduced motion) starts once mounted.
      _current = initial;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _show(initial);
      });
    }
  }

  @override
  void dispose() {
    _mounted.remove(this);
    _timer?.cancel();
    _curve.dispose();
    _anim.dispose();
    super.dispose();
  }

  bool get _reduceMotion =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  void _show(_ToastRequest request) {
    _timer?.cancel();
    setState(() {
      _current = request;
      _drag = 0;
    });
    if (_reduceMotion) {
      _anim.value = 1;
    } else {
      _anim.forward();
    }
    _timer = Timer(
      AymaToast.durationFor(request.kind, hasAction: request.action != null),
      _dismiss,
    );
  }

  void _dismiss() {
    _timer?.cancel();
    if (_current == null) return;
    if (_reduceMotion) {
      _anim.value = 0;
    } else {
      _anim.reverse();
    }
  }

  void _onAction() {
    final action = _current?.action;
    _dismiss();
    action?.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final request = _current;
    if (request == null) return const SizedBox.shrink();
    final media = MediaQuery.of(context);
    // Above the bottom nav bar (and its orb), or above the keyboard when
    // that is taller.
    final bottom = [
      media.viewInsets.bottom,
      media.padding.bottom + AymaTabBar.contentHeight,
    ].reduce((a, b) => a > b ? a : b);
    return Positioned(
      left: 16,
      right: 16,
      bottom: bottom + 12,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: FadeTransition(
              opacity: _curve,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, 0.35),
                  end: Offset.zero,
                ).animate(_curve),
                child: Transform.translate(
                  offset: Offset(0, _drag),
                  child: GestureDetector(
                    excludeFromSemantics: true,
                    behavior: HitTestBehavior.opaque,
                    onTap: _dismiss,
                    onVerticalDragUpdate: (d) => setState(
                      () => _drag = (_drag + d.delta.dy).clamp(0, 120),
                    ),
                    onVerticalDragEnd: (d) {
                      if (_drag > 24 || (d.primaryVelocity ?? 0) > 300) {
                        _dismiss();
                      } else {
                        setState(() => _drag = 0);
                      }
                    },
                    child: AymaToastCard(
                      key: const ValueKey('ayma_toast'),
                      message: request.message,
                      kind: request.kind,
                      action: request.action == null
                          ? null
                          : AymaToastAction(
                              label: request.action!.label,
                              onPressed: _onAction,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The toast's card itself (public for widget tests; app code calls
/// [AymaToast.show]).
class AymaToastCard extends StatelessWidget {
  const AymaToastCard({
    super.key,
    required this.message,
    required this.kind,
    this.action,
  });

  final String message;
  final AymaToastKind kind;
  final AymaToastAction? action;

  static ({IconData icon, String label}) _style(AymaToastKind kind) =>
      switch (kind) {
        AymaToastKind.success => (icon: Icons.check_rounded, label: 'Done'),
        AymaToastKind.info => (icon: Icons.auto_awesome_rounded, label: 'Ayma'),
        AymaToastKind.warning => (
          icon: Icons.priority_high_rounded,
          label: 'Heads up',
        ),
        AymaToastKind.error => (
          icon: Icons.error_outline_rounded,
          label: 'Error',
        ),
      };

  /// [kind]'s tint on the toast's surface.
  static Color tint(AymaTokens ac, AymaToastKind kind) => switch (kind) {
    AymaToastKind.success => ac.success,
    AymaToastKind.info => ac.accent,
    AymaToastKind.warning => ac.warning,
    AymaToastKind.error => ac.error,
  };

  /// [color] pulled toward [ink] until it reaches [minRatio] contrast on
  /// [surface], so any accent stays legible on either theme.
  static Color legible(Color color, Color surface, Color ink, double minRatio) {
    var c = color;
    for (var t = 0.1; contrast(c, surface) < minRatio && t <= 1.0; t += 0.1) {
      c = Color.lerp(color, ink, t)!;
    }
    return c;
  }

  /// WCAG contrast ratio of [a] against [b].
  static double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = ac.bgElev;
    final style = _style(kind);
    final tinted = tint(ac, kind);
    final iconColor = legible(tinted, surface, ac.fg, 3);
    final action = this.action;
    return NoAymaAction(
      child: Semantics(
        container: true,
        liveRegion: true,
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            padding: EdgeInsets.fromLTRB(16, 12, action == null ? 16 : 8, 12),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: ac.line, width: 0.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.45 : 0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: tinted.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(style.icon, size: 18, color: iconColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        style.label.toUpperCase(),
                        style: AymaType.mono(size: 9.5, color: ac.fgDim),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AymaType.sans(
                          size: 14,
                          color: ac.fg,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                if (action != null) ...[
                  const SizedBox(width: 8),
                  // Capped so at large text on a narrow phone the label
                  // ellipsizes instead of pushing the row off screen.
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.sizeOf(context).width * 0.35,
                    ),
                    child: TextButton(
                      onPressed: action.onPressed,
                      style: TextButton.styleFrom(
                        foregroundColor:
                            legible(ac.accent, surface, ac.fg, 4.5),
                        minimumSize: const Size(48, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      child: Text(
                        action.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AymaType.mono(size: 11, weight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
