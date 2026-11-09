import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'share_kit.dart';

/// Reads the Google Play install referrer on Android once after a fresh install.
///
/// When the app is installed via a shared-profile Play link, the link carries
/// `ayma_page=<token>` in the Play install referrer. This service reads that
/// token on first launch and stashes it into [PendingPageShare], so the shared
/// profile auto-opens the moment the user signs in (matching the signed-out
/// `/p/` deep-link tap behaviour).
class InstallReferrerService {
  InstallReferrerService({
    MethodChannel? channel,
    this._prefs,
    this._isAndroidOverride,
  }) : _channel = channel ?? const MethodChannel('ayma/install_referrer');

  static InstallReferrerService? _instance;
  static InstallReferrerService get instance =>
      _instance ??= InstallReferrerService();

  @visibleForTesting
  static set instance(InstallReferrerService? service) => _instance = service;

  final MethodChannel _channel;
  final SharedPreferences? _prefs;
  final bool? _isAndroidOverride;

  static const prefKey = 'ayma_install_referrer_processed';
  static const referrerKey = 'ayma_page';

  bool get _isAndroid =>
      _isAndroidOverride ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  /// Checks and processes the install referrer on Android once per install.
  Future<void> checkInstallReferrer() async {
    if (!_isAndroid) return;

    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      if (prefs.getBool(prefKey) == true) return;
      await prefs.setBool(prefKey, true);

      final raw = await _channel.invokeMethod<String>('getInstallReferrer');
      handleReferrer(raw);
    } catch (e) {
      debugPrint('InstallReferrerService check failed: $e');
    }
  }

  /// Parses [raw] and, if an `ayma_page` token is found, stashes it in
  /// [PendingPageShare]. Returns the parsed token, or null if absent/malformed.
  String? handleReferrer(String? raw) {
    final token = parseToken(raw);
    if (token != null && token.isNotEmpty) {
      if (!PendingPageShare.hasPending) {
        PendingPageShare.stashToken(token);
      }
      return token;
    }
    return null;
  }

  /// Extracts the `ayma_page` token from a raw install referrer string.
  ///
  /// Supports:
  /// - Direct key-value: `ayma_page=TOKEN`
  /// - Query strings: `utm_source=play&ayma_page=TOKEN&utm_medium=cpc`
  /// - URL-encoded strings: `ayma_page%3DTOKEN`
  ///
  /// Returns `null` if the key is absent, empty, or malformed.
  static String? parseToken(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    String decoded = trimmed;
    try {
      if (decoded.contains('%')) {
        decoded = Uri.decodeComponent(decoded);
      }
    } catch (_) {
      return null;
    }

    if (decoded.contains('?')) {
      decoded = decoded.substring(decoded.indexOf('?') + 1);
    }

    try {
      final params = Uri.splitQueryString(decoded);
      final val = params[referrerKey]?.trim();
      if (val != null && val.isNotEmpty) {
        return val;
      }
      final nestedReferrer = params['referrer']?.trim();
      if (nestedReferrer != null && nestedReferrer.isNotEmpty) {
        final nestedToken = parseToken(nestedReferrer);
        if (nestedToken != null && nestedToken.isNotEmpty) {
          return nestedToken;
        }
      }
    } catch (_) {}

    final match = RegExp(r'(?:^|[&?])ayma_page=([^&]+)').firstMatch(decoded);
    if (match != null) {
      final val = match.group(1)?.trim();
      if (val != null && val.isNotEmpty) {
        try {
          return Uri.decodeComponent(val);
        } catch (_) {
          return val;
        }
      }
    }

    return null;
  }
}
