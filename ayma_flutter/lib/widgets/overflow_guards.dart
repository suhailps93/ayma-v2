import 'package:flutter/widgets.dart';

/// Layout guards that keep a screen from ever rendering the yellow-and-black
/// overflow stripes, whatever the window: split-screen or freeform windows
/// down to ~300px tall, landscape, the Fold's near-square inner display, the
/// keyboard up, text scaled to 200%. Each one lays its content out exactly
/// as before whenever there is room, and scrolls instead of overflowing when
/// there isn't. `test/layout_matrix_test.dart` holds every screen to this.

/// Centers [child] in the space it's given and scrolls it when that space is
/// shorter than the child.
///
/// The app's full-area states (loading errors, empty states) use this in
/// place of `Center(child: Padding(child: Column(...)))`. Safe in an
/// unbounded-height parent too (inside a list): there it simply centers
/// horizontally, as a plain [Center] would.
class CenteredScroll extends StatelessWidget {
  const CenteredScroll({
    super.key,
    this.padding = EdgeInsets.zero,
    required this.child,
  });

  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Center(
        child: constraints.hasBoundedHeight
            ? SingleChildScrollView(padding: padding, child: child)
            : Padding(padding: padding, child: child),
      ),
    );
  }
}

/// [child] at its natural height, but never taller than [maxHeight]: past
/// that it scrolls inside the cap. For the fixed (non-scrolling) parts of a
/// column, so together they can't add up to more than the column.
/// [reverse] keeps the bottom in view (a composer's text field).
class CappedScroll extends StatelessWidget {
  const CappedScroll({
    super.key,
    required this.maxHeight,
    this.reverse = false,
    required this.child,
  });

  final double maxHeight;
  final bool reverse;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight < 0 ? 0 : maxHeight),
      child: SingleChildScrollView(reverse: reverse, child: child),
    );
  }
}

/// The common screen shape `[...header, Expanded(body), ...footer]`: a
/// scrolling [body] between a fixed [header] and [footer] (a close button
/// row, a pinned action bar). The header and footer are each capped at their
/// share of the height ([headerShare], [footerShare]) via [CappedScroll], so
/// in a short window they scroll rather than squeeze the column past its
/// bounds; at normal sizes the caps exceed their content and nothing changes.
class ChromeColumn extends StatelessWidget {
  const ChromeColumn({
    super.key,
    this.header = const [],
    required this.body,
    this.footer = const [],
    this.headerShare = 0.3,
    this.footerShare = 0.5,
    this.crossAxisAlignment = CrossAxisAlignment.center,
  }) : assert(headerShare + footerShare <= 1);

  final List<Widget> header;
  final Widget body;
  final List<Widget> footer;
  final double headerShare;
  final double footerShare;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        Widget part(List<Widget> children, double share) => CappedScroll(
          maxHeight: h * share,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: crossAxisAlignment,
            children: children,
          ),
        );
        return Column(
          crossAxisAlignment: crossAxisAlignment,
          children: [
            if (header.isNotEmpty) part(header, headerShare),
            Expanded(child: body),
            if (footer.isNotEmpty) part(footer, footerShare),
          ],
        );
      },
    );
  }
}
