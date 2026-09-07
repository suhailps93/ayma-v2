import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// A small, dependency-free renderer for the slice of Markdown Ayma actually
/// emits in chat: **bold**, *italic* / _italic_, `code`, [links](url), bullet
/// and numbered lists, `#` headings, and blank-line paragraph breaks. Anything
/// it doesn't recognise renders as plain text, so a stray `*` never breaks a
/// reply.
class MarkdownText extends StatelessWidget {
  const MarkdownText(
    this.data, {
    super.key,
    required this.style,
    this.linkColor,
  });

  final String data;
  final TextStyle style;
  final Color? linkColor;

  @override
  Widget build(BuildContext context) {
    final link = linkColor ?? const Color(0xFF3A7BD5);
    final blocks = _blocks(data.trim());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < blocks.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
            child: _block(blocks[i], link),
          ),
      ],
    );
  }

  Widget _block(_Block b, Color link) {
    switch (b.kind) {
      case _Kind.image:
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: Image.network(
              b.lines.first,
              fit: BoxFit.cover,
              width: double.infinity,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              loadingBuilder: (c, w, p) => p == null
                  ? w
                  : const SizedBox(
                      height: 140,
                      child: Center(child: CircularProgressIndicator()),
                    ),
            ),
          ),
        );
      case _Kind.heading:
        return Text.rich(
          _inline(b.lines.first, style, link),
          style: style.copyWith(
            fontWeight: FontWeight.w700,
            fontSize: (style.fontSize ?? 16) + (b.level == 1 ? 3 : 1),
          ),
        );
      case _Kind.list:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final item in b.lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(b.ordered ? '${b.marker(item)} ' : '•  ', style: style),
                    Expanded(
                      child: Text.rich(
                        _inline(b.stripMarker(item), style, link),
                        style: style,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      case _Kind.paragraph:
        return Text.rich(
          _inline(b.lines.join(' '), style, link),
          style: style,
        );
    }
  }
}

enum _Kind { paragraph, list, heading, image }

class _Block {
  _Block(this.kind, this.lines, {this.ordered = false, this.level = 0});

  final _Kind kind;
  final List<String> lines;
  final bool ordered;
  final int level;

  static final _ol = RegExp(r'^\s*(\d+)[.)]\s+');
  static final _ul = RegExp(r'^\s*[-*]\s+');

  String marker(String line) => _ol.firstMatch(line)?.group(1) != null
      ? '${_ol.firstMatch(line)!.group(1)}.'
      : '•';

  String stripMarker(String line) =>
      line.replaceFirst(ordered ? _ol : _ul, '');
}

List<_Block> _blocks(String src) {
  final out = <_Block>[];
  final lines = src.split('\n');
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }
    final image =
        RegExp(r'^!\[[^\]]*\]\((https?:\/\/[^\s)]+)\)\s*$').firstMatch(line);
    if (image != null) {
      out.add(_Block(_Kind.image, [image.group(1)!]));
      i++;
      continue;
    }
    final heading = RegExp(r'^(#{1,3})\s+(.*)').firstMatch(line);
    if (heading != null) {
      out.add(_Block(_Kind.heading, [heading.group(2)!.trim()],
          level: heading.group(1)!.length));
      i++;
      continue;
    }
    final ordered = _Block._ol.hasMatch(line);
    final unordered = _Block._ul.hasMatch(line);
    if (ordered || unordered) {
      final items = <String>[];
      while (i < lines.length &&
          (_Block._ol.hasMatch(lines[i]) || _Block._ul.hasMatch(lines[i]))) {
        items.add(lines[i]);
        i++;
      }
      out.add(_Block(_Kind.list, items, ordered: ordered));
      continue;
    }
    final para = <String>[];
    while (i < lines.length &&
        lines[i].trim().isNotEmpty &&
        !RegExp(r'^(#{1,3})\s+').hasMatch(lines[i]) &&
        !RegExp(r'^!\[[^\]]*\]\(https?:\/\/').hasMatch(lines[i]) &&
        !_Block._ol.hasMatch(lines[i]) &&
        !_Block._ul.hasMatch(lines[i])) {
      para.add(lines[i].trim());
      i++;
    }
    out.add(_Block(_Kind.paragraph, para));
  }
  return out;
}

// **bold**, *italic* / _italic_, `code`, [text](url) — first match wins.
final _token = RegExp(
  r'(\*\*([^*]+)\*\*)'
  r'|(__([^_]+)__)'
  r'|(\*([^*\n]+)\*)'
  r'|(?<![A-Za-z0-9])_([^_\n]+)_(?![A-Za-z0-9])'
  r'|(`([^`]+)`)'
  r'|(\[([^\]]+)\]\((https?:\/\/[^\s)]+)\))',
);

TextSpan _inline(String text, TextStyle base, Color link) {
  final spans = <InlineSpan>[];
  var idx = 0;
  for (final m in _token.allMatches(text)) {
    if (m.start > idx) {
      spans.add(TextSpan(text: text.substring(idx, m.start)));
    }
    if (m.group(2) != null) {
      spans.add(TextSpan(
          text: m.group(2),
          style: const TextStyle(fontWeight: FontWeight.w700)));
    } else if (m.group(4) != null) {
      spans.add(TextSpan(
          text: m.group(4),
          style: const TextStyle(fontWeight: FontWeight.w700)));
    } else if (m.group(6) != null) {
      spans.add(TextSpan(
          text: m.group(6),
          style: const TextStyle(fontStyle: FontStyle.italic)));
    } else if (m.group(7) != null) {
      spans.add(TextSpan(
          text: m.group(7),
          style: const TextStyle(fontStyle: FontStyle.italic)));
    } else if (m.group(9) != null) {
      spans.add(TextSpan(
        text: m.group(9),
        style: TextStyle(
          fontFamily: 'monospace',
          fontFeatures: const [],
          backgroundColor: base.color?.withValues(alpha: 0.08),
        ),
      ));
    } else if (m.group(11) != null) {
      final label = m.group(11)!;
      final url = m.group(12)!;
      spans.add(TextSpan(
        text: label,
        style: TextStyle(color: link, decoration: TextDecoration.underline),
        recognizer: TapGestureRecognizer()
          ..onTap = () {
            launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
          },
      ));
    }
    idx = m.end;
  }
  if (idx < text.length) spans.add(TextSpan(text: text.substring(idx)));
  return TextSpan(style: base, children: spans);
}
