import 'package:flutter/foundation.dart';

/// Ayma as the Android default digital assistant — the Dart half of the
/// Assist API hand-off (native side: `AymaAssistantSession` +
/// `AssistBridge`, channel `ayma/assistant`).
///
/// Privacy contract, mirrored in the native code and in
/// `docs/AYMA_DEFAULT_ASSISTANT.md` / `docs/PRIVACY.md`:
///  * A snapshot exists ONLY because the user summoned Ayma (long-press
///    Home / assistant gesture) while Ayma is the default assistant.
///  * Nothing is captured in the background, ever — no Accessibility
///    service, no polling, no scraping.
///  * A snapshot lives in memory only (native bridge + this file's
///    [AssistantSessionStore]). It is never written to disk, never put
///    in shared preferences, and it expires. Its text is sent to Ayma's
///    backend only when the user asks a question about the screen —
///    exactly like the in-app screen context — and the screenshot bytes
///    never leave the device at all in V1.

/// User-facing privacy copy for the assistant feature. The tests pin
/// the load-bearing claims ("only when you summon", "never stored")
/// so a copy edit cannot silently over-promise or under-disclose.
abstract final class AssistPrivacy {
  /// Shown on the assistant surface under every captured screen.
  static const String sessionNote =
      'Ayma can see this screen only because you summoned her. '
      'What she sees is used for this session only and is never stored.';

  /// Shown when a summon arrived without screen data (the Android
  /// "Use screen and app data" toggle is off for Ayma).
  static const String noScreenDataNote =
      'Android did not share this screen with Ayma. To let her see it, '
      'turn on "Use screen and app data" for Ayma in your default '
      'assistant settings — she still only ever sees a screen when you '
      'summon her, and it is never stored.';

  /// The settings-row explainer.
  static const String settingsBlurb =
      'Long-press Home in any app and Ayma opens knowing what is on '
      'your screen. She only sees a screen when you summon her, and '
      'what she sees is never stored.';
}

/// One captured foreground screen, as delivered by the Assist API.
@immutable
class AssistSnapshot {
  const AssistSnapshot({
    this.foregroundPackage = '',
    this.webUri = '',
    this.structuredData = '',
    this.texts = const [],
    this.hasScreenshot = false,
    this.screenshotWidth = 0,
    this.screenshotHeight = 0,
    this.capturedAtMillis = 0,
    this.screenDataAllowed = false,
    this.source = '',
  });

  /// Package of the app that was in the foreground (e.g.
  /// `com.android.chrome`). Empty when Android shared nothing.
  final String foregroundPackage;

  /// The web URL the foreground app reported, when it reported one.
  final String webUri;

  /// App-provided structured data (schema.org JSON), usually empty.
  final String structuredData;

  /// Visible text from the view hierarchy, flattened + de-duplicated
  /// natively, in reading order.
  final List<String> texts;

  final bool hasScreenshot;
  final int screenshotWidth;
  final int screenshotHeight;

  /// When the summon happened (epoch millis, native clock).
  final int capturedAtMillis;

  /// False when the user's "Use screen and app data" setting kept
  /// Android from sharing anything: the summon still opened Ayma.
  final bool screenDataAllowed;

  /// `voice_interaction` (a real summon) or `assist_intent`.
  final String source;

  factory AssistSnapshot.fromMap(Map<dynamic, dynamic> map) {
    List<String> textsOf(Object? raw) => raw is List
        ? raw.map((e) => e.toString()).where((s) => s.isNotEmpty).toList()
        : const [];
    return AssistSnapshot(
      foregroundPackage: (map['foregroundPackage'] as String? ?? '').trim(),
      webUri: (map['webUri'] as String? ?? '').trim(),
      structuredData: (map['structuredData'] as String? ?? '').trim(),
      texts: textsOf(map['texts']),
      hasScreenshot: map['screenshotBytes'] != null,
      screenshotWidth: (map['screenshotWidth'] as num?)?.toInt() ?? 0,
      screenshotHeight: (map['screenshotHeight'] as num?)?.toInt() ?? 0,
      capturedAtMillis: (map['capturedAtMillis'] as num?)?.toInt() ?? 0,
      screenDataAllowed: map['screenDataAllowed'] == true,
      source: (map['source'] as String? ?? '').trim(),
    );
  }

  bool get hasScreenContent =>
      texts.isNotEmpty ||
      hasScreenshot ||
      webUri.isNotEmpty ||
      structuredData.isNotEmpty;

  /// A human name for the foreground app: the package's last segment,
  /// title-cased (`com.example.shop` -> `Shop`). Falls back to a
  /// neutral phrase — we never guess a brand we cannot know.
  String get friendlyAppName {
    final pkg = foregroundPackage.trim();
    if (pkg.isEmpty) return 'another app';
    final last = pkg.split('.').last.trim();
    if (last.isEmpty) return 'another app';
    return last[0].toUpperCase() + last.substring(1);
  }

  /// The hierarchy text as Ayma receives it: unique lines joined and
  /// capped, mirroring the in-app screen-context cap discipline.
  String visibleText({int maxChars = 1500}) {
    if (maxChars <= 0 || texts.isEmpty) return '';
    final seen = <String>{};
    final sb = StringBuffer();
    for (final t in texts) {
      final line = t.trim();
      if (line.isEmpty || !seen.add(line.toLowerCase())) continue;
      if (sb.isNotEmpty) {
        if (sb.length + 1 >= maxChars) break;
        sb.writeln();
      }
      if (sb.length + line.length > maxChars) {
        sb.write(line.substring(0, maxChars - sb.length));
        break;
      }
      sb.write(line);
    }
    return sb.toString();
  }

  /// A short deterministic summary of what is on the screen, built
  /// locally (no network): the first few distinct text lines.
  String detailSummary({int maxLines = 6}) {
    final seen = <String>{};
    final lines = <String>[];
    for (final t in texts) {
      final line = t.trim();
      if (line.isEmpty || !seen.add(line.toLowerCase())) continue;
      lines.add(line);
      if (lines.length >= maxLines) break;
    }
    return lines.join(' · ');
  }

  /// A one-paragraph local description, used for the "Describe this
  /// screen" affordance before/independent of any backend turn.
  String describe() {
    if (!screenDataAllowed || !hasScreenContent) {
      return 'You summoned Ayma, but Android did not share this '
          'screen with her, so she cannot see what is on it.';
    }
    final buf = StringBuffer('You are in $friendlyAppName');
    if (webUri.isNotEmpty) buf.write(' ($webUri)');
    buf.write('.');
    final summary = detailSummary();
    if (summary.isNotEmpty) {
      buf.write(' On screen: $summary.');
    } else if (hasScreenshot) {
      buf.write(' Ayma has a picture of the screen but no readable '
          'text from it.');
    }
    return buf.toString();
  }

  /// The question actually sent for a "describe" ask.
  static const String describeQuestion =
      'Describe what is on my screen and tell me what I can do here.';

  /// Screen-context fields for `ApiClient.chat`'s screen params, so an
  /// assistant ask rides the exact same context channel as in-app
  /// screens (`screen == 'external_app'`).
  ({String screen, String subjectName, String note, String detail, String visible})
      chatScreenParams() => (
            screen: 'external_app',
            subjectName: friendlyAppName,
            note: foregroundPackage,
            detail: detailSummary(),
            visible: visibleText(),
          );

  /// The composed user turn when a caller prefers one string over the
  /// structured screen params (kept capped like [visibleText]).
  String questionWithContext(String question) {
    final q = question.trim();
    if (!hasScreenContent) return q;
    final visible = visibleText(maxChars: 800);
    if (visible.isEmpty) return q;
    return '$q\n\n[On my screen in $friendlyAppName: $visible]';
  }
}

/// A snapshot plus its screenshot bytes. The bytes exist only inside
/// this object, in memory; nothing in this file persists them.
@immutable
class AssistCapture {
  const AssistCapture({required this.snapshot, this.screenshotBytes});

  final AssistSnapshot snapshot;
  final Uint8List? screenshotBytes;

  factory AssistCapture.fromMap(Map<dynamic, dynamic> map) {
    final raw = map['screenshotBytes'];
    return AssistCapture(
      snapshot: AssistSnapshot.fromMap(map),
      screenshotBytes: raw is Uint8List
          ? raw
          : (raw is List<int> ? Uint8List.fromList(raw) : null),
    );
  }
}

/// The live session's capture, held for the assistant surface (and a
/// post-sign-in detour) to pick up. In-memory only; a capture older
/// than [maxAge] reads as absent — screen content goes stale fast and
/// privacy says we do not keep it around.
class AssistantSessionStore {
  AssistantSessionStore._();
  static final AssistantSessionStore instance = AssistantSessionStore._();

  static const Duration maxAge = Duration(minutes: 15);

  AssistCapture? _current;

  void hold(AssistCapture capture) => _current = capture;

  AssistCapture? get current {
    final c = _current;
    if (c == null) return null;
    final at = c.snapshot.capturedAtMillis;
    if (at > 0 &&
        DateTime.now().millisecondsSinceEpoch - at > maxAge.inMilliseconds) {
      _current = null;
      return null;
    }
    return c;
  }

  void clear() => _current = null;

  /// Test hook.
  @visibleForTesting
  void reset() => _current = null;
}
