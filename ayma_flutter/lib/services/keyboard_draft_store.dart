import 'dart:convert';

import 'package:flutter/services.dart';

/// Ayma Keyboard V1 — draft payload shared between the Ayma app and the
/// Ayma Keyboard (Android InputMethodService in the same application).
///
/// Storage choice (justified in docs/AYMA_KEYBOARD.md): an app-internal
/// file (`ayma_keyboard_draft.json` in the app files directory), written
/// and read natively by Kotlin code shared by MainActivity and the IME.
/// Both sides run under the same application UID and sandbox, so the file
/// is private to Ayma with no IPC surface. A ContentProvider would have
/// to be exported (or grant URI permissions) to be useful to anything,
/// and would add an attack/query surface for no benefit inside one app.
/// The IME therefore reads the file directly; the Flutter side writes it
/// through the `ayma/keyboard_draft` MethodChannel.
///
/// Privacy: this file only ever holds text the user explicitly sent to
/// the keyboard with the "Send to Ayma Keyboard" action. Keystrokes typed
/// on the keyboard are never stored here or anywhere else.
const Duration kKeyboardDraftTtl = Duration(hours: 1);

class KeyboardDraft {
  const KeyboardDraft({
    required this.text,
    required this.createdAtMillis,
    this.source,
  });

  final String text;
  final int createdAtMillis;
  final String? source;

  DateTime get createdAt =>
      DateTime.fromMillisecondsSinceEpoch(createdAtMillis);

  bool isFreshAt(DateTime now) {
    if (text.trim().isEmpty) return false;
    final ageMs = now.millisecondsSinceEpoch - createdAtMillis;
    // A draft from the future (clock skew) is treated as fresh for up to
    // the TTL; an old draft is expired.
    return ageMs < kKeyboardDraftTtl.inMilliseconds;
  }

  bool isExpiredAt(DateTime now) => !isFreshAt(now);

  Duration ageAt(DateTime now) =>
      now.difference(createdAt).clamp(Duration.zero, const Duration(days: 365));

  /// The exact text committed by `InputConnection.commitText`.
  /// Outer whitespace is trimmed (a draft is a message, not a document);
  /// interior newlines and spacing are preserved verbatim. Returns null
  /// when there is nothing insertable or the draft has expired.
  String? formatForInsertAt(DateTime now) {
    if (isExpiredAt(now)) return null;
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Map<String, Object?> toJson() => {
        'text': text,
        'createdAtMillis': createdAtMillis,
        if (source != null) 'source': source,
      };

  String encode() => jsonEncode(toJson());

  static KeyboardDraft? tryDecode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final text = decoded['text'];
      final created = decoded['createdAtMillis'];
      if (text is! String || created is! num) return null;
      return KeyboardDraft(
        text: text,
        createdAtMillis: created.toInt(),
        source: decoded['source'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is KeyboardDraft &&
      other.text == text &&
      other.createdAtMillis == createdAtMillis &&
      other.source == source;

  @override
  int get hashCode => Object.hash(text, createdAtMillis, source);
}

extension on Duration {
  Duration clamp(Duration min, Duration max) {
    if (this < min) return min;
    if (this > max) return max;
    return this;
  }
}

/// Thin wrapper over the native draft file. On non-Android platforms and
/// in widget tests the channel is absent; calls then keep an in-memory
/// copy so flows remain testable and degrade gracefully (the keyboard
/// itself is Android-only in V1).
class KeyboardDraftService {
  KeyboardDraftService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('ayma/keyboard_draft');

  final MethodChannel _channel;
  KeyboardDraft? _memoryFallback;

  Future<bool> setDraft(String text, {String? source, DateTime? now}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final draft = KeyboardDraft(
      text: trimmed,
      createdAtMillis: (now ?? DateTime.now()).millisecondsSinceEpoch,
      source: source,
    );
    _memoryFallback = draft;
    try {
      final ok = await _channel.invokeMethod<bool>('setDraft', {
        'text': draft.text,
        'createdAtMillis': draft.createdAtMillis,
        'source': draft.source,
      });
      return ok ?? true;
    } on MissingPluginException {
      return true; // in-memory fallback (tests / non-Android)
    } on PlatformException {
      return false;
    }
  }

  Future<KeyboardDraft?> getDraft() async {
    try {
      final raw = await _channel.invokeMethod<String>('getDraft');
      return KeyboardDraft.tryDecode(raw) ?? _memoryFallback;
    } on MissingPluginException {
      return _memoryFallback;
    } on PlatformException {
      return _memoryFallback;
    }
  }

  Future<void> clearDraft() async {
    _memoryFallback = null;
    try {
      await _channel.invokeMethod<void>('clearDraft');
    } on MissingPluginException {
      // Nothing native to clear.
    } on PlatformException {
      // Clearing is best-effort; the in-memory copy is already gone.
    }
  }

  Future<bool> openKeyboardSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openKeyboardSettings') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> showKeyboardPicker() async {
    try {
      return await _channel.invokeMethod<bool>('showKeyboardPicker') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

/// Shared instance used by the UI entry points.
final keyboardDraftService = KeyboardDraftService();
