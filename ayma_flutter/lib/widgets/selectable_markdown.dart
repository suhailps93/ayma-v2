import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// A section body rendered rich **and** selectable, where every selection maps
/// back to an exact character range in the raw markdown.
///
/// Supports the slice of markdown the Your Story sections actually use:
/// paragraphs, `#`/`##`/`###` headings, `-`/`*` bullets, `**bold**`,
/// `*italic*` / `_italic_`, `[text](url)`, and `{{private}} … {{/private}}`
/// spans (rendered dimmed with a lock, and omitted entirely when [publicView]
/// is true). Images are not expected inside a section body and render as
/// plain text.
///
/// [onSelect] fires with the raw-body offsets of the current selection plus its
/// plain text — the editor turns that into make-private / make-public / delete
/// / chat actions without any fragile substring matching.
class SelectableMarkdown extends StatefulWidget {
  const SelectableMarkdown({
    super.key,
    required this.raw,
    required this.style,
    this.linkColor,
    this.publicView = false,
    this.onSelect,
  });

  final String raw;
  final TextStyle style;
  final Color? linkColor;

  /// Render as the public profile would: private spans removed.
  final bool publicView;

  /// `(rawStart, rawEnd, plainText)` for the live selection; `(0, 0, '')` when
  /// nothing is selected.
  final void Function(int rawStart, int rawEnd, String plainText)? onSelect;

  @override
  State<SelectableMarkdown> createState() => _SelectableMarkdownState();
}

class _SelectableMarkdownState extends State<SelectableMarkdown> {
  late _Parsed _p = _parse(widget.raw, widget.publicView);

  @override
  void didUpdateWidget(SelectableMarkdown old) {
    super.didUpdateWidget(old);
    if (old.raw != widget.raw || old.publicView != widget.publicView) {
      _p = _parse(widget.raw, widget.publicView);
    }
  }

  void _onSel(TextSelection sel, SelectionChangedCause? _) {
    final cb = widget.onSelect;
    if (cb == null) return;
    if (!sel.isValid || sel.isCollapsed) {
      cb(0, 0, '');
      return;
    }
    final a = _p.plainToRaw(sel.start);
    final b = _p.plainToRaw(sel.end);
    final lo = a < b ? a : b;
    final hi = a < b ? b : a;
    cb(lo, hi, widget.raw.substring(lo.clamp(0, widget.raw.length),
        hi.clamp(0, widget.raw.length)));
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.linkColor ?? const Color(0xFF3A7BD5);
    final dim = widget.style.color?.withValues(alpha: 0.55) ??
        Colors.grey;
    return SelectableText.rich(
      TextSpan(
        style: widget.style,
        children: [
          for (final seg in _p.segs)
            if (seg.plain.isNotEmpty)
              TextSpan(
                text: seg.plain,
                style: _styleFor(seg, link, dim),
                recognizer: seg.link == null
                    ? null
                    : (TapGestureRecognizer()
                      ..onTap = () => launchUrl(Uri.parse(seg.link!),
                          mode: LaunchMode.externalApplication)),
              ),
        ],
      ),
      onSelectionChanged: _onSel,
      // The editor shows its own passage toolbar (Private / Public / Delete /
      // Ayma) — suppress the OS "Copy · Share · Ask …" menu on top of it.
      contextMenuBuilder: (context, editableTextState) =>
          const SizedBox.shrink(),
    );
  }

  TextStyle _styleFor(_Seg s, Color link, Color dim) {
    var st = widget.style;
    if (s.heading > 0) {
      // # / ## / ### -> progressively smaller step-ups off the body size, all
      // bold. Matches AymaType's serif headline sizing without needing the
      // caller to hand in a whole heading TextTheme.
      final bump = switch (s.heading) { 1 => 8, 2 => 5, _ => 2 };
      st = st.copyWith(
        fontWeight: FontWeight.w700,
        fontSize: (st.fontSize ?? 16) + bump,
      );
    }
    if (s.bold) st = st.copyWith(fontWeight: FontWeight.w700);
    if (s.italic) st = st.copyWith(fontStyle: FontStyle.italic);
    if (s.link != null) {
      st = st.copyWith(
          color: link, decoration: TextDecoration.underline);
    }
    if (s.private) {
      st = st.copyWith(
        color: dim,
        decoration: TextDecoration.underline,
        decorationStyle: TextDecorationStyle.dotted,
      );
    }
    return st;
  }
}

/// Set the raw-offset range `[rawA, rawB)` of [raw] (offsets into the raw body,
/// markers included) to private / not, then re-serialise with clean,
/// well-balanced `{{private}} … {{/private}}` spans. `[rawA, rawB) == [0, 0)`
/// with `private == false` just normalises the markers (used after a delete).
String setPrivacy(String raw, int rawA, int rawB, bool private) {
  final chars = <String>[];
  final priv = <bool>[];
  final rawToChar = List<int>.filled(raw.length + 1, 0);
  var depth = 0;
  var i = 0;
  while (i < raw.length) {
    if (raw.startsWith(_privOpen, i)) {
      for (var j = 0; j < _privOpen.length; j++) {
        rawToChar[i + j] = chars.length;
      }
      depth++;
      i += _privOpen.length;
      continue;
    }
    if (raw.startsWith(_privClose, i)) {
      for (var j = 0; j < _privClose.length; j++) {
        rawToChar[i + j] = chars.length;
      }
      depth = depth > 0 ? depth - 1 : 0;
      i += _privClose.length;
      continue;
    }
    rawToChar[i] = chars.length;
    chars.add(raw[i]);
    priv.add(depth > 0);
    i++;
  }
  rawToChar[raw.length] = chars.length;

  final ca = rawToChar[rawA.clamp(0, raw.length)];
  final cb = rawToChar[rawB.clamp(0, raw.length)];
  for (var k = ca; k < cb; k++) {
    priv[k] = private;
  }

  final out = StringBuffer();
  var open = false;
  for (var k = 0; k < chars.length; k++) {
    if (priv[k] && !open) {
      out.write(_privOpen);
      open = true;
    } else if (!priv[k] && open) {
      out.write(_privClose);
      open = false;
    }
    out.write(chars[k]);
  }
  if (open) out.write(_privClose);
  return out.toString();
}

// --- parser --------------------------------------------------------------

class _Seg {
  _Seg(this.plain, this.rawStart, this.rawEnd,
      {this.bold = false,
      this.italic = false,
      this.link,
      this.private = false,
      this.heading = 0});

  /// Verbatim slice of the raw body — `plain.length == rawEnd - rawStart` for
  /// content segs. Synthetic segs (the lock glyph, a bullet dot, a consumed
  /// `#`/`-` marker) use `rawStart == rawEnd` so they contribute nothing to
  /// the mapping.
  final String plain;
  final int rawStart;
  final int rawEnd;
  final bool bold;
  final bool italic;
  final String? link;
  final bool private;

  /// 1 for `#`, 2 for `##`, 3+ for `###` and deeper; 0 = not a heading.
  final int heading;

  bool get synthetic => rawStart == rawEnd;
}

class _Parsed {
  _Parsed(this.segs);
  final List<_Seg> segs;

  /// Plain-text offset -> raw-body offset.
  int plainToRaw(int p) {
    var acc = 0;
    for (final s in segs) {
      final len = s.plain.length;
      if (p <= acc + len) {
        if (s.synthetic) return s.rawStart;
        return s.rawStart + (p - acc);
      }
      acc += len;
    }
    return segs.isEmpty ? 0 : segs.last.rawEnd;
  }
}

final _inline = RegExp(
  r'(\*\*([^*]+)\*\*)'
  r'|(__([^_]+)__)'
  r'|(\*([^*\n]+)\*)'
  r'|(?<![A-Za-z0-9])_([^_\n]+)_(?![A-Za-z0-9])'
  r'|(\[([^\]]+)\]\((https?:\/\/[^\s)]+)\))',
);
final _privOpen = '{{private}}';
final _privClose = '{{/private}}';

final _heading = RegExp(r'^(#{1,6})[ \t]+');
final _bullet = RegExp(r'^[-*][ \t]+');

_Parsed _parse(String raw, bool publicView) {
  final segs = <_Seg>[];

  // Walk the raw string, tracking whether we're inside a {{private}} span.
  var i = 0;
  var priv = false;
  while (i < raw.length) {
    if (raw.startsWith(_privOpen, i)) {
      priv = true;
      i += _privOpen.length;
      if (!publicView) {
        segs.add(_Seg('\u{1F512} ', i, i, private: true)); // lock glyph
      }
      continue;
    }
    if (raw.startsWith(_privClose, i)) {
      priv = false;
      i += _privClose.length;
      continue;
    }
    // Next marker or end.
    var next = raw.length;
    final o = raw.indexOf(_privOpen, i);
    final c = raw.indexOf(_privClose, i);
    if (o >= 0 && o < next) next = o;
    if (c >= 0 && c < next) next = c;

    final chunk = raw.substring(i, next);
    if (!(publicView && priv)) {
      _emitLines(segs, chunk, i, priv);
    }
    i = next;
  }
  return _Parsed(segs);
}

/// Split a private-marker-free chunk into lines and emit each one, so a line
/// starting with `#`/`##`/`###` or `-`/`*` gets heading/bullet treatment
/// instead of showing its raw marker as plain text. [base] is the chunk's
/// offset in the raw body.
void _emitLines(List<_Seg> segs, String chunk, int base, bool priv) {
  var lineStart = 0;
  while (lineStart <= chunk.length) {
    var lineEnd = chunk.indexOf('\n', lineStart);
    final hasNewline = lineEnd != -1;
    if (!hasNewline) lineEnd = chunk.length;
    final line = chunk.substring(lineStart, lineEnd);

    var contentStart = 0;
    var heading = 0;
    final hMatch = _heading.firstMatch(line);
    final bMatch = _bullet.firstMatch(line);
    if (hMatch != null) {
      heading = hMatch.group(1)!.length;
      contentStart = hMatch.end;
    } else if (bMatch != null) {
      // Zero-width bullet glyph in place of the raw "- "/"* " marker.
      segs.add(_Seg('•  ', base + lineStart, base + lineStart,
          private: priv));
      contentStart = bMatch.end;
    }
    _emitInline(segs, line.substring(contentStart), base + lineStart + contentStart,
        priv, heading);

    if (!hasNewline) break;
    segs.add(_Seg('\n', base + lineEnd, base + lineEnd + 1, private: priv));
    lineStart = lineEnd + 1;
  }
}

/// Emit segs for one line's content (no private markers, marker prefix
/// already stripped), resolving inline emphasis / links. [base] is this
/// slice's offset in the raw body; [heading] carries the line's heading level
/// (0 = none) onto every seg it produces.
void _emitInline(
    List<_Seg> segs, String chunk, int base, bool priv, int heading) {
  var pos = 0;
  for (final m in _inline.allMatches(chunk)) {
    if (m.start > pos) {
      final t = chunk.substring(pos, m.start);
      segs.add(_Seg(t, base + pos, base + pos + t.length,
          private: priv, heading: heading));
    }
    if (m.group(1) != null) {
      // **bold** — content group 2, raw content offset = m.start + 2
      segs.add(_Seg(m.group(2)!, base + m.start + 2,
          base + m.start + 2 + m.group(2)!.length,
          bold: true, private: priv, heading: heading));
    } else if (m.group(3) != null) {
      segs.add(_Seg(m.group(4)!, base + m.start + 2,
          base + m.start + 2 + m.group(4)!.length,
          bold: true, private: priv, heading: heading));
    } else if (m.group(5) != null) {
      segs.add(_Seg(m.group(6)!, base + m.start + 1,
          base + m.start + 1 + m.group(6)!.length,
          italic: true, private: priv, heading: heading));
    } else if (m.group(7) != null) {
      segs.add(_Seg(m.group(7)!, base + m.start + 1,
          base + m.start + 1 + m.group(7)!.length,
          italic: true, private: priv, heading: heading));
    } else if (m.group(8) != null) {
      // [text](url) — text group 9, its raw offset = m.start + 1
      segs.add(_Seg(m.group(9)!, base + m.start + 1,
          base + m.start + 1 + m.group(9)!.length,
          link: m.group(10), private: priv, heading: heading));
    }
    pos = m.end;
  }
  if (pos < chunk.length) {
    final t = chunk.substring(pos);
    segs.add(_Seg(t, base + pos, base + pos + t.length,
        private: priv, heading: heading));
  }
}
