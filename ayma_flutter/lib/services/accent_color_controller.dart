import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';
import 'profile_service.dart';

/// App-wide accent-colour preference (Task 4 of the Cherry Fuchsia batch),
/// persisted locally, same shape as `ThemeController`: a `ChangeNotifier`
/// holding one piece of state, `load()` reads `SharedPreferences` at startup
/// (best-effort, defaults on failure), `set(...)` writes through and
/// notifies. A single global instance ([accentColorControllerGlobal]).
///
/// Dual persistence, mirroring how `ayma_voice_name` follows a user around
/// (`ProfileService.setVoicePreference`): `SharedPreferences` is the fast,
/// offline-safe local copy the very next frame paints from; the Firestore
/// profile doc (`ayma_accent_color`) is the durable copy that lets the same
/// colour come back after a reinstall or on another device. `load()` only
/// reaches Firestore when there's no local value yet — every later change
/// still writes local first (instant repaint) and mirrors to Firestore
/// best-effort in the background.
class AccentColorController extends ChangeNotifier {
  AccentColorController({
    Color initial = AymaColors.accent,
    ProfileService? profileService,
  })  : _color = initial,
        _profiles = profileService ?? ProfileService();

  static const _key = 'accent_color_hex';

  final ProfileService _profiles;

  Color _color;
  Color get color => _color;

  /// Load the saved preference. Local `SharedPreferences` wins when present
  /// (fast path); otherwise, best-effort, pull the server copy so a
  /// reinstall/new device picks up a colour chosen elsewhere.
  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      final local = _parse(raw);
      if (local != null) {
        _color = local;
        notifyListeners();
        return;
      }
    } catch (_) {
      // No storage (tests / restricted context) — fall through to default.
    }
    try {
      final remote = await _profiles.getAccentColor();
      if (remote != null) {
        _color = remote;
        notifyListeners();
        try {
          await (await SharedPreferences.getInstance())
              .setString(_key, _toHex(remote));
        } catch (_) {/* best-effort cache */}
      }
    } catch (_) {
      // Signed out / offline / no profile doc yet — keep the default.
    }
  }

  /// Live-updates the colour app-wide (notifies listeners — every
  /// `context.ac.accent` read repaints) without persisting anything. Used
  /// while the user is actively dragging the Accent Color picker, so every
  /// frame reflects instantly everywhere but a drag doesn't spam disk/
  /// network writes; call [set] once the drag ends to persist the pick.
  void preview(Color color) {
    if (color.toARGB32() == _color.toARGB32()) return;
    _color = color;
    notifyListeners();
  }

  /// Sets the accent colour, notifies listeners (live repaint everywhere
  /// `context.ac.accent` is read — a no-op if [preview] already applied this
  /// exact colour), then persists — local first (fast), Firestore
  /// best-effort after (never blocks the UI on it). Always persists even
  /// when the colour is unchanged from the current in-memory value, since
  /// that's exactly the case right after a [preview] call landed the same
  /// colour without writing it through.
  Future<void> set(Color color) async {
    if (color.toARGB32() != _color.toARGB32()) {
      _color = color;
      notifyListeners();
    }
    try {
      await (await SharedPreferences.getInstance())
          .setString(_key, _toHex(color));
    } catch (_) {/* best-effort */}
    try {
      await _profiles.setAccentColor(color);
    } catch (_) {
      // Offline / signed out — local pick still stands; nothing to recover.
    }
  }

  /// Back to the Cherry Fuchsia default (§ Accent Color settings screen's
  /// "Reset to default").
  Future<void> resetToDefault() => set(AymaColors.accent);

  static String _toHex(Color c) {
    final argb = c.toARGB32();
    return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }

  static Color? _parse(String? hex) {
    if (hex == null) return null;
    final cleaned = hex.replaceFirst('#', '');
    final rgb = int.tryParse(cleaned, radix: 16);
    if (rgb == null || cleaned.length != 6) return null;
    return Color(0xFF000000 | rgb);
  }
}

/// App-wide instance — the root [MaterialApp] and the Accent Color settings
/// screen share it.
final accentColorControllerGlobal = AccentColorController();
