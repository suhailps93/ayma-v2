import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Response header the API sets on its `403 biometric_consent_required`
/// answers (functions/bootstrap/main.py `require_biometric_consent`).
const String kConsentRequiredHeader = 'x-ayma-consent-required';

/// App-wide "this account still needs the face-matching consent" signal. Set
/// by `/bootstrap` or by any API call the server refused for missing consent;
/// the router's redirect (routing/app_router.dart) listens and sends the user
/// to the consent screen. Cleared once the consent is recorded or on sign-out.
class BiometricConsentState extends ChangeNotifier {
  BiometricConsentState._();

  static final BiometricConsentState instance = BiometricConsentState._();

  bool _required = false;
  bool get required => _required;

  void markRequired() {
    if (_required) return;
    _required = true;
    notifyListeners();
  }

  void clear() {
    if (!_required) return;
    _required = false;
    notifyListeners();
  }
}

/// Wraps the API's HTTP client: a response carrying [kConsentRequiredHeader]
/// raises [BiometricConsentState.markRequired], whichever call it was.
class ConsentAwareHttpClient extends http.BaseClient {
  ConsentAwareHttpClient(this._inner, {BiometricConsentState? state})
    : _state = state ?? BiometricConsentState.instance;

  final http.Client _inner;
  final BiometricConsentState _state;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    if (response.statusCode == 403 &&
        response.headers[kConsentRequiredHeader] == '1') {
      _state.markRequired();
    }
    return response;
  }

  @override
  void close() => _inner.close();
}

/// The face-matching consent ticked on the sign-in page, held on the device
/// until there is an account to record it on. The sign-in page saves it when
/// the box is ticked (and clears it when unticked); the splash screen sends it
/// to `POST /biometric-consent` right after the first successful sign-in and
/// clears it once the server has stored it. The value is the consent version
/// that was shown.
class PendingBiometricConsent {
  const PendingBiometricConsent._();

  static const _key = 'pending_biometric_consent_version';

  static Future<void> save(String version) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_key, version);
    } catch (e) {
      debugPrint('pending biometric consent save failed: $e');
    }
  }

  static Future<void> clear() async {
    try {
      await (await SharedPreferences.getInstance()).remove(_key);
    } catch (e) {
      debugPrint('pending biometric consent clear failed: $e');
    }
  }

  static Future<String?> read() async {
    try {
      return (await SharedPreferences.getInstance()).getString(_key);
    } catch (e) {
      debugPrint('pending biometric consent read failed: $e');
      return null;
    }
  }
}

/// The device's country (ISO 3166-1 alpha-2, e.g. `US`) for the consent
/// record, or '' when the locale doesn't say.
String deviceRegionCode([PlatformDispatcher? dispatcher]) {
  final code = (dispatcher ?? PlatformDispatcher.instance).locale.countryCode;
  if (code == null || !RegExp(r'^[A-Za-z]{2}$').hasMatch(code)) return '';
  return code.toUpperCase();
}
