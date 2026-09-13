import 'package:flutter/material.dart';

import '../theme.dart';

/// A compact floating toolbar anchored near a selected sentence in Your
/// Story: Make public · Make private · Ask Ayma. Positioned via a raw
/// pointer-down anchor point (see `StoryEditorScreen`'s `Listener` wrapper
/// around each section's body) rather than hard-coded coordinates — it
/// appears above the anchor when there's room, below otherwise, and stays
/// clamped inside the screen.
///
/// Meant to be the `overlayChild` of an [OverlayPortal] whose `child` is the
/// whole document — the portal's overlay renders full-screen, so this widget
/// paints a full-screen transparent "tap outside to dismiss" barrier behind
/// the toolbar itself.
class StoryToolbar extends StatelessWidget {
  const StoryToolbar({
    super.key,
    required this.anchor,
    required this.isPrivate,
    required this.busy,
    required this.onMakePublic,
    required this.onMakePrivate,
    required this.onAsk,
    required this.onDismiss,
  });

  /// Global position of the tap/selection that opened this toolbar.
  final Offset anchor;

  /// Whether the selected text is currently private (checks "Make private")
  /// or public (checks "Make public").
  final bool isPrivate;

  final bool busy;
  final VoidCallback onMakePublic;
  final VoidCallback onMakePrivate;
  final VoidCallback onAsk;

  /// Tap-outside-to-dismiss.
  final VoidCallback onDismiss;

  static const double _width = 246;
  static const double _height = 60;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final topSafe = media.padding.top + 8;
    final bottomSafe = media.padding.bottom + 8;

    double left = (anchor.dx - _width / 2).clamp(12.0, screen.width - _width - 12.0);
    // Prefer above the anchor; flip below when there isn't room.
    final above = anchor.dy - 14 - _height;
    final top = above >= topSafe
        ? above
        : (anchor.dy + 22).clamp(topSafe, screen.height - _height - bottomSafe);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTransparency.opaque,
            onTap: onDismiss,
          ),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          left: left,
          top: top,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 170),
            curve: Curves.easeOut,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.scale(
                scale: 0.94 + 0.06 * t,
                alignment: Alignment.center,
                child: child,
              ),
            ),
            child: _ToolbarCard(
              isPrivate: isPrivate,
              busy: busy,
              onMakePublic: onMakePublic,
              onMakePrivate: onMakePrivate,
              onAsk: onAsk,
            ),
          ),
        ),
      ],
    );
  }
}

/// Alias so the barrier's hit-test behaviour reads clearly at the call site
/// above without importing `HitTestBehavior` under a confusing local name.
typedef HitTransparency = HitTestBehavior;

class _ToolbarCard extends StatelessWidget {
  const _ToolbarCard({
    required this.isPrivate,
    required this.busy,
    required this.onMakePublic,
    required this.onMakePrivate,
    required this.onAsk,
  });

  final bool isPrivate;
  final bool busy;
  final VoidCallback onMakePublic;
  final VoidCallback onMakePrivate;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Material(
      color: ac.bgElev,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: StoryToolbar._width,
        height: StoryToolbar._height,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: ac.lineSoft, width: 0.5),
        ),
        child: Row(
          children: [
            _Item(
              icon: Icons.public,
              label: 'Make public',
              checked: !isPrivate,
              onTap: busy ? null : onMakePublic,
            ),
            _divider(ac),
            _Item(
              icon: Icons.lock_outline,
              label: 'Make private',
              checked: isPrivate,
              onTap: busy ? null : onMakePrivate,
            ),
            _divider(ac),
            _Item(
              icon: Icons.auto_awesome,
              label: 'Ask Ayma',
              checked: false,
              onTap: busy ? null : onAsk,
              accent: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _divider(AymaTokens ac) => Container(
        width: 0.5,
        height: 28,
        color: ac.lineSoft,
      );
}

class _Item extends StatelessWidget {
  const _Item({
    required this.icon,
    required this.label,
    required this.checked,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final bool checked;
  final VoidCallback? onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final color = accent ? ac.accent : (checked ? ac.fg : ac.fgDim);
    return Expanded(
      child: Semantics(
        button: true,
        label: label,
        selected: checked,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: StoryToolbar._height,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AymaType.sans(size: 10, color: color),
                ),
                if (checked) ...[
                  const SizedBox(height: 2),
                  Container(
                    width: 4,
                    height: 4,
                    decoration:
                        BoxDecoration(color: ac.accent, shape: BoxShape.circle),
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
