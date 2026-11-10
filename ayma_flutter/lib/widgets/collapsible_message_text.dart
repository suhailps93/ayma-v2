import 'package:flutter/material.dart';

import '../theme.dart';
import 'markdown_text.dart';

/// Renders an Ayma chat message, collapsing over-long ones to a short
/// preview with a "Show full message" expander.
///
/// Why this exists (ANR storm, NOTE 144/145, Nov 7 2026): a self-check run
/// used to post its whole 5,728-char raw report as one turn reply, and
/// that bubble stays the thread tail in history. Laying it out through
/// [MarkdownText] costs ~1.6 s on first build (measured in a widget test
/// against the real NOTE 144 report) and ~130 ms on every rebuild — and
/// the chat list rebuilds its visible rows on every store update
/// (new message, snapshot burst, scroll-to-bottom). On the return path
/// from Chrome, and on every cold start that lands on the tail, those
/// rebuilds stack into multi-second frames and the app ANRs. Capping
/// what is laid out by default bounds every bubble's layout cost; the
/// full text is one tap away and long-press copy still copies it all.
class CollapsibleMessageText extends StatefulWidget {
  const CollapsibleMessageText(
    this.text, {
    super.key,
    required this.style,
    this.linkColor,
  });

  final String text;
  final TextStyle style;
  final Color? linkColor;

  /// Messages at or under this length render in full — the same cap the
  /// server uses for a single chat bubble (MAX_BUBBLE_CHARS).
  static const int collapseThresholdChars = 1500;

  /// How much of an over-long message the collapsed preview shows.
  static const int previewChars = 1200;

  /// The collapsed preview: [text] cut at the last line break at or
  /// before [previewChars] (else the last space, else a hard cut), so
  /// the preview never ends mid-word when a boundary is available.
  static String previewOf(String text) {
    if (text.length <= collapseThresholdChars) return text;
    var cut = previewChars;
    final newline = text.lastIndexOf('\n', previewChars);
    if (newline > previewChars ~/ 2) {
      cut = newline;
    } else {
      final space = text.lastIndexOf(' ', previewChars);
      if (space > previewChars ~/ 2) cut = space;
    }
    return '${text.substring(0, cut).trimRight()}…';
  }

  @override
  State<CollapsibleMessageText> createState() =>
      _CollapsibleMessageTextState();
}

class _CollapsibleMessageTextState extends State<CollapsibleMessageText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final collapsible =
        widget.text.length > CollapsibleMessageText.collapseThresholdChars;
    if (!collapsible) {
      return MarkdownText(
        widget.text,
        style: widget.style,
        linkColor: widget.linkColor,
      );
    }
    final shown = _expanded
        ? widget.text
        : CollapsibleMessageText.previewOf(widget.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MarkdownText(
          shown,
          style: widget.style,
          linkColor: widget.linkColor,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _expanded = !_expanded),
            style: TextButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            ),
            child: Text(
              _expanded
                  ? 'Show less'
                  : 'Show full message (${widget.text.length} characters)',
              style: AymaType.sans(
                size: 13,
                color: ac.accentText,
                weight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
