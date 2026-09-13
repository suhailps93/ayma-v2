import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// A section body rendered rich **and** selectable, where every selection maps
/// back to an exact character range in the raw markdown.
///
/// Supports the slice of markdown the Your Story sections actually use:
/// paragraphs, `#`/`##`/`###` headings, `-`/`*` bullets, `**bold**`,
/// `*italic*` / `_italic_`, `[text](url)`, and `{{private}} … {{/private}}`
/// spans (recoloured to [privateColor], no icon or underline — visibility is
/// communicated by colour alone, same as a whole section's colour — and
/// omitted entirely when [publicView] is true). Images are not expected
/// inside a section body and render as plain text.
///
/// [onSelect] fires with the raw-body offsets of the current selection plus its
/// plain text — the editor turns that into make-private / make-public / delete
/// / chat actions without any fragile substring matching.
///
/// [onSentenceTap] is the same shape as [onSelect], fired instead by a plain
/// **tap** (no drag) landing on a sentence — a faster, more discoverable way
/// to reach the same toolbar for the common one-sentence case. It fires with
/// that sentence's exact raw-body offsets, same as a drag-selection over the
/// identical span would. It never fires for a tap that lands on a link (the
/// link still opens) or when it is left null (read-only content).
class SelectableMarkdown extends StatefulWidget {
  const SelectableMarkdown({
    super.key,
    required this.raw,
    required this.style,
    this.linkColor,
    this.privateColor,
    this.publicView = false,
    this.onSelect,
    this.onSentenceTap,
  });

  final String raw;
  final TextStyle style;
  final Color? linkColor;

  /// Colour for `{{private}}` spans. Falls back to a dimmed [style] colour if
  /// not given — pass the same "private" grey the section's own badge uses
  /// so an inline private aside always reads the same way a private section
  /// does.
  final Color? privateColor;

  /// Render as the public profile would: private spans removed.
  final bool publicView;

  /// `(rawStart, rawEnd, plainText)` for the live selection; `(0, 0, '')` when
  /// nothing is selected.
  final void Function(int rawStart, int rawEnd, String plainText)? onSelect;

  /// `(rawStart, rawEnd, plainText)` for a single tapped sentence. See the
  /// class doc above.
  final void Function(int rawStart, int rawEnd, String plainText)?
      onSentenceTap;

  @override
  State<SelectableMarkdown> createState() => _SelectableMarkdownState();
}

class _SelectableMarkdownState extends State<SelectableMarkdown> {
  late _Parsed _p = _parse(widget.raw, widget.publicView);

  // A brief highlight flash over the tapped sentence's raw range, so a tap
  // shows exactly what got picked up (sentence boundaries are a heuristic —
  // this confirms the guess landed where the reader expected) before fading.
  // Self-contained and time-based: it never needs to track the editor's own
  // toolbar-visible state, so it can't go stale relative to it.
  int _flashStart = 0;
  int _flashEnd = 0;
  Timer? _flashTimer;

  @override
  void didUpdateWidget(SelectableMarkdown old) {
    super.didUpdateWidget(old);
    if (old.raw != widget.raw || old.publicView != widget.publicView) {
      _p = _parse(widget.raw, widget.publicView);
    }
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    super.dispose();
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

  void _onSentenceTap(int rawStart, int rawEnd) {
    final cb = widget.onSentenceTap;
    if (cb == null) return;
    _flashTimer?.cancel();
    setState(() {
      _flashStart = rawStart;
      _flashEnd = rawEnd;
    });
    _flashTimer = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() {
        _flashStart = 0;
        _flashEnd = 0;
      });
    });
    cb(rawStart, rawEnd, widget.raw.substring(
        rawStart.clamp(0, widget.raw.length),
        rawEnd.clamp(0, widget.raw.length)));
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.linkColor ?? const Color(0xFF3A7BD5);
    final dim = widget.privateColor ??
        widget.style.color?.withValues(alpha: 0.55) ??
        Colors.grey;
    // Same colour the platform already uses for a drag-selection highlight —
    // borrowing that precedent rather than inventing a new one, so the tap
    // flash reads as "this got selected", not as a new kind of decoration.
    final flash = Theme.of(context).textSelectionTheme.selectionColor ??
        const Color(0x663A7BD5);
    return SelectableText.rich(
      TextSpan(
        style: widget.style,
        children: [
          for (final seg in _p.segs)
            if (seg.plain.isNotEmpty)
              TextSpan(
                text: seg.plain,
                style: _styleFor(seg, link, dim, flash),
                recognizer: seg.link != null
                    ? (TapGestureRecognizer()
                      ..onTap = () => launchUrl(Uri.parse(seg.link!),
                          mode: LaunchMode.externalApplication))
                    // Sentence-tap is the fallback for plain text runs only —
                    // it never overrides a link's own recognizer above, and
                    // it's absent entirely when there's no sentence here
                    // (synthetic bullet/newline segs) or the caller passed no
                    // onSentenceTap (read-only content).
                    : (widget.onSentenceTap == null ||
                            seg.sentenceEnd <= seg.sentenceStart)
                        ? null
                        : (TapGestureRecognizer()
                          ..onTap = () =>
                              _onSentenceTap(seg.sentenceStart, seg.sentenceEnd)),
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

  TextStyle _styleFor(_Seg s, Color link, Color dim, Color flash) {
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
      // Colour alone carries the privacy meaning (matches the section-level
      // legend) — no glyph, no underline.
      st = st.copyWith(color: dim);
    }
    if (_flashEnd > _flashStart &&
        s.sentenceEnd > s.sentenceStart &&
        s.rawStart < _flashEnd &&
        s.rawEnd > _flashStart) {
      st = st.copyWith(backgroundColor: flash);
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
      this.heading = 0,
      int? sentenceStart,
      int? sentenceEnd})
      : sentenceStart = sentenceStart ?? rawStart,
        sentenceEnd = sentenceEnd ?? rawStart;

  /// Verbatim slice of the raw body — `plain.length == rawEnd - rawStart` for
  /// content segs. Synthetic segs (a bullet dot, a consumed `#`/`-` marker)
  /// use `rawStart == rawEnd` so they contribute nothing to the mapping.
  final String plain;
  final int rawStart;
  final int rawEnd;
  final bool bold;
  final bool italic;
  final String? link;
  final bool private;

  /// 1 for `#`, 2 for `##`, 3+ for `###` and deeper; 0 = not a heading.
  final int heading;

  /// Raw-body range `[sentenceStart, sentenceEnd)` of the whole sentence this
  /// seg is one styled piece of — several segs (plain run, bold run, link…)
  /// share the same pair so a tap on any of them selects the whole sentence.
  /// Defaults to an empty range (`sentenceStart == sentenceEnd`) for segs
  /// that emit outside `_emitInline` (a bullet dot, a line-break) — those
  /// never get a sentence-tap recognizer.
  final int sentenceStart;
  final int sentenceEnd;

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
    final content = line.substring(contentStart);
    _emitInline(segs, content, base + lineStart + contentStart, priv, heading,
        _sentenceRanges(content));

    if (!hasNewline) break;
    segs.add(_Seg('\n', base + lineEnd, base + lineEnd + 1, private: priv));
    lineStart = lineEnd + 1;
  }
}

/// Emit segs for one line's content (no private markers, marker prefix
/// already stripped), resolving inline emphasis / links. [base] is this
/// slice's offset in the raw body; [heading] carries the line's heading level
/// (0 = none) onto every seg it produces. [sentences] are [chunk]-local
/// sentence ranges from [_sentenceRanges] — every seg produced gets tagged
/// with the raw-offset span of whichever sentence contains it, so segs from
/// the same sentence (a plain run, a bold run, a link…) all carry the same
/// `sentenceStart`/`sentenceEnd` and a tap on any of them selects the whole
/// sentence. A plain-text run between/around emphasis matches is itself split
/// at any sentence boundary it crosses (see [_emitPlain]) — otherwise a
/// two-sentence paragraph with no inline formatting at all would render as
/// one seg and a tap anywhere in it would always resolve to the first
/// sentence.
void _emitInline(List<_Seg> segs, String chunk, int base, bool priv,
    int heading, List<(int, int)> sentences) {
  var pos = 0;
  for (final m in _inline.allMatches(chunk)) {
    if (m.start > pos) {
      _emitPlain(segs, chunk, pos, m.start, base, priv, heading, sentences);
    }
    final sr = _sentenceAt(sentences, m.start);
    final sentStart = base + sr.$1;
    final sentEnd = base + sr.$2;
    if (m.group(1) != null) {
      // **bold** — content group 2, raw content offset = m.start + 2
      segs.add(_Seg(m.group(2)!, base + m.start + 2,
          base + m.start + 2 + m.group(2)!.length,
          bold: true,
          private: priv,
          heading: heading,
          sentenceStart: sentStart,
          sentenceEnd: sentEnd));
    } else if (m.group(3) != null) {
      segs.add(_Seg(m.group(4)!, base + m.start + 2,
          base + m.start + 2 + m.group(4)!.length,
          bold: true,
          private: priv,
          heading: heading,
          sentenceStart: sentStart,
          sentenceEnd: sentEnd));
    } else if (m.group(5) != null) {
      segs.add(_Seg(m.group(6)!, base + m.start + 1,
          base + m.start + 1 + m.group(6)!.length,
          italic: true,
          private: priv,
          heading: heading,
          sentenceStart: sentStart,
          sentenceEnd: sentEnd));
    } else if (m.group(7) != null) {
      segs.add(_Seg(m.group(7)!, base + m.start + 1,
          base + m.start + 1 + m.group(7)!.length,
          italic: true,
          private: priv,
          heading: heading,
          sentenceStart: sentStart,
          sentenceEnd: sentEnd));
    } else if (m.group(8) != null) {
      // [text](url) — text group 9, its raw offset = m.start + 1
      segs.add(_Seg(m.group(9)!, base + m.start + 1,
          base + m.start + 1 + m.group(9)!.length,
          link: m.group(10),
          private: priv,
          heading: heading,
          sentenceStart: sentStart,
          sentenceEnd: sentEnd));
    }
    pos = m.end;
  }
  if (pos < chunk.length) {
    _emitPlain(segs, chunk, pos, chunk.length, base, priv, heading, sentences);
  }
}

/// Emit one _Seg per sentence covering the plain-text (no inline emphasis)
/// slice `[localStart, localEnd)` of [chunk] — split further at any sentence
/// boundary inside that slice, so a merged multi-sentence plain run (no bold
/// /italic/link anywhere in it) still yields one seg per sentence instead of
/// one seg for the whole run. Each seg's own `rawStart`/`rawEnd` is just its
/// own slice, but its `sentenceStart`/`sentenceEnd` is the *whole* sentence it
/// belongs to (which may extend into neighbouring segs from other emphasis
/// runs) — that shared pair is what lets a tap on any of them select the
/// whole sentence.
void _emitPlain(List<_Seg> segs, String chunk, int localStart, int localEnd,
    int base, bool priv, int heading, List<(int, int)> sentences) {
  var p = localStart;
  while (p < localEnd) {
    final sr = _sentenceAt(sentences, p);
    final segLocalEnd = sr.$2 < localEnd ? sr.$2 : localEnd;
    final t = chunk.substring(p, segLocalEnd);
    segs.add(_Seg(t, base + p, base + segLocalEnd,
        private: priv,
        heading: heading,
        sentenceStart: base + sr.$1,
        sentenceEnd: base + sr.$2));
    p = segLocalEnd;
  }
}

/// The [sentences] range (from [_sentenceRanges]) containing local offset
/// [localOffset], or the last range if [localOffset] runs past the end
/// (shouldn't happen given the ranges partition the whole chunk, but falls
/// back safely) — `(localOffset, localOffset)` for an empty [sentences].
(int, int) _sentenceAt(List<(int, int)> sentences, int localOffset) {
  for (final r in sentences) {
    if (localOffset < r.$2) return r;
  }
  return sentences.isEmpty ? (localOffset, localOffset) : sentences.last;
}

// --- sentence-boundary detection -----------------------------------------

/// Common abbreviations whose trailing `.` never ends a sentence, lower-cased
/// and with internal periods kept (so e.g. `ph.d` is matched as one token).
/// Not exhaustive — a simple heuristic, good enough for this app's own
/// third-person wiki prose, not a linguistically complete sentence splitter.
const _abbreviations = {
  'dr', 'mr', 'mrs', 'ms', 'jr', 'sr', 'st', 'prof', 'rev', 'gen', 'sgt',
  'capt', 'vs', 'etc', 'approx', 'inc', 'ltd', 'co', 'no', 'fig', 'ave',
  'blvd', 'dept', 'univ', 'corp', 'vol', 'ph.d', 'mt', 'ft', 'hon', 'esq',
};

/// Initials / acronym pattern: "U", "U.S", "J.K", "N.Y" — a run of single
/// letters each followed by a period, ending on a bare letter. Catches the
/// common case of an abbreviation the fixed list above won't (any run of
/// initials) without needing to enumerate every one.
final _initials = RegExp(r'^[A-Za-z](\.[A-Za-z])*$');

bool _isAbbreviation(String chunk, int periodIdx) {
  var start = periodIdx;
  while (start > 0 && chunk[start - 1] != ' ' && chunk[start - 1] != '\t') {
    start--;
  }
  final word = chunk.substring(start, periodIdx);
  if (word.isEmpty) return false;
  if (_initials.hasMatch(word)) return true;
  return _abbreviations.contains(word.toLowerCase());
}

/// Split [chunk] (one line's raw content, markdown markers and all) into
/// sentence ranges `[start, end)` that partition it completely — every
/// character of [chunk] belongs to exactly one range. A sentence ends at a
/// `.`/`!`/`?` immediately followed by whitespace or the end of [chunk],
/// unless the word right before it is a known abbreviation or looks like a
/// run of initials (see [_isAbbreviation]) — e.g. "Dr. Smith" and "U.S. tour"
/// don't split there. Trailing whitespace after the punctuation is folded
/// into the sentence that ends there, so the next range starts right at its
/// first real character.
///
/// Known limitations (acceptable for this heuristic): a period followed by a
/// closing quote or parenthesis before the whitespace ("Sentence one." "Two.")
/// isn't recognised as a boundary; an abbreviation not in the fixed list and
/// not initials-shaped may cause a false split; an ellipsis's final `.` may
/// be read as a sentence end if followed by whitespace.
List<(int, int)> _sentenceRanges(String chunk) {
  if (chunk.isEmpty) return const [];
  final ranges = <(int, int)>[];
  var start = 0;
  final len = chunk.length;
  for (var i = 0; i < len; i++) {
    final c = chunk[i];
    if (c != '.' && c != '!' && c != '?') continue;
    final next = i + 1 < len ? chunk[i + 1] : null;
    final atBreak = next == null || next == ' ' || next == '\t';
    if (!atBreak) continue;
    if (c == '.' && _isAbbreviation(chunk, i)) continue;
    var end = i + 1;
    while (end < len && (chunk[end] == ' ' || chunk[end] == '\t')) {
      end++;
    }
    ranges.add((start, end));
    start = end;
  }
  if (start < len) ranges.add((start, len));
  return ranges;
}
