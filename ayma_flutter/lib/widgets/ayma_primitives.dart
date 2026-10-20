import 'package:flutter/material.dart';

import '../theme.dart';

/// Re-exported so screens can name orb states without a second import.
export 'ayma_orb.dart' show AymaOrbState;

/// Small shared building blocks from the Ayma design language (§14.1):
/// the mono micro-label, the labelled hairline divider, the tiny gradient
/// "mini orb" that marks Ayma's voice, and the screen header (eyebrow + serif
/// display title + optional trailing action) that opens every tab.

/// All-caps letter-spaced mono micro-label — the recurring section marker.
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: AymaType.mono(size: 10, color: color ?? context.ac.fgMute)
          .copyWith(letterSpacing: 2),
    );
  }
}

/// A centred [Eyebrow] flanked by hairlines — heads a block of content.
class DividerLabel extends StatelessWidget {
  const DividerLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final line = Expanded(
      child: Divider(color: context.ac.line, thickness: 0.5),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          line,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Eyebrow(text),
          ),
          line,
        ],
      ),
    );
  }
}

/// The 14px gradient dot that stands in for Ayma wherever her voice appears in
/// otherwise-static content (notes, tips, feedback prompts).
class MiniOrb extends StatelessWidget {
  const MiniOrb({super.key, this.size = 14});

  final double size;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.3, -0.4),
          radius: 0.9,
          colors: [
            Color.lerp(ac.accent, Colors.white, 0.55)!,
            ac.accent,
            Color.lerp(ac.accent, Colors.black, 0.45)!,
          ],
          stops: const [0, 0.5, 1],
        ),
        boxShadow: [
          BoxShadow(color: ac.accentSoft, blurRadius: size * 0.45),
        ],
      ),
    );
  }
}

/// The header every tab opens with: a large serif display [title], an
/// optional [subtitle], and an optional trailing [action] rendered as a
/// ghost circle. Replaces the default [AppBar] on the main tabs. An optional
/// mono [eyebrow] can still be set above the title, but no call site uses it
/// any more — the founder had the small uppercase labels above every main
/// screen's title removed app-wide.
class AymaScreenHeader extends StatelessWidget {
  const AymaScreenHeader({
    super.key,
    this.eyebrow,
    required this.title,
    this.subtitle,
    this.action,
    this.titleSize = 36,
    this.padding = const EdgeInsets.fromLTRB(20, 12, 12, 12),
    this.automaticallyImplyBack = false,
    this.leading,
  });

  /// Mono label above [title]. Omit to render just the title (no gap left
  /// behind — the title sits flush with the top padding).
  final String? eyebrow;
  final String title;
  final String? subtitle;
  final Widget? action;
  final double titleSize;
  final EdgeInsets padding;

  /// When true, a standard [BackButton] leads the title whenever the
  /// enclosing route can actually pop. For screens that serve double duty as
  /// a shell tab AND a standalone pushed route (Messages, Explore, You —
  /// pushed by deep links / Ayma's `open_screen`): as a tab the shell route
  /// can't pop, so nothing renders and the header is unchanged; pushed, the
  /// back arrow appears — iPhones have no system back button/gesture-bar, so
  /// every pushed screen needs a visible way back (founder issue).
  final bool automaticallyImplyBack;

  /// Explicit leading control (overrides the implied [BackButton]).
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final showBack = leading != null ||
        (automaticallyImplyBack && (ModalRoute.of(context)?.canPop ?? false));
    return Padding(
      padding: showBack
          // The BackButton supplies its own ~16px of visual inset; pull the
          // horizontal padding back so the arrow aligns with the content
          // edge instead of floating toward the middle.
          ? padding.copyWith(left: (padding.left - 12).clamp(0, padding.left))
          : padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showBack)
            Padding(
              // Optically center the arrow against the serif title's cap
              // height (titles here are 34–36px tall).
              padding: const EdgeInsets.only(top: 2),
              child: leading ?? BackButton(color: ac.fg),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (eyebrow != null) ...[
                  Eyebrow(eyebrow!),
                  const SizedBox(height: 10),
                ],
                Text(title, style: AymaType.serif(size: titleSize, color: ac.fg)),
                if (subtitle != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    subtitle!,
                    style: AymaType.sans(
                        size: 13, color: ac.fgDim, height: 1.5),
                  ),
                ],
              ],
            ),
          ),
          if (action != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 8),
              child: action,
            ),
        ],
      ),
    );
  }
}

/// A compact credit chip — a coin glyph and a number — for token-intensive
/// buttons ("Calculate match · ⊚ 12") and the profile balance row.
class CreditPill extends StatelessWidget {
  const CreditPill({
    super.key,
    required this.amount,
    this.prefix = '',
    this.color,
    this.dim = false,
  });

  final int amount;

  /// Optional leading glyphless text, e.g. '~' for an estimate.
  final String prefix;
  final Color? color;

  /// Render muted (disabled button, insufficient balance).
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final c = color ?? (dim ? ac.fgMute : ac.accent);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.toll_rounded, size: 13, color: c),
        const SizedBox(width: 4),
        Text('$prefix$amount',
            style: AymaType.mono(size: 11, color: c).copyWith(letterSpacing: 0.5)),
      ],
    );
  }
}

/// A 38px circular ghost button — the design's standard trailing affordance in
/// a screen header (notifications, settings, overflow).
class GhostCircleButton extends StatelessWidget {
  const GhostCircleButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.badgeChild,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  /// When set, replaces the bare icon (e.g. a [Badge]-wrapped icon).
  final Widget? badgeChild;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Material(
      color: ac.bgElev,
      shape: CircleBorder(side: BorderSide(color: ac.lineSoft, width: 0.5)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Tooltip(
          message: tooltip ?? '',
          child: SizedBox(
            width: 38,
            height: 38,
            child: badgeChild ??
                Icon(icon, size: 17, color: ac.fgDim),
          ),
        ),
      ),
    );
  }
}
