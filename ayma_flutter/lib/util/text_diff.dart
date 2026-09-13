/// A tiny dependency-free text-diff: an LCS line diff, plus an optional
/// word-level diff for lines that changed. Used by the Your Story editor's
/// `DiffView` to render GitHub-style red/green hunks.
library;

/// What happened to one line between the two texts.
enum DiffKind { equal, insert, delete }

/// One line of a line diff. [oldIndex] / [newIndex] are 0-based positions in
/// the source texts, or -1 when the line does not exist on that side.
class DiffLine {
  const DiffLine(this.kind, this.text, {this.oldIndex = -1, this.newIndex = -1});

  final DiffKind kind;
  final String text;
  final int oldIndex;
  final int newIndex;

  @override
  bool operator ==(Object other) =>
      other is DiffLine &&
      other.kind == kind &&
      other.text == text &&
      other.oldIndex == oldIndex &&
      other.newIndex == newIndex;

  @override
  int get hashCode => Object.hash(kind, text, oldIndex, newIndex);

  @override
  String toString() {
    const g = {DiffKind.equal: ' ', DiffKind.insert: '+', DiffKind.delete: '-'};
    return '${g[kind]} $text';
  }
}

/// One span of a word diff within a changed line.
class DiffSpan {
  const DiffSpan(this.kind, this.text);

  /// Only [DiffKind.equal] and one of insert/delete are used here.
  final DiffKind kind;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is DiffSpan && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => '<${kind.name}:$text>';
}

List<String> _splitLines(String s) {
  if (s.isEmpty) return const [];
  return s.replaceAll('\r\n', '\n').split('\n');
}

/// The classic dynamic-programming LCS table over two lists.
List<List<int>> _lcsTable(List<String> a, List<String> b) {
  final table = List.generate(
    a.length + 1,
    (_) => List<int>.filled(b.length + 1, 0),
    growable: false,
  );
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      table[i][j] = a[i] == b[j]
          ? table[i + 1][j + 1] + 1
          : (table[i + 1][j] >= table[i][j + 1]
              ? table[i + 1][j]
              : table[i][j + 1]);
    }
  }
  return table;
}

/// A line-level diff of [oldText] vs [newText]. Deletes for a changed region
/// are emitted before inserts, so a replaced block reads as `-old` then `+new`.
List<DiffLine> diffLines(String oldText, String newText) {
  final a = _splitLines(oldText);
  final b = _splitLines(newText);
  final table = _lcsTable(a, b);

  final out = <DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      out.add(DiffLine(DiffKind.equal, a[i], oldIndex: i, newIndex: j));
      i++;
      j++;
    } else if (table[i + 1][j] >= table[i][j + 1]) {
      out.add(DiffLine(DiffKind.delete, a[i], oldIndex: i));
      i++;
    } else {
      out.add(DiffLine(DiffKind.insert, b[j], newIndex: j));
      j++;
    }
  }
  while (i < a.length) {
    out.add(DiffLine(DiffKind.delete, a[i], oldIndex: i));
    i++;
  }
  while (j < b.length) {
    out.add(DiffLine(DiffKind.insert, b[j], newIndex: j));
    j++;
  }
  return out;
}

/// True when the two texts are identical after newline normalisation.
bool textsEqual(String oldText, String newText) =>
    oldText.replaceAll('\r\n', '\n') == newText.replaceAll('\r\n', '\n');

/// A cheap "what changed" range in [newText] relative to [oldText] — the
/// longest common prefix and suffix trimmed off both sides; whatever's left
/// in the middle of [newText] is the changed span, widened out to the nearest
/// sentence-ish punctuation so a one-word edit still flashes the whole
/// sentence it landed in. Used to flash the sentence Ayma just changed
/// (§ Your Story live updates) — a heuristic, not a real diff; `null` when
/// the texts are identical.
(int, int)? changedRange(String oldText, String newText) {
  if (textsEqual(oldText, newText)) return null;
  final a = oldText;
  final b = newText;
  var prefix = 0;
  final maxPrefix = a.length < b.length ? a.length : b.length;
  while (prefix < maxPrefix && a[prefix] == b[prefix]) {
    prefix++;
  }
  var suffix = 0;
  final maxSuffix = maxPrefix - prefix;
  while (suffix < maxSuffix &&
      a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
    suffix++;
  }
  var start = prefix;
  var end = b.length - suffix;
  if (end <= start) {
    // A pure insertion/deletion at the boundary — flash right at the seam.
    start = prefix.clamp(0, b.length);
    end = (prefix + 1).clamp(0, b.length);
  }
  // Widen to the enclosing sentence: back up to just after the previous
  // sentence-ending punctuation, extend forward to the next one.
  const enders = {'.', '!', '?', '\n'};
  while (start > 0 && !enders.contains(b[start - 1])) {
    start--;
  }
  while (end < b.length && !enders.contains(b[end - 1])) {
    end++;
  }
  return (start, end);
}

List<String> _tokenizeWords(String line) {
  if (line.isEmpty) return const [];
  final tokens = <String>[];
  final buf = StringBuffer();
  for (var k = 0; k < line.length; k++) {
    final ch = line[k];
    final isSpace = ch.trim().isEmpty;
    if (buf.isNotEmpty) {
      final lastSpace = buf.toString()[buf.length - 1].trim().isEmpty;
      if (isSpace != lastSpace) {
        tokens.add(buf.toString());
        buf.clear();
      }
    }
    buf.write(ch);
  }
  if (buf.isNotEmpty) tokens.add(buf.toString());
  return tokens;
}

/// A word-level diff between a deleted line and the insert that replaced it —
/// for highlighting just the words that moved inside an otherwise similar line.
/// [changed] carries [DiffKind.delete] for [oldLine]-only tokens and
/// [DiffKind.insert] for [newLine]-only ones.
List<DiffSpan> diffWords(String oldLine, String newLine) {
  final a = _tokenizeWords(oldLine);
  final b = _tokenizeWords(newLine);
  final table = _lcsTable(a, b);

  final out = <DiffSpan>[];
  void push(DiffKind kind, String text) {
    if (text.isEmpty) return;
    if (out.isNotEmpty && out.last.kind == kind) {
      out[out.length - 1] = DiffSpan(kind, out.last.text + text);
    } else {
      out.add(DiffSpan(kind, text));
    }
  }

  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      push(DiffKind.equal, a[i]);
      i++;
      j++;
    } else if (table[i + 1][j] >= table[i][j + 1]) {
      push(DiffKind.delete, a[i]);
      i++;
    } else {
      push(DiffKind.insert, b[j]);
      j++;
    }
  }
  while (i < a.length) {
    push(DiffKind.delete, a[i]);
    i++;
  }
  while (j < b.length) {
    push(DiffKind.insert, b[j]);
    j++;
  }
  return out;
}
