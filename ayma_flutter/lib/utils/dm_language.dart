/// Coarse Unicode-script detection for the cross-language DM feature (§6.12).
///
/// The DM thread must decide, for each incoming message, whether to even
/// consider offering a translation. A message in a DIFFERENT writing system
/// than the reader's language (e.g. Malayalam text, English reader) is reliably
/// foreign on script alone — so we detect it locally and never have to guess.
/// A message in the SAME writing system (typically Latin↔Latin: English,
/// Spanish, French) is ambiguous, especially when short, and can only be told
/// apart by the backend's language detector; the client resolves those with a
/// round-trip rather than blindly offering "Translate".
///
/// Mirrors the Python helper in functions/bootstrap/dm_translate.py so both
/// sides agree on what counts as a "foreign script".
library;

/// One inclusive codepoint range mapped to a script bucket.
class _ScriptRange {
  const _ScriptRange(this.lo, this.hi, this.name);
  final int lo;
  final int hi;
  final String name;
}

const List<_ScriptRange> _scriptRanges = [
  _ScriptRange(0x0041, 0x005A, 'latin'),
  _ScriptRange(0x0061, 0x007A, 'latin'),
  _ScriptRange(0x00C0, 0x024F, 'latin'),
  _ScriptRange(0x0370, 0x03FF, 'greek'),
  _ScriptRange(0x0400, 0x04FF, 'cyrillic'),
  _ScriptRange(0x0590, 0x05FF, 'hebrew'),
  _ScriptRange(0x0600, 0x06FF, 'arabic'),
  _ScriptRange(0x0900, 0x097F, 'devanagari'),
  _ScriptRange(0x0980, 0x09FF, 'bengali'),
  _ScriptRange(0x0B80, 0x0BFF, 'tamil'),
  _ScriptRange(0x0C00, 0x0C7F, 'telugu'),
  _ScriptRange(0x0C80, 0x0CFF, 'kannada'),
  _ScriptRange(0x0D00, 0x0D7F, 'malayalam'),
  _ScriptRange(0x0E00, 0x0E7F, 'thai'),
  _ScriptRange(0x1100, 0x11FF, 'hangul'),
  _ScriptRange(0x3040, 0x30FF, 'japanese'),
  _ScriptRange(0x3400, 0x9FFF, 'cjk'),
  _ScriptRange(0xAC00, 0xD7AF, 'hangul'),
];

/// Non-Latin-script languages, by base code. Anything not listed (en, es, fr,
/// de, pt, it, nl, tr, vi, id, …) is treated as Latin-script — the safe default,
/// so an unknown-but-Latin reader language keeps short same-script text out of
/// the eager "offer Translate" path.
const Map<String, String> _nonLatinLangScripts = {
  'ml': 'malayalam', 'ta': 'tamil', 'te': 'telugu', 'kn': 'kannada',
  'hi': 'devanagari', 'mr': 'devanagari', 'ne': 'devanagari',
  'bn': 'bengali', 'ar': 'arabic', 'ur': 'arabic', 'fa': 'arabic',
  'ru': 'cyrillic', 'uk': 'cyrillic', 'bg': 'cyrillic', 'sr': 'cyrillic',
  'el': 'greek', 'he': 'hebrew', 'th': 'thai',
  'zh': 'cjk', 'ja': 'japanese', 'ko': 'hangul',
};

String? _scriptOfChar(int code) {
  for (final r in _scriptRanges) {
    if (code >= r.lo && code <= r.hi) return r.name;
  }
  return null; // punctuation, digits, emoji, whitespace, symbols
}

/// The writing system most of [text]'s letters are in, or `'none'` when it
/// carries no classified letters (emoji/numbers/punctuation only).
String dominantScript(String text) {
  final counts = <String, int>{};
  for (final code in text.runes) {
    final name = _scriptOfChar(code);
    if (name != null) counts[name] = (counts[name] ?? 0) + 1;
  }
  if (counts.isEmpty) return 'none';
  var best = 'none';
  var bestN = 0;
  counts.forEach((k, v) {
    if (v > bestN) {
      bestN = v;
      best = k;
    }
  });
  return best;
}

/// The writing system a language code is written in (Latin by default).
String scriptOfLang(String code) {
  final base = code.trim().toLowerCase().replaceAll('_', '-').split('-').first;
  if (base.isEmpty) return 'latin';
  return _nonLatinLangScripts[base] ?? 'latin';
}

/// Whether a message is reliably in a DIFFERENT writing system than the
/// reader's [preferredLang] — the case we can detect offline and immediately
/// offer "Translate" for (e.g. Malayalam text for an English reader). Returns
/// false for same-script text (ambiguous, resolved by a backend round-trip) and
/// for script-less noise (emoji/numbers only — never offer Translate on that).
bool isForeignScript(String text, String preferredLang) {
  final msg = dominantScript(text);
  if (msg == 'none') return false;
  return msg != scriptOfLang(preferredLang);
}
